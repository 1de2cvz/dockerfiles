# 共享基础镜像 `base`

所有项目的镜像都基于它构建：环境只维护这一套，每个项目在上面加自己的依赖和代码，仍然各自发布独立的镜像。

## 两个变体

| 镜像 | 用在哪 | 内容 |
|---|---|---|
| `ghcr.io/1de2cvz/base:py3.12-node24` | 项目的**最终阶段** | Python、Node、tini、时区、`app` 用户，`NODE_ENV=production` |
| `ghcr.io/1de2cvz/base:py3.12-node24-build` | 项目的**构建阶段** | 在上一行基础上加 npm、npx、uv；不设 `NODE_ENV` |

两者来自同一个 Dockerfile 的同一个 `core` 阶段，所以构建阶段和运行阶段的 glibc、Python、Node 完全一致，构建阶段装好的虚拟环境和 `node_modules` 可以直接复制到运行阶段。

标签：

- `py3.12-node24`、`py3.12-node24-build`：滚动标签，每次基础镜像更新都会指向新版本。
- `py3.12-node24-sha-<提交号>`、`py3.12-node24-build-sha-<提交号>`：不可变。
- 项目里按 digest 引用（`...:py3.12-node24@sha256:...`），由 Renovate 升级。

平台：`linux/amd64`、`linux/arm64`。

## 镜像内容

| 项 | 值 |
|---|---|
| 操作系统 | Debian 13 (trixie) |
| Python | 3.12（官方 `python:3.12-slim-trixie`，装在 `/usr/local`） |
| Node.js | 24 LTS（只拷入 `node` 可执行文件；build 变体另有 npm） |
| uv | 0.12.19（只在 build 变体） |
| init | `tini`（`/usr/bin/tini`），多进程镜像用作 PID 1 |
| 用户 | `app`，uid/gid 10001，无 home，无登录 shell。基础镜像**不切换用户**，项目在最终阶段自己写 `USER app` |
| 工作目录 | `/app`（属主 root） |
| 大小 | runtime 解压后约 245 MB，其中 Node 约 121 MB |

环境变量：

| 变量 | 值 | 变体 |
|---|---|---|
| `LANG` | `C.UTF-8` | 都有 |
| `TZ` | `Asia/Shanghai`（`/etc/localtime` 也已设置） | 都有 |
| `PYTHONUNBUFFERED`、`PYTHONDONTWRITEBYTECODE` | `1` | 都有 |
| `NODE_ENV` | `production` | runtime |
| `UV_PYTHON_DOWNLOADS=never`、`UV_PYTHON=/usr/local/bin/python3`、`UV_LINK_MODE=copy` | — | build |

## 项目怎么用

Python 服务的完整模板见 [`templates/python-service.Dockerfile`](../../templates/python-service.Dockerfile)，结构是：

```dockerfile
ARG BUILD_IMAGE=ghcr.io/1de2cvz/base:py3.12-node24-build
ARG RUNTIME_IMAGE=ghcr.io/1de2cvz/base:py3.12-node24

FROM ${BUILD_IMAGE} AS deps
# uv sync --frozen --no-dev → /opt/venv

FROM ${RUNTIME_IMAGE}
COPY --from=deps /opt/venv /opt/venv
COPY app/ /app/app/
USER app
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port \"$PORT\""]
```

有 Node 部分的项目，在同一个 build 镜像里用 `npm ci` 安装、打包，再把 `dist/` 和生产依赖复制到最终阶段；不需要再引入 `node:*` 镜像。

多进程项目：

```dockerfile
ENTRYPOINT ["tini", "--", "/usr/local/bin/<启动脚本>"]
```

需要其他用户时按 [STANDARD.md](../../STANDARD.md) 5.1 的 UID 登记表创建。

## 内网构建

| 构建参数 / secret | 作用 |
|---|---|
| `PYTHON_IMAGE`、`NODE_IMAGE`、`UV_IMAGE` | 换成内网镜像仓库地址 |
| `APT_MIRROR` | Debian 源，例如 `https://mirrors.aliyun.com`；留空用官方源 |
| `--secret id=ca_cert,src=<证书>` | HTTPS 解密代理或内网源的 CA，只在装包时使用，不进镜像 |

```bash
docker build images/base --target runtime -t base:py3.12-node24 \
  --build-arg APT_MIRROR=https://mirrors.aliyun.com \
  --secret id=ca_cert,src=/path/to/ca.crt
```

## 检查

`test.sh` 检查两个变体的内容（系统、版本、时区、字符集、用户、tini，以及 npm / uv 只在 build 里）：

```bash
images/base/test.sh base:py3.12-node24 base:py3.12-node24-build
```

CI（`.github/workflows/base-image.yml`）在 PR 上构建并运行检查和漏洞扫描，合并到 `main` 后发布两个变体。

## 升级

- **补丁版本和 digest**：Renovate 每周一提 PR，CI 通过后合并即可。
- **Python / Node 主、次版本**：Renovate 不会自动提。手工修改 Dockerfile 的 `PYTHON_IMAGE` / `NODE_IMAGE` 和 workflow 的 `TAG`（例如 `py3.12-node26`），作为新标签发布；旧标签保留，各项目按自己的节奏切换。
- Node 24 维护期到 2028-04-30；下一个 LTS 是 Node 26（2026 年 10 月进入 LTS）。
