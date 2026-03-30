# docker-image-sync

自动将多个公开容器镜像同步到我的 Docker Hub，用于加速拉取和个人使用。

> 注意：
> - 本仓库不是上游官方仓库
> - 这里只是对公开镜像做自动同步
> - 所有镜像版权、商标、许可证归原作者所有
> - 如有侵权或不适合公开分发，请联系我删除

---

## 功能

- 支持多个镜像自动同步
- 支持多个 tag
- 支持定时同步
- 支持 GHCR 等 OCI Registry 复制到 Docker Hub
- 使用 `skopeo` 保留多架构镜像（尽量）

---

## 仓库结构

```text
.
├─ .github/workflows/sync-images.yml
├─ scripts/sync-images.sh
├─ config/images.txt
├─ .gitignore
└─ README.md
