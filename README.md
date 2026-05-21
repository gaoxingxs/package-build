# package-build

一组通用软件的离线构建工作流集合，**专为 CentOS 7 / glibc 2.17 兼容环境**优化。所有产物可直接落地到老旧 Linux 发行版（CentOS 7+ / RHEL 7+ / Ubuntu 18.04+ / Debian 10+ / Amazon Linux 2 / SLES 12+），无需在目标机编译。

构建在 GitHub Actions 跑，**全部仅手动触发**（`workflow_dispatch`），不会因 push 误触发占额度。

---

## 工作流一览

| 工作流 | 产物 | 备注 |
|---|---|---|
| `[PostgreSQL] Build with extensions` | `postgresql-<ver>-glibc217-<arch>.tar.gz` | PG 17 + pg_cron + pgvector + 全部 contrib；支持 amd64 / arm64 |
| `[APISIX] Build offline RPM packages` | APISIX RPM 离线包 | 含 OpenResty / LuaRocks；支持 amd64 / arm64 |
| `[Ansible] Download offline RPM bundle` | `ansible-centos7-offline.tar.gz` | Ansible 及依赖 RPM 包 |
| `[llama.cpp] Build static binaries` | `llama-cpp-centos7-avx512.tar.gz` | 静态链接，AVX-512 |
| `[n8n] Build & push runner image` | GHCR 多架构镜像 | 基于 `n8nio/runners`，加装 Python 依赖 |
| `[Python] Download/build offline wheels` | wheel 包集合 | 多 Python 版本、amd64 / arm64 |
| `[Redis] Build static binaries` | `redis-server` / `redis-cli` 静态二进制 | amd64 / arm64 |
| `[RPMs] Download with dependencies` | RPM 包及依赖打包 | 指定包名自动解析依赖 |
| `[zstd] Build static binary` | `zstd` 静态二进制 | amd64 / arm64 |

---

## 使用方法

### 通过 GitHub Web UI

仓库 → **Actions** → 选工作流 → **Run workflow** → 填参数运行。

### 通过 GitHub CLI

```bash
# 列出所有工作流
gh workflow list

# 触发 PostgreSQL 双架构构建
gh workflow run postgres-build.yml --ref main \
  -f target_arch=both \
  -f pg_version=17.5

# 看最近的 run
gh run list --workflow=postgres-build.yml --limit 5

# 实时跟踪
gh run watch <run-id>

# 下载产物
gh run download <run-id>
```

---

## 仓库结构

```
.github/workflows/      # 9 个构建工作流（命名规范：<组件>-<动作>.yml）
apisix/                 # APISIX 构建脚本
n8n/                    # n8n runner 镜像 Dockerfile + Python 依赖清单
postgres/               # PostgreSQL 构建 Dockerfile + 部署手册
```

各组件的构建上下文文件按 `<组件名>/` 集中。新增工作流时，请遵循同样的命名与目录约定。

---

## 组件文档

- **PostgreSQL 部署手册**：[`postgres/DEPLOYMENT.md`](postgres/DEPLOYMENT.md) — 单机部署、主从复制（流式复制）、读写分离方案对比、扩展启用

---

## 设计约定

- **工作流文件名**：`<组件>-<动作>.yml`（kebab-case，组件在前）
- **工作流显示名**：`[Component] Action 描述（关键约束）` —— 便于在 Actions 列表里按组件筛选
- **触发方式**：统一 `workflow_dispatch`，不接受 push/PR/tag 自动触发
- **Node 24 兼容**：所有工作流设 `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true`，应对 2026-06 之后的 Node 20 弃用
- **多架构**：能跨架构的工作流统一通过 `target_arch` 输入 + QEMU 矩阵实现（amd64 / arm64 / both）
