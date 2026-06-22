# PanSou Web Host DockerHub Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增一个 GitHub Actions workflow，基于 `ghcr.io/fish2018/pansou-web:latest` 解析出的 manifest list digest 构建 Host 网络模式自定义版镜像并推送到 DockerHub 的 `${DOCKERHUB_USERNAME}/pansou-web`。

**Architecture:** 在 `docker-image-sync` 仓库中新增独立 workflow，不改现有镜像同步 workflow。workflow 运行时先用 Buildx 解析上游 `latest` 的 manifest list digest，得到 pinned base ref；再从该 pinned ref 提取 `/app/start.sh`，用脚本做最小端口参数化补丁，并在非 443 HTTPS 场景保留请求主机 `$host`；随后生成新的 `healthcheck.sh` 和派生 `Dockerfile`，且 Dockerfile 的 `FROM` 与提取脚本使用同一个 pinned ref，最后用 Docker Buildx 多架构推送。

**Tech Stack:** GitHub Actions、Docker Buildx、DockerHub、Bash、Python 3 标准库、Docker 官方 actions。

---

## File Structure

新增和修改范围保持最小：

- Create: `.github/workflows/build-pansou-web-host.yml`
  - 负责手动/定时构建 Host 自定义版 `pansou-web` 镜像。
  - 负责登录 DockerHub、生成构建上下文、构建多架构镜像、推送 tags。
- No modification: `.github/workflows/sync-images.yml`
  - 现有 skopeo 镜像同步流程保持不变。
- No modification: `config/images.txt`
  - 现有公开镜像同步配置保持不变。
- Existing design reference: `docs/superpowers/specs/2026-06-22-pansou-web-host-dockerhub-workflow-design.md`
  - 已确认的规格文档，不需要在本计划中修改。

---

### Task 1: Add PanSou Web Host DockerHub workflow

**Files:**
- Create: `.github/workflows/build-pansou-web-host.yml`

- [ ] **Step 1: Run the failing workflow presence and content check**

From repository root `D:\project\docker-image-sync`, run:

```bash
python3 - <<'PY'
from pathlib import Path

path = Path('.github/workflows/build-pansou-web-host.yml')
if not path.exists():
    raise SystemExit('FAIL: missing .github/workflows/build-pansou-web-host.yml')

text = path.read_text(encoding='utf-8')
required = [
    'name: Build PanSou Web Host image',
    'workflow_dispatch:',
    'cron: "0 1 * * *"',
    'docker/login-action@v4',
    'docker/setup-qemu-action@v3',
    'docker/setup-buildx-action@v3',
    'docker/build-push-action@v7',
    'ghcr.io/fish2018/pansou-web:latest',
    'docker buildx imagetools inspect "${BASE_IMAGE}" --format \'{{.Digest}}\'',
    'BASE_IMAGE_PINNED="ghcr.io/fish2018/pansou-web@${base_digest}"',
    'https://\\$host:${NGINX_HTTPS_PORT}\\$request_uri',
    'docker.io/${{ secrets.DOCKERHUB_USERNAME }}/pansou-web:latest',
    'docker.io/${{ secrets.DOCKERHUB_USERNAME }}/pansou-web:host',
    'docker.io/${{ secrets.DOCKERHUB_USERNAME }}/pansou-web:host-${{ github.run_number }}',
]
missing = [item for item in required if item not in text]
if missing:
    raise SystemExit('FAIL: missing required workflow content: ' + ', '.join(missing))
print('PASS: workflow file contains required content')
PY
```

Expected result before implementation:

```text
FAIL: missing .github/workflows/build-pansou-web-host.yml
```

- [ ] **Step 2: Create the workflow file**

Create `.github/workflows/build-pansou-web-host.yml` with this exact content:

```yaml
name: Build PanSou Web Host image

on:
  workflow_dispatch:
  schedule:
    - cron: "0 1 * * *"  # 每天 UTC 01:00 执行，用于跟随上游 latest 更新

permissions:
  contents: read

concurrency:
  group: build-pansou-web-host
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    env:
      IMAGE_NAME: pansou-web
      BASE_IMAGE: ghcr.io/fish2018/pansou-web:latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Login to Docker Hub
        uses: docker/login-action@v4
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3
        with:
          platforms: linux/amd64,linux/arm64

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Prepare PanSou Web host build context
        shell: bash
        run: |
          set -Eeuo pipefail

          rm -rf build-context
          mkdir -p build-context

          base_digest="$(docker buildx imagetools inspect "${BASE_IMAGE}" --format '{{.Digest}}' 2>/dev/null || true)"
          if [ -z "${base_digest}" ]; then
              base_digest="$(docker buildx imagetools inspect "${BASE_IMAGE}" | awk '/^Digest:/ {print $2; exit}')"
          fi
          if [ -z "${base_digest}" ]; then
              echo "Failed to resolve manifest digest for ${BASE_IMAGE}" >&2
              exit 1
          fi

          BASE_IMAGE_PINNED="ghcr.io/fish2018/pansou-web@${base_digest}"

          docker pull "${BASE_IMAGE_PINNED}"
          container_id="$(docker create "${BASE_IMAGE_PINNED}")"
          trap 'docker rm -f "${container_id}" >/dev/null 2>&1 || true' EXIT

          docker cp "${container_id}:/app/start.sh" build-context/start.sh
          chmod +x build-context/start.sh

          python3 - <<'PY'
          from pathlib import Path

          path = Path('build-context/start.sh')
          text = path.read_text(encoding='utf-8')

          replacements = [
              (
                  'export DOMAIN=${DOMAIN:-localhost}\n',
                  'export DOMAIN=${DOMAIN:-localhost}\n'
                  'export NGINX_HTTP_PORT=${NGINX_HTTP_PORT:-8080}\n'
                  'export NGINX_HTTPS_PORT=${NGINX_HTTPS_PORT:-8443}\n',
              ),
              (
                  '    listen 80;',
                  '    listen ${NGINX_HTTP_PORT};',
              ),
              (
                  'echo "    listen 443 ssl http2;"',
                  'echo "    listen ${NGINX_HTTPS_PORT} ssl http2;"',
              ),
              (
                  '    echo "    return 301 https://\\$host\\$request_uri;"',
                  '    if [ "${NGINX_HTTPS_PORT}" = "443" ]; then\n'
                  '        echo "    return 301 https://\\$host\\$request_uri;"\n'
                  '    else\n'
                  '        echo "    return 301 https://\\$host:${NGINX_HTTPS_PORT}\\$request_uri;"\n'
                  '    fi',
              ),
          ]

          for old, new in replacements:
              if old not in text:
                  raise SystemExit(f'Expected start.sh pattern not found: {old!r}')
              text = text.replace(old, new, 1)

          path.write_text(text, encoding='utf-8')
          PY

          cat > build-context/healthcheck.sh <<'EOF'
          #!/bin/bash
          set -Eeuo pipefail

          PANSOU_HOST=${PANSOU_HOST:-127.0.0.1}
          PANSOU_PORT=${PANSOU_PORT:-8888}
          NGINX_HTTP_PORT=${NGINX_HTTP_PORT:-8080}
          HEALTH_CHECK_TIMEOUT=${HEALTH_CHECK_TIMEOUT:-10}

          if ! pgrep nginx >/dev/null 2>&1; then
              echo "❌ Nginx进程不存在"
              exit 1
          fi

          if ! curl -sf --max-time "${HEALTH_CHECK_TIMEOUT}" "http://127.0.0.1:${NGINX_HTTP_PORT}/api/health" >/dev/null 2>&1; then
              echo "❌ Nginx无法访问健康检查端点"
              exit 1
          fi

          if ! curl -sf --max-time "${HEALTH_CHECK_TIMEOUT}" "http://${PANSOU_HOST}:${PANSOU_PORT}/api/health" >/dev/null 2>&1; then
              echo "❌ 后端服务健康检查失败"
              exit 1
          fi

          exit 0
          EOF
          chmod +x build-context/healthcheck.sh

          cat > build-context/Dockerfile <<EOF
          FROM ${BASE_IMAGE_PINNED}

          ENV NGINX_HTTP_PORT=8080
          ENV NGINX_HTTPS_PORT=8443

          COPY start.sh /app/start.sh
          COPY healthcheck.sh /app/healthcheck.sh

          RUN chmod +x /app/start.sh /app/healthcheck.sh

          EXPOSE 8080 8443

          HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
            CMD /app/healthcheck.sh || exit 1
          EOF

          echo "Generated build context:"
          find build-context -maxdepth 1 -type f -print | sort

          echo "Verifying generated start.sh contains custom Nginx ports and redirect behavior..."
          grep -F 'NGINX_HTTP_PORT=${NGINX_HTTP_PORT:-8080}' build-context/start.sh
          grep -F 'NGINX_HTTPS_PORT=${NGINX_HTTPS_PORT:-8443}' build-context/start.sh
          grep -F 'listen ${NGINX_HTTP_PORT};' build-context/start.sh
          grep -F 'listen ${NGINX_HTTPS_PORT} ssl http2;' build-context/start.sh
          grep -F 'https://\$host:${NGINX_HTTPS_PORT}\$request_uri' build-context/start.sh
          grep -F "FROM ${BASE_IMAGE_PINNED}" build-context/Dockerfile

      - name: Build and push Docker image
        uses: docker/build-push-action@v7
        with:
          context: build-context
          file: build-context/Dockerfile
          platforms: linux/amd64,linux/arm64
          push: true
          tags: |
            docker.io/${{ secrets.DOCKERHUB_USERNAME }}/pansou-web:latest
            docker.io/${{ secrets.DOCKERHUB_USERNAME }}/pansou-web:host
            docker.io/${{ secrets.DOCKERHUB_USERNAME }}/pansou-web:host-${{ github.run_number }}
```

- [ ] **Step 3: Re-run the workflow presence and content check**

Run:

```bash
python3 - <<'PY'
from pathlib import Path

path = Path('.github/workflows/build-pansou-web-host.yml')
if not path.exists():
    raise SystemExit('FAIL: missing .github/workflows/build-pansou-web-host.yml')

text = path.read_text(encoding='utf-8')
required = [
    'name: Build PanSou Web Host image',
    'workflow_dispatch:',
    'cron: "0 1 * * *"',
    'docker/login-action@v4',
    'docker/setup-qemu-action@v3',
    'docker/setup-buildx-action@v3',
    'docker/build-push-action@v7',
    'ghcr.io/fish2018/pansou-web:latest',
    'docker buildx imagetools inspect "${BASE_IMAGE}" --format \'{{.Digest}}\'',
    'BASE_IMAGE_PINNED="ghcr.io/fish2018/pansou-web@${base_digest}"',
    'https://\\$host:${NGINX_HTTPS_PORT}\\$request_uri',
    'docker.io/${{ secrets.DOCKERHUB_USERNAME }}/pansou-web:latest',
    'docker.io/${{ secrets.DOCKERHUB_USERNAME }}/pansou-web:host',
    'docker.io/${{ secrets.DOCKERHUB_USERNAME }}/pansou-web:host-${{ github.run_number }}',
]
missing = [item for item in required if item not in text]
if missing:
    raise SystemExit('FAIL: missing required workflow content: ' + ', '.join(missing))
print('PASS: workflow file contains required content')
PY
```

Expected result after implementation:

```text
PASS: workflow file contains required content
```

- [ ] **Step 4: Run whitespace check**

Run:

```bash
git diff --check -- .github/workflows/build-pansou-web-host.yml
```

Expected result:

```text
```

The command should print no output and exit successfully.

- [ ] **Step 5: Commit the workflow**

Run:

```bash
git add .github/workflows/build-pansou-web-host.yml docs/superpowers/specs/2026-06-22-pansou-web-host-dockerhub-workflow-design.md docs/superpowers/plans/2026-06-22-pansou-web-host-dockerhub-workflow.md
git commit -m "feat: build pansou-web host image for DockerHub"
```

Expected result:

```text
[main <commit>] feat: build pansou-web host image for DockerHub
```

---

### Task 2: Validate the generated build-context logic locally without pushing

**Files:**
- Modify: none
- Validate: `.github/workflows/build-pansou-web-host.yml`

- [ ] **Step 1: Run the embedded build-context generation locally**

From repository root `D:\project\docker-image-sync`, run this command to execute the same logic as the workflow preparation step without pushing an image:

```bash
BASE_IMAGE=ghcr.io/fish2018/pansou-web:latest bash <<'SH'
set -Eeuo pipefail

rm -rf build-context
mkdir -p build-context

base_digest="$(docker buildx imagetools inspect "${BASE_IMAGE}" --format '{{.Digest}}' 2>/dev/null || true)"
if [ -z "${base_digest}" ]; then
    base_digest="$(docker buildx imagetools inspect "${BASE_IMAGE}" | awk '/^Digest:/ {print $2; exit}')"
fi
if [ -z "${base_digest}" ]; then
    echo "Failed to resolve manifest digest for ${BASE_IMAGE}" >&2
    exit 1
fi

BASE_IMAGE_PINNED="ghcr.io/fish2018/pansou-web@${base_digest}"

docker pull "${BASE_IMAGE_PINNED}"
container_id="$(docker create "${BASE_IMAGE_PINNED}")"
trap 'docker rm -f "${container_id}" >/dev/null 2>&1 || true' EXIT

docker cp "${container_id}:/app/start.sh" build-context/start.sh
chmod +x build-context/start.sh

python3 - <<'PY'
from pathlib import Path

path = Path('build-context/start.sh')
text = path.read_text(encoding='utf-8')

replacements = [
    (
        'export DOMAIN=${DOMAIN:-localhost}\n',
        'export DOMAIN=${DOMAIN:-localhost}\n'
        'export NGINX_HTTP_PORT=${NGINX_HTTP_PORT:-8080}\n'
        'export NGINX_HTTPS_PORT=${NGINX_HTTPS_PORT:-8443}\n',
    ),
    (
        '    listen 80;',
        '    listen ${NGINX_HTTP_PORT};',
    ),
    (
        'echo "    listen 443 ssl http2;"',
        'echo "    listen ${NGINX_HTTPS_PORT} ssl http2;"',
    ),
    (
        '    echo "    return 301 https://\\$host\\$request_uri;"',
        '    if [ "${NGINX_HTTPS_PORT}" = "443" ]; then\n'
        '        echo "    return 301 https://\\$host\\$request_uri;"\n'
        '    else\n'
        '        echo "    return 301 https://\\$host:${NGINX_HTTPS_PORT}\\$request_uri;"\n'
        '    fi',
    ),
]

for old, new in replacements:
    if old not in text:
        raise SystemExit(f'Expected start.sh pattern not found: {old!r}')
    text = text.replace(old, new, 1)

path.write_text(text, encoding='utf-8')
PY

cat > build-context/healthcheck.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail

PANSOU_HOST=${PANSOU_HOST:-127.0.0.1}
PANSOU_PORT=${PANSOU_PORT:-8888}
NGINX_HTTP_PORT=${NGINX_HTTP_PORT:-8080}
HEALTH_CHECK_TIMEOUT=${HEALTH_CHECK_TIMEOUT:-10}

if ! pgrep nginx >/dev/null 2>&1; then
    echo "❌ Nginx进程不存在"
    exit 1
fi

if ! curl -sf --max-time "${HEALTH_CHECK_TIMEOUT}" "http://127.0.0.1:${NGINX_HTTP_PORT}/api/health" >/dev/null 2>&1; then
    echo "❌ Nginx无法访问健康检查端点"
    exit 1
fi

if ! curl -sf --max-time "${HEALTH_CHECK_TIMEOUT}" "http://${PANSOU_HOST}:${PANSOU_PORT}/api/health" >/dev/null 2>&1; then
    echo "❌ 后端服务健康检查失败"
    exit 1
fi

exit 0
EOF
chmod +x build-context/healthcheck.sh

cat > build-context/Dockerfile <<EOF
FROM ${BASE_IMAGE_PINNED}

ENV NGINX_HTTP_PORT=8080
ENV NGINX_HTTPS_PORT=8443

COPY start.sh /app/start.sh
COPY healthcheck.sh /app/healthcheck.sh

RUN chmod +x /app/start.sh /app/healthcheck.sh

EXPOSE 8080 8443

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD /app/healthcheck.sh || exit 1
EOF

find build-context -maxdepth 1 -type f -print | sort
SH
```

Expected result includes:

```text
build-context/Dockerfile
build-context/healthcheck.sh
build-context/start.sh
```

- [ ] **Step 2: Validate generated script syntax**

Run:

```bash
bash -n build-context/start.sh
bash -n build-context/healthcheck.sh
```

Expected result:

```text
```

Both commands should print no output and exit successfully.

- [ ] **Step 3: Validate generated files contain the required custom port behavior**

Run:

```bash
python3 - <<'PY'
from pathlib import Path

start = Path('build-context/start.sh').read_text(encoding='utf-8')
health = Path('build-context/healthcheck.sh').read_text(encoding='utf-8')
dockerfile = Path('build-context/Dockerfile').read_text(encoding='utf-8')

checks = {
    'start.sh defines NGINX_HTTP_PORT default': 'NGINX_HTTP_PORT=${NGINX_HTTP_PORT:-8080}' in start,
    'start.sh defines NGINX_HTTPS_PORT default': 'NGINX_HTTPS_PORT=${NGINX_HTTPS_PORT:-8443}' in start,
    'start.sh uses HTTP listen env var': 'listen ${NGINX_HTTP_PORT};' in start,
    'start.sh uses HTTPS listen env var': 'listen ${NGINX_HTTPS_PORT} ssl http2;' in start,
    'start.sh redirects to preserved host on custom HTTPS port': 'https://$host:${NGINX_HTTPS_PORT}$request_uri' in start,
    'healthcheck uses NGINX_HTTP_PORT': 'http://127.0.0.1:${NGINX_HTTP_PORT}/api/health' in health,
    'Dockerfile derives from pinned upstream image': 'FROM ghcr.io/fish2018/pansou-web@' in dockerfile,
    'Dockerfile copies patched start script': 'COPY start.sh /app/start.sh' in dockerfile,
    'Dockerfile copies patched healthcheck': 'COPY healthcheck.sh /app/healthcheck.sh' in dockerfile,
}

failed = [name for name, ok in checks.items() if not ok]
if failed:
    raise SystemExit('FAIL: ' + ', '.join(failed))
print('PASS: generated build context contains required host-port behavior')
PY
```

Expected result:

```text
PASS: generated build context contains required host-port behavior
```

- [ ] **Step 4: Build the image locally for the host architecture**

Run:

```bash
docker build -t pansou-web:host-local build-context
```

Expected result includes:

```text
Successfully tagged pansou-web:host-local
```

BuildKit may print a different final line such as `naming to docker.io/library/pansou-web:host-local done`; that is also acceptable if the command exits successfully.

- [ ] **Step 5: Commit validation note if generated files were accidentally staged**

Run:

```bash
git status --short
```

Expected result after Task 1 commit and local validation:

```text
?? build-context/
```

Do not commit `build-context/`. Remove it with:

```bash
rm -rf build-context
```

Then run:

```bash
git status --short
```

Expected result:

```text
```

---

### Task 3: Verify GitHub Actions run and DockerHub tags

**Files:**
- Modify: none
- Validate remote: `.github/workflows/build-pansou-web-host.yml`

- [ ] **Step 1: Push the branch containing the workflow commit**

Run:

```bash
git push origin main
```

Expected result includes:

```text
To github.com:
```

If working on a non-main branch, push that branch and open a pull request instead:

```bash
git push origin HEAD
```

- [ ] **Step 2: Trigger the workflow manually**

In GitHub UI:

1. Open the `docker-image-sync` repository.
2. Go to `Actions`.
3. Select `Build PanSou Web Host image`.
4. Click `Run workflow`.
5. Run it from the branch that contains the workflow.

Expected result:

```text
Workflow run starts with one job named build
```

- [ ] **Step 3: Confirm the workflow completed successfully**

In the workflow run logs, confirm these steps completed successfully:

```text
Login to Docker Hub
Set up QEMU
Set up Docker Buildx
Prepare PanSou Web host build context
Build and push Docker image
```

Expected result:

```text
build: success
```

- [ ] **Step 4: Confirm DockerHub tags exist**

Open DockerHub repository:

```text
https://hub.docker.com/r/<DOCKERHUB_USERNAME>/pansou-web/tags
```

Confirm these tags exist:

```text
latest
host
host-<GitHub run number>
```

Use the concrete GitHub run number from the successful workflow run. For example, if the run number is `12`, confirm:

```text
host-12
```

- [ ] **Step 5: Verify deployment command uses the host tag**

On a deployment host that supports Docker host networking, use this Compose service shape:

```yaml
services:
  pansou:
    image: <DOCKERHUB_USERNAME>/pansou-web:host
    container_name: pansou-app
    network_mode: host
    environment:
      - DOMAIN=localhost
      - NGINX_HTTP_PORT=8080
      - NGINX_HTTPS_PORT=8443
      - PANSOU_PORT=8888
      - PANSOU_HOST=127.0.0.1
    volumes:
      - pansou-data:/app/data
    restart: unless-stopped

volumes:
  pansou-data:
```

Run:

```bash
docker compose up -d
curl -f http://127.0.0.1:8080/api/health
```

Expected result:

```text
```

`curl` should exit successfully. The response body can vary by upstream application version.

---

## Self-Review Notes

- Spec coverage: The plan creates the independent workflow, uses DockerHub secrets, resolves a manifest list digest from `ghcr.io/fish2018/pansou-web:latest`, pins both script extraction and Dockerfile `FROM` to the same upstream digest, supports `NGINX_HTTP_PORT` and `NGINX_HTTPS_PORT`, preserves `$host` for non-443 HTTPS redirects, pushes `latest`, `host`, and `host-<run_number>`, and avoids modifying the existing sync workflow.
- Placeholder scan: This plan contains no deferred implementation markers and includes exact commands and complete file content for the workflow.
- Consistency check: The same secrets names, image name, workflow name, tags, and port defaults are used throughout all tasks.
