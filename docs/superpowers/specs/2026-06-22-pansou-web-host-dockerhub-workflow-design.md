# PanSou Web Host 版 DockerHub 构建 Workflow 设计

日期：2026-06-22

## 背景

`docker-image-sync` 当前用于把公开容器镜像同步到 DockerHub。已有 workflow `.github/workflows/sync-images.yml` 使用 `skopeo` 将 `config/images.txt` 中的公开镜像复制到 DockerHub，并已通过仓库 secrets 配置 DockerHub 登录信息。

本次需求是在该仓库内新增一个 GitHub Actions workflow，用于构建并推送 `pansou-web` 的 Host 网络模式自定义版镜像到 DockerHub。

## 目标

新增一个独立 workflow：

```text
.github/workflows/build-pansou-web-host.yml
```

该 workflow 构建一个派生镜像：

```dockerfile
FROM ghcr.io/fish2018/pansou-web@<manifest-list-digest>
```

派生镜像只覆盖：

- `/app/start.sh`
- `/app/healthcheck.sh`

使镜像支持以下环境变量：

- `NGINX_HTTP_PORT`，默认 `8080`
- `NGINX_HTTPS_PORT`，默认 `8443`

并将镜像推送到 DockerHub：

```text
${DOCKERHUB_USERNAME}/pansou-web
```

其中 DockerHub 登录信息继续使用仓库中已经配置的：

- `secrets.DOCKERHUB_USERNAME`
- `secrets.DOCKERHUB_TOKEN`

## 非目标

本设计不做以下事情：

- 不修改现有 `.github/workflows/sync-images.yml`
- 不修改 `config/images.txt`
- 不从 `fish2018/pansou` 源码重新编译后端
- 不从本仓库构建 pansou-web 前端
- 不维护完整上游 `pansou-web` 构建链路
- 不把 DockerHub 用户名或 Token 写死到仓库文件

## 推荐方案

采用“单 workflow 内嵌构建上下文”方案。

workflow 运行时动态生成临时构建目录：

```text
build-context/
├── Dockerfile
├── start.sh
└── healthcheck.sh
```

然后用 `docker/build-push-action` 构建并推送。

workflow 在 Buildx 可用后先解析 `ghcr.io/fish2018/pansou-web:latest` 的 manifest list digest，并构造：

```text
ghcr.io/fish2018/pansou-web@<manifest-list-digest>
```

后续提取 `start.sh` 与生成 Dockerfile 的 `FROM` 都使用同一个 pinned ref，避免 `latest` 在准备阶段和构建阶段之间漂移导致脚本与基镜像不一致。

### 选择该方案的原因

- 只需要新增一个 workflow 文件
- 符合该仓库“镜像同步/镜像自动化”的用途
- 不需要引入额外源码目录
- 不需要本地持有 `pansou-amd64`、`pansou-arm64`、`frontend-dist` 等原始构建产物
- 基于上游发布镜像派生，构建成本低，失败面小

## Workflow 触发方式

workflow 支持：

```yaml
on:
  workflow_dispatch:
  schedule:
    - cron: "0 1 * * *"
```

含义：

- `workflow_dispatch`：允许手动触发
- `schedule`：每天 UTC 01:00 自动构建一次

定时构建用于跟随上游 `ghcr.io/fish2018/pansou-web:latest` 更新。

## 镜像标签策略

推送以下标签：

```text
${DOCKERHUB_USERNAME}/pansou-web:latest
${DOCKERHUB_USERNAME}/pansou-web:host
${DOCKERHUB_USERNAME}/pansou-web:host-${GITHUB_RUN_NUMBER}
```

各标签用途：

- `latest`：日常部署默认使用
- `host`：明确表示 Host 网络模式自定义端口版
- `host-<run_number>`：用于回滚到具体构建批次

## 构建平台

使用 Docker Buildx 构建多架构镜像：

```text
linux/amd64
linux/arm64
```

这样保持和上游镜像的多架构使用习惯一致。

## 自定义启动脚本行为

`start.sh` 基于上游镜像中的启动逻辑做最小差异修改：

1. 增加端口环境变量默认值：

```bash
export NGINX_HTTP_PORT=${NGINX_HTTP_PORT:-8080}
export NGINX_HTTPS_PORT=${NGINX_HTTPS_PORT:-8443}
```

2. 将 Nginx HTTP 监听端口从固定 `80` 改为：

```nginx
listen ${NGINX_HTTP_PORT};
```

3. 将 Nginx HTTPS 监听端口从固定 `443` 改为：

```nginx
listen ${NGINX_HTTPS_PORT} ssl http2;
```

4. SSL 可用时的 HTTP 到 HTTPS 跳转需要考虑非 443 HTTPS 端口：

- 如果 `NGINX_HTTPS_PORT=443`，跳转到 `https://$host$request_uri`
- 否则跳转到 `https://$host:${NGINX_HTTPS_PORT}$request_uri`

## 健康检查行为

`healthcheck.sh` 检查：

1. Nginx 进程是否存在
2. Nginx 是否通过 `NGINX_HTTP_PORT` 响应 `/api/health`
3. 后端服务是否通过 `PANSOU_HOST:PANSOU_PORT` 响应 `/api/health`

Nginx 健康检查地址为：

```text
http://127.0.0.1:${NGINX_HTTP_PORT}/api/health
```

这样避免默认检查 80 端口导致 Host 自定义版镜像被误判为 unhealthy。

## GitHub Actions 主要步骤

新增 workflow 包含以下步骤：

1. Checkout 当前仓库
2. 登录 DockerHub
   - username: `${{ secrets.DOCKERHUB_USERNAME }}`
   - password: `${{ secrets.DOCKERHUB_TOKEN }}`
3. 设置 QEMU
4. 设置 Docker Buildx
5. 解析上游 `ghcr.io/fish2018/pansou-web:latest` 的 manifest list digest，生成 pinned base ref
6. 创建 `build-context`
7. 使用 pinned base ref 提取并补丁 `/app/start.sh`
8. 在 `build-context` 中写入：
   - `Dockerfile`
   - `start.sh`
   - `healthcheck.sh`
9. 使用 `docker/build-push-action` 构建并推送多架构镜像

## 部署示例

构建完成后，可以用以下 Compose 配置部署：

```yaml
services:
  pansou:
    image: ${DOCKERHUB_USERNAME}/pansou-web:host
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

访问地址：

```text
http://localhost:8080
```

## 错误处理

workflow 失败条件包括：

- DockerHub 登录失败
- 上游镜像 `ghcr.io/fish2018/pansou-web:latest` 拉取失败
- 临时构建上下文生成失败
- Docker Buildx 多架构构建失败
- 推送 DockerHub 失败

这些错误直接由 GitHub Actions 日志暴露，不额外吞掉错误。

## 验证方式

实现后至少验证：

1. workflow YAML 结构有效
2. workflow 引用了正确的 DockerHub secrets
3. 构建上下文中 Dockerfile 使用解析出的 pinned 上游镜像 digest 引用
4. Dockerfile 覆盖 `/app/start.sh` 和 `/app/healthcheck.sh`
5. `start.sh` 中 Nginx HTTP/HTTPS 监听端口均使用环境变量
6. `start.sh` 中非 443 HTTPS 跳转保留请求主机并拼接 `${NGINX_HTTPS_PORT}`
7. `healthcheck.sh` 使用 `NGINX_HTTP_PORT` 检查 Nginx
8. GitHub Actions 手动运行后 DockerHub 出现以下 tag：
   - `latest`
   - `host`
   - `host-<run_number>`

## 维护说明

由于该方案复制了上游 `start.sh` 的核心逻辑，如果上游 `ghcr.io/fish2018/pansou-web:latest` 后续大幅调整启动脚本，Host 自定义版 workflow 中的内嵌脚本可能需要同步更新。

为降低维护成本，本次实现只保留必要修改，不引入额外特性。
