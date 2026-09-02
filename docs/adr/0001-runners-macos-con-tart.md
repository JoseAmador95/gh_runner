# ADR 0001: runners de macOS con VMs efímeras de Tart

## Contexto

Este repo despliega runners self-hosted de GitHub Actions en contenedores Linux
(`deploy.sh`/`deploy.ps1`), y esa es la razón de que el vigía (§9 del README) sea
un servicio más del propio `compose.yaml`: el motor de contenedores es, según el
propio README, «la única capa idéntica en Linux, macOS y Windows: no hay
`systemd`, ni `launchd`, ni tarea programada que mantener».

Esa premisa no aguanta un job que necesita firmar una app de iOS
(`codesign`, `security create-keychain`): eso exige un macOS de verdad, con
`Virtualization.framework` y una sesión gráfica, y **no existe un contenedor de
macOS**. La API de contenedores de Apple no virtualiza el sistema operativo
como Docker/Podman virtualizan Linux; lo más parecido, con el mismo modelo de
imágenes que ya usa este repo, es **Tart** (Cirrus Labs): clona VMs desde
imágenes en un registro OCI (`ghcr.io/cirruslabs/...`), igual que
`podman pull`/`docker pull`, con clones copy-on-write casi gratis frente a la
imagen base.

Tres restricciones de la plataforma que no son negociables y que moldean todo
lo demás:

- **Máximo 2 VMs de macOS a la vez por Mac con licencia.** No es un límite de
  este proyecto: lo impone el EULA de macOS (como mucho dos instancias
  virtualizadas simultáneas) y lo hace cumplir
  `Virtualization.framework` en el propio sistema operativo. Una tercera VM no
  arranca.
- **El agente tiene que arrancar dentro de la sesión gráfica (Aqua), no por
  `ssh`.** El workflow que firma la app llama a `codesign` y al llavero; fuera
  de la sesión Aqua eso falla con `errSecInternalComponent` o —peor— abre un
  diálogo de autorización que nadie puede contestar en una VM sin nadie
  delante. El job no falla: se cuelga hasta el timeout, sin ninguna pista de
  por qué.
- **El presupuesto de disco es real y estrecho.** Con un Mac mini M2 de menos
  de 500 GB libres: 50-60 GB de caché OCI de la imagen base, 60-80 GB de la
  golden ya aprovisionada, y 15-30 GB por cada clon efímero de un job. Con un
  solo slot ya son ~150-170 GB comprometidos.

## Decisión

Reproducir en macOS, con Tart, el mismo modelo que ya funciona en Linux —
runner efímero, un job por registro, auto-reparación, vigilancia— aceptando
que la pieza que lo sostiene deja de ser el motor de contenedores.

### Golden image en dos fases de cadencia distinta

`hornear-macos.sh` separa lo caro de lo barato:

- **`--completo`** (semanal): clona la imagen base OCI en una VM golden, la
  arranca, la aprovisiona por `ssh` con el script que le pase el consumidor
  (`--provisionar RUTA_O_URL`, el equivalente exacto de un `FROM` en un
  `Containerfile` derivado) y la para. Comprueba el espacio libre **antes** de
  clonar —fallar a mitad de un clon de 60 GB deja el disco peor que al
  empezar— y poda la caché OCI de la base al terminar (`tart prune`), porque
  la golden ya es una copia completa e independiente.
- **`--runner`** (diaria): solo baja y verifica el tarball de `actions/runner`
  en el host, sin tocar la golden. GitHub sube el mínimo de versión del agente
  a menudo (documentado también para el camino Linux), y re-hornear 60-80 GB
  para cambiar un ejecutable de ~300 MB sería tirar el presupuesto de disco a
  la basura. El invitado lo desempaqueta en segundos al arrancar
  (`entrypoint-macos.sh`).

La base por defecto es `ghcr.io/cirruslabs/macos-sequoia-xcode:16.4` —**un
solo** Xcode— y no `macos-runner:tahoe`, que trae tres versiones y ronda los
100 GB: este proyecto no cambia de Xcode entre jobs.

### VM efímera por job, supervisada desde el host

`supervisar-macos.sh` sustituye a `restart: always`: un proceso por slot que
repite, indefinidamente, `tart clone` de la golden → `tart set` (cpu/memoria)
→ `tart run` (el job corre dentro) → `tart delete`. La VM se **destruye** en
cada vuelta —es lo que impide que un job de un PR de terceros ensucie al
siguiente—, así que cualquier estado que deba sobrevivir entre vueltas tiene
que vivir fuera de ella, en el host.

De ahí dos consecuencias de diseño obligadas:

- **El backoff anti crash-loop se muda al host.** En Linux,
  `entrypoint.sh` lleva sus marcadores (`.gh_runner_ok`/`_last`/`_fails`)
  dentro del propio contenedor, que `restart: always` reutiliza. Aquí morirían
  con la VM en cada vuelta y no frenarían nada: un fallo instantáneo repetido
  martillearía la API de GitHub con un `registration-token` por vuelta hasta
  agotar el rate limit del PAT, justo lo que el backoff existe para evitar. Los
  mismos nombres de fichero, la misma lógica, pero en
  `./estado/runner-<i>/` del host, que sí persiste.
- **El ciclo mínimo sano sube de 20 s a 90 s** (`SV_MIN_CICLO`). En Linux una
  vuelta de 20 s ya es sospechosa; en macOS una vuelta **sana** incluye
  arrancar la VM entera (~30-45 s), así que 20 s seguiría siendo un falso
  positivo de fallo. Y como `tart run` retornando solo dice «la VM se apagó»
  —se apaga igual si el invitado murió en el primer segundo—, la salud de una
  vuelta la decide su duración, no solo su código de salida.

`desregistrar_por_api` es la pieza que no tiene equivalente en el camino
Linux: si la VM muere colgada (pánico, `kill -9`, corte de luz), el invitado
nunca llega a desregistrarse y queda un runner `offline` en Settings →
Runners con el nombre del slot. Como el nombre se reutiliza en la vuelta
siguiente, `--replace` lo taparía... salvo que el slot no vuelva a arrancar,
que es justo el caso en que el vigía necesita avisar: entonces el fantasma se
queda ahí **para siempre**, contando como un runner caído que ya no existe.
El supervisor lo limpia porque es el único proceso que sigue vivo para
hacerlo, tanto en su parada elegante como tras una vuelta que terminó mal.

### El agente arranca por LaunchAgent en la sesión Aqua, no por `ssh`

La golden hornea un LaunchAgent que ejecuta
`entrypoint-macos.sh` dentro de la sesión gráfica con inicio de sesión
automático. No es una preferencia de estilo: es la única forma de que
`codesign` funcione. Si alguien «simplifica» esto a
`ssh vm ./entrypoint-macos.sh`, la firma de la app deja de funcionar en
silencio (o se cuelga hasta el timeout, sin trazas).

### La excepción a la premisa: `launchd` en el host, una vez

`supervisar-macos.sh` y (opt-in) el vigía corren como LaunchAgents del host
macOS, gestionados por `deploy-macos.sh` con `launchctl bootstrap`/`bootout` a
través de `macos-ctl.sh`. Esto rompe, literalmente, la frase del README que
justifica que el vigía sea un contenedor: aquí **sí** hay `launchd` que
mantener.

Se rompe a propósito y **una sola vez**, y está justificado por dos motivos:

1. **En este camino no hay motor de contenedores en absoluto.** La premisa que
   se protege («no mantengas un programador de tareas por sistema operativo»)
   ya no aplica: no hay Podman ni Docker sobre los que apoyarse, y el propio
   ciclo del job —clonar, arrancar, destruir una VM— **ya** necesita alguien
   que lo repita indefinidamente. Ese alguien es `supervisar-macos.sh`, y una
   vez que existe como proceso de larga duración gestionado por `launchd`,
   añadir el LaunchAgent del vigía es un fichero más de un tipo que
   `deploy-macos.sh` ya genera, no una segunda tecnología de agendado.
2. **La coste de "mantener launchd" ya está pagado.** El supervisor por slot
   tiene que sobrevivir a reinicios del Mac, reintentar tras un fallo y
   apagarse con orden (`ExitTimeOut 120`, para que le dé tiempo a drenar el
   job, hacer `tart stop`/`tart delete` y limpiar el runner fantasma antes de
   que `launchd` mande `SIGKILL`). Ese trabajo hay que hacerlo exista o no el
   vigía; el vigía solo reutiliza la misma maquinaria.

La alternativa que sí preservaría la premisa —un `podman machine` mínimo,
solo para correr `vigilar.sh` dentro de un contenedor Linux, igual que en el
camino Linux— se descartó (ver más abajo): además de meter una VM Linux
entera para ejecutar un script de shell, **mide el reloj equivocado**. El
vigía existe, entre otras cosas, para detectar desfase de reloj (§9 del
README: el caso real que lo motivó fue un host con el reloj 32 minutos
atrasado). Los runners de macOS heredan el reloj del **host macOS**, no el de
una VM de Podman con su propio NTP; medir el reloj de la VM de Podman
respondería a una pregunta que no es la que importa.

### Imagen en dos fases: golden local ahora, GHCR más adelante

Hoy la golden solo vive en el disco local del Mac que la hornea
(`tart clone`/`tart run` contra la caché OCI de la base, sin publicar nada).
Es la fase 1, y es la correcta con **un solo Mac**: `tart push` a un registro
como GHCR y luego `tart pull` de vuelta en la misma máquina sería subir y
volver a bajar 60-80 GB al mismo disco, coste puro sin ningún beneficio. Esa
fase 2 solo tiene sentido cuando aparezca un **segundo Mac** que necesite la
misma golden sin re-hornearla desde cero, o si se quiere reproducibilidad
auditable (poder señalar exactamente qué imagen corrió un job concreto, con
su digest). Hasta entonces, cada Mac hornea la suya.

## Consecuencias

- El operador que ya conoce el camino Linux reconoce el camino macOS sin
  aprender una tecnología nueva de cero: misma CLI de `deploy-macos.sh`
  (comparada campo a campo con `deploy.sh` en su cabecera), mismos verbos en
  `macos-ctl.sh` (`ps`, `logs`, `up`, `down`, `down -v`) que en
  `podman compose`, mismo modelo de vigía con `sano`/`parcial`/`degradado`.
- `launchd` pasa a ser una dependencia operativa real en macOS: quien despliega
  tiene que entender `launchctl bootstrap`/`bootout`, plists y su
  `ExitTimeOut`, aunque `macos-ctl.sh` lo esconda casi por completo detrás de
  verbos conocidos.
- El tope de 2 VMs es un techo de capacidad por máquina, no ajustable: escalar
  significa añadir Macs, no subir `--count`.
- El presupuesto de disco obliga a vigilar el Mac de cerca (~150-170 GB con un
  solo slot) y a mantener separadas las dos cadencias de refresco
  (`--runner` diario, `--completo` semanal): confundirlas —re-hornear la
  golden a diario— agotaría el disco o el tiempo del operador sin necesidad.
- Un job de macOS no puede recuperarse de un `kill -9` de la misma forma
  silenciosa que un contenedor: si `desregistrar_por_api` no consigue hablar
  con la API (sin PAT, sin red), el runner fantasma queda visible en Settings
  hasta que alguien lo borre a mano.
- La golden sin publicar en GHCR significa que, hoy, **no hay forma de
  auditar o compartir** la imagen exacta que corrió un job entre dos Macs:
  cada uno construye la suya de forma independiente a partir de la misma base
  y el mismo script de aprovisionamiento, pero no hay garantía binaria de que
  coincidan byte a byte.

## Alternativas descartadas

- **`podman machine` solo para el vigía, para preservar «sin launchd».**
  Rechazada: mete una VM Linux entera para ejecutar un script de shell que ya
  tiene dónde vivir (el propio host, que ya corre `launchd` por el
  supervisor), y además mide el reloj de la VM de Podman en vez del reloj del
  host macOS, que es el que de verdad usan los runners para renovar su
  credencial. Resolvería el síntoma («no toques `launchd`») rompiendo el
  propósito del vigía.
- **Anka (Veertu).** Descartada: es un producto comercial con licencia de
  pago; Tart resuelve el mismo problema (VMs de macOS, imágenes OCI, clones
  copy-on-write) sin coste de licencia y con el mismo modelo de imágenes que
  ya usa este repo para las imágenes Linux.
- **Runner directo sobre el host, sin VM.** Descartada: rompe el aislamiento
  entre jobs que el resto del fleet garantiza hoy (cada job Linux corre en su
  propio contenedor efímero). Un runner sobre el host macOS desnudo dejaría
  que el código de un PR de terceros tocara el sistema real, sin nada que
  destruir entre jobs.
- **Alquiler de Mac en la nube (p. ej. Scaleway, ~0,22 €/h).** Descartada para
  este proyecto: la misma licencia de Apple que limita las VMs locales a 2
  obliga a los proveedores en la nube a un **mínimo de reserva de 24 h** por
  máquina física; a ese precio, mantenerla encendida de forma continua ronda
  los ~149 €/mes. Es desproporcionado para workflows que hoy solo se disparan
  con `workflow_dispatch`, y un Mac propio ya cubre la carga con el modelo de
  este ADR.
