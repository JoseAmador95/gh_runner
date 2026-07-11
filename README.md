```bash
podman build --tag gh-runner:ubuntu-24 .
```

```bash
podman run -d \
    --name gh-runner \
    --restart=always \
    -e REPO_USER=USER \
    -e REPO_NAME=NAME \
    -e RUNNER_TOKEN=TOKEN \
    -e RUNNER_LABELS="self-hosted,mac-mini,arm64,ubuntu-24.04" \
    gh-runner:ubuntu-24.04
```
