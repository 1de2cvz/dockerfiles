# 共享基础镜像 `base`

所有项目的镜像都基于它构建：环境只维护这一套，每个项目在上面加自己的依赖和代码，仍然各自发布独立的镜像。

## 变体

| 镜像标签 | Dockerfile 目标 | 用在哪 | 内容 |
|---|---|---|---|
| `py3.12-node24` | `runtime` | 项目的**最终阶段** | Python、Node、tini、时区、`app` 用户，`NODE_ENV=production` |
| `py3.12-node24-build` | `build` | 项目的**构建阶段** | 上一行 + npm、npx、uv；不设 `NODE_ENV` |
| `py3.12-node24-java8` | `runtime-java` | 用 Java 的项目的最终阶段 | `runtime` + Java 8 **JRE** + fontconfig |
| `py3.12-node24-java8-build` | `build-java` | 用 Java 的项目的构建阶段 | `build` + Java 8 **JDK** + fontconfig |

镜像完整地址为 `ghcr.io/1de2cvz/base:<标签>`。所有变体来自同一个 Dockerfile 的同一个 `core` 阶段，所以构建阶段和运行阶段的 glibc、Python、Node 完全一致，构建阶段装好的虚拟环境和 `node_modules` 可以直接复制到运行阶段。

标签：

- 上表的标签是滚动的，每次基础镜像更新都会指向新版本。
- `<标签>-sha-<提交号>`：不可变。
- 项目里按 digest 引用（`...:py3.12-node24@sha256:...`），由 Renovate 升级。

平台：`linux/amd64`、`linux/arm64`。

## 镜像内容

| 项 | 值 |
|---|---|
| 操作系统 | Debian 13 (trixie) |
| Python | 3.12（官方 `python:3.12-slim-trixie`，装在 `/usr/local`） |
| Node.js | 24 LTS（只拷入 `node` 可执行文件；build 变体另有 npm） |
| Java | 8，Eclipse Temurin（只在 java 变体；`/opt/java/openjdk`，已加入 `PATH`，`JAVA_HOME` 已设置） |
| uv | 0.12.19（只在 build 变体） |
| init | `tini`（`/usr/bin/tini`），多进程镜像用作 PID 1 |
| 装包工具 | `apt-install <包>...`：处理内网 CA 证书并清理索引，项目需要系统包时用它 |
| 用户 | `app`，uid/gid 10001，无 home，无登录 shell。基础镜像**不切换用户**，项目在最终阶段自己写 `USER app` |
| 工作目录 | `/app`（属主 root） |

解压后的大小：

| 变体 | 大小 |
|---|---|
| `py3.12-node24` | 约 245 MB（其中 Node 约 121 MB） |
| `py3.12-node24-java8` | 约 350 MB（其中 JRE 约 106 MB） |
| `py3.12-node24-java8-build` | 约 460 MB（其中 JDK 约 148 MB） |

环境变量：

| 变量 | 值 | 变体 |
|---|---|---|
| `LANG` | `C.UTF-8` | 全部 |
| `TZ` | `Asia/Shanghai`（`/etc/localtime` 也已设置） | 全部 |
| `PYTHONUNBUFFERED`、`PYTHONDONTWRITEBYTECODE` | `1` | 全部 |
| `NODE_ENV` | `production` | runtime、runtime-java |
| `UV_PYTHON_DOWNLOADS=never`、`UV_PYTHON=/usr/local/bin/python3`、`UV_LINK_MODE=copy` | — | build、build-java |
| `JAVA_HOME` | `/opt/java/openjdk` | java 变体 |

Java 已验证：时区为 `Asia/Shanghai`，`file.encoding` 为 UTF-8，能识别容器的内存和 CPU 限制。只带 DejaVu 字体，需要中文字体的项目自行 `apt-install fonts-noto-cjk`。

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

- **有 Node 部分**：在同一个 build 镜像里用 `npm ci` 安装、打包，再把 `dist/` 和生产依赖复制到最终阶段；不需要再引入 `node:*` 镜像。
- **有 Java 部分**：构建阶段用 `-java8-build`，用项目自带的 `./mvnw` 或 `./gradlew` 构建（基础镜像不带 Maven / Gradle）；最终阶段用 `-java8`，只复制 jar。JVM 参数见 [STANDARD.md](../../STANDARD.md) 5.7。
- **多进程**：`ENTRYPOINT ["tini", "--", "/usr/local/bin/<启动脚本>"]`。
- **需要其他用户**：按 [STANDARD.md](../../STANDARD.md) 5.1 的 UID 登记表创建。
- **本地开发**：项目根目录放 [`templates/mise.toml`](../../templates/mise.toml)，本地运行时版本与镜像一致。

## 内网构建

| 构建参数 / secret | 作用 |
|---|---|
| `PYTHON_IMAGE`、`NODE_IMAGE`、`UV_IMAGE`、`JRE_IMAGE`、`JDK_IMAGE` | 换成内网镜像仓库地址 |
| `APT_MIRROR` | Debian 源，例如 `https://mirrors.aliyun.com`；留空用官方源 |
| `--secret id=ca_cert,src=<证书>` | HTTPS 解密代理或内网源的 CA，只在装包时使用，不进镜像 |

```bash
docker build images/base --target runtime -t base:py3.12-node24 \
  --build-arg APT_MIRROR=https://mirrors.aliyun.com \
  --secret id=ca_cert,src=/path/to/ca.crt
```

## 检查

- `test.sh`：按 `versions.env` 检查各变体的系统、版本、时区、字符集、用户、tini、Java 字体和编码，以及 npm / uv / javac 只出现在 build 变体里。

  ```bash
  images/base/test.sh <runtime> <build> [<runtime-java> <build-java>]
  ```

- `scripts/check_versions.py`：核对 Dockerfile 与 `versions.env` 一致，并查询各运行时的停止维护日期。加 `--offline` 只做一致性检查。

CI：

- `.github/workflows/base-image.yml`：PR 上构建四个变体，运行一致性检查、`test.sh` 和漏洞扫描；合并到 `main` 后发布。
- `.github/workflows/versions.yml`：每周一检查维护期，剩余不足 180 天时开 issue 提醒。

## 升级

- **补丁版本和 digest**：Renovate 每周一提 PR，CI 通过后合并即可。
- **主、次版本**（例如 Node 24 → 26）：Renovate 不会自动提，由人决定。
  1. 改 `versions.env`（例如 `NODE=26`）。
  2. 改 Dockerfile 里对应的上游镜像，改完运行 `scripts/check_versions.py --offline` 确认一致。
  3. 提 PR，CI 通过后合并，发布新标签（例如 `py3.12-node26`）。旧标签保留，各项目在约定期限内切换，并同步修改各自的 `mise.toml`、`engines`、`requires-python`。
  4. 更新 [STANDARD.md](../../STANDARD.md) 2.4 的版本表。
