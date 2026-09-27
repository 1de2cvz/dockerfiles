# 容器镜像规范

本规范约束组织内所有应用镜像的构建、运行、发布和文档。制定时参照了两个现有项目：`doc-vector`（单进程 Python 服务）和 `agent-runtime`（Python + Node 多进程一体化镜像）。第 10 节是这两个项目的现状对照和整改清单。

条目分两级：

- **【必须】**：新项目从第一天起满足；现有项目按第 10 节的清单整改。
- **【建议】**：没有特殊理由就照做；不照做的，在项目的镜像文档里写明原因。

---

## 1. 镜像边界

1. 【必须】一个产品一个镜像。不同产品不合并进同一个镜像；需要一起部署时，用 docker compose 编排多个容器。
2. 【必须】多进程镜像（一个容器跑多个进程，比如 `agent-runtime`）只在同时满足下面几条时允许：
   - 各进程属于同一个产品、同一个版本号发布，不会单独升级其中一个；
   - PID 1 是 init 进程（`tini`），负责转发信号、回收僵尸进程，见 5.2；
   - 任一进程退出，整个容器以该进程的退出码退出，交给 `--restart` 拉起，不在容器内自行重启；
   - 每个进程用独立的系统用户运行，只能访问自己需要的数据和密钥；
   - 进程之间只通过 `127.0.0.1` 通信，内部端口不监听 `0.0.0.0`；
   - 启动顺序靠等待前一个进程的健康检查通过，不靠 `sleep`。

## 2. 基础镜像

1. 【必须】标签里写明 Debian 代号，例如 `python:3.12-slim-trixie`，不写 `python:3.12-slim`。不带代号的标签会随上游切换 Debian 大版本，glibc 和系统库会悄悄变掉。
2. 【必须】统一使用 **Debian 13 (trixie)**。Debian 12 (bookworm) 已于 2026 年 6 月结束官方安全支持，转入 LTS 维护，新项目不再使用。
3. 【必须】基础镜像固定到 digest，并通过构建参数暴露，方便换成内网镜像仓库地址：

   ```dockerfile
   ARG PYTHON_IMAGE=python:3.12.14-slim-trixie@sha256:<digest>
   ARG NODE_IMAGE=node:22.23.3-trixie-slim@sha256:<digest>
   FROM ${PYTHON_IMAGE} AS runtime
   ```

   digest 由 Renovate 自动提 PR 升级（同一次升级里一起更新所有项目的同一个基础镜像），合并前走 CI 全量检查。
4. 【必须】一个镜像内的所有构建阶段使用同一个 Debian 代号。从别的镜像拷贝可执行文件时（例如从 Node 镜像拷 `node`），来源镜像的代号必须和目标一致，否则可能因为 glibc 版本不同而运行失败。
5. 【必须】语言运行时统一主版本：**Python 3.12**、**Node.js 22**。
   - Node 22 于 2027-04-30 结束维护，需在此之前统一升到 Node 24。
   - 升级主版本时所有项目一起升，不各自升。

## 3. 构建

1. 【必须】多阶段构建。最终镜像不含编译工具链、构建工具（`uv`、`npm`、`esbuild`、`vite`、`tsc` 等）和包管理器缓存。
2. 【必须】用 `COPY --chown=<用户>:<组>` 设置属主，不在 `COPY` 之后 `RUN chown -R`。后者会把整份文件再复制一层，镜像体积翻倍。
3. 【必须】仓库里有 `.dockerignore`，至少排除 `.git`、`.venv`、`node_modules`、测试数据和本地 `.env`。
4. 【必须】支持内网构建，构建参数统一命名：

   | 构建参数 | 默认值 | 用途 |
   |---|---|---|
   | `PYTHON_IMAGE`、`NODE_IMAGE` | 带 digest 的官方镜像 | 基础镜像 |
   | `UV_IMAGE` | `ghcr.io/astral-sh/uv:<固定版本>` | 提供 `uv` 可执行文件 |
   | `PIP_INDEX_URL` | `https://pypi.org/simple` | PyPI 源。用 uv 时在 Dockerfile 里转成 `UV_DEFAULT_INDEX` |
   | `NPM_REGISTRY` | `https://registry.npmjs.org` | npm 源，传给 `npm ci --registry` |
   | `--secret id=ca_cert` | 无 | HTTPS 解密代理的 CA 证书，只在安装依赖的 `RUN` 里挂载，不进镜像。按工具设置：pip 用 `PIP_CERT`，uv 用 `SSL_CERT_FILE`，npm 用 `NODE_EXTRA_CA_CERTS` |

5. 【必须】`uv` 固定版本，从 `UV_IMAGE` 拷入（`COPY --from=${UV_IMAGE} /uv /bin/uv`），不用 `pip install uv`。
6. 【建议】依赖安装使用 BuildKit 缓存挂载（`RUN --mount=type=cache,...`），先复制锁文件安装依赖，再复制源码，让代码改动不触发依赖重装。

## 4. 依赖

1. 【必须】所有依赖都由锁文件锁定，构建时不解析新版本：
   - Python：`uv.lock`，安装用 `uv sync --frozen --no-dev`。不再导出 `requirements.txt` 这样的中间文件；确实需要时，由 CI 从 `uv.lock` 生成并校验一致。
   - Node：`package-lock.json`，安装用 `npm ci`（生产依赖加 `--omit=dev`）。
2. 【必须】容器运行时不安装包，也不访问 PyPI、npm。
3. 【必须】最终镜像里没有编译工具链，所以所有带原生代码的依赖必须在每个目标架构上都有预编译包（wheel / prebuilt）。开启 arm64 构建时，CI 负责验证这一点。
4. 【建议】为安全敏感的组件（持有密钥、对外暴露）单独建虚拟环境并尽量减少依赖，参照 `agent-runtime` 的模型网关。

## 5. 运行时

### 5.1 用户

1. 【必须】应用进程不以 root 运行。
   - 单进程镜像：用 `USER` 指令切换用户。
   - 多进程镜像：root 只用于启动脚本修正数据卷属主，然后用 `setpriv` 降权启动各进程。
2. 【必须】UID/GID 固定且 ≥ 10000。不使用 1000，它通常就是宿主机上的第一个普通用户，挂载宿主机目录时属主会混淆。
3. 【必须】UID 按角色统一登记，新角色在此表追加：

   | UID/GID | 用户名 | 角色 |
   |---|---|---|
   | 10001 | `app` | 默认应用用户（单进程镜像都用它） |
   | 10002 | `gateway` | 持有外部服务密钥的网关进程 |
   | 10003 | `node` | 多进程镜像中的 Node 服务进程 |

4. 【必须】启动脚本修正属主时，只改属主不对的文件（`find ... ! -uid <uid> -exec chown ...`），不在每次启动时全量 `chown -R`。

### 5.2 PID 1 与信号

1. 【必须】单进程镜像：用 exec 形式启动（`CMD ["uvicorn", ...]`，或在 shell 脚本最后一步 `exec`），让应用本身成为 PID 1，能收到 `SIGTERM`。
2. 【必须】多进程镜像：`ENTRYPOINT ["tini", "--", "<启动脚本>"]`。bash 做 PID 1 时不会回收被托孤的孙进程，工具调用、子进程多的服务会积累僵尸进程。
3. 【必须】收到 `SIGTERM` 后 10 秒内优雅退出（Docker 默认 10 秒后发 `SIGKILL`）。

### 5.3 端口与健康检查

1. 【必须】`EXPOSE` 声明所有对外端口。只在容器内使用的端口监听 `127.0.0.1`，不 `EXPOSE`。
2. 【必须】定义 `HEALTHCHECK`。检查命令使用镜像已有的运行时（`python -c` / `node -e`），不为此安装 `curl`。
3. 【建议】健康检查路径统一为 `/healthz`。已对外公布的旧路径保留，另加 `/healthz`。
4. 【建议】健康检查只反映本进程能否提供服务，不检查外部依赖（数据库、模型服务），避免外部服务抖动导致容器被反复判为不健康。外部依赖的状态另设接口（如 `/readyz`）。
5. 【建议】参数统一：间隔 30 秒、超时 5 秒、连续失败 3 次；启动宽限按实际启动时间设置。

### 5.4 数据与目录

1. 【必须】所有持久化数据放在声明为 `VOLUME` 的目录下，容器内其他位置视为只读。
2. 【必须】源码目录（`/app`）在运行时不写入。
3. 【建议】新项目的数据根目录统一为 `/data`，按用途分子目录。已有项目不强制迁移。
4. 【必须】首次启动时由应用自己初始化数据卷（建目录、拷默认配置），不要求部署人员手工准备。

### 5.5 环境变量与配置

1. 【必须】所有配置通过环境变量传入，仓库根目录提供完整的 `.env.example`（每个变量带注释：含义、默认值、是否必填）。
2. 【必须】密钥不写进 Dockerfile 的 `ARG` 或 `ENV`，也不打进镜像。
3. 【必须】缺少必填配置或配置互相矛盾时，容器立即以退出码 **64** 退出，并在日志里写明缺什么。
4. 【建议】多进程镜像中，密钥只传给需要它的进程（参照 `agent-runtime` 启动 Node 进程前剥离 `GATEWAY_*`）。
5. 【必须】镜像统一预设：

   | 变量 | 值 |
   |---|---|
   | `LANG` | `C.UTF-8` |
   | `TZ` | `Asia/Shanghai`（确认镜像内有 `/usr/share/zoneinfo`，没有就安装 `tzdata`） |
   | `PYTHONUNBUFFERED`、`PYTHONDONTWRITEBYTECODE` | `1`（有 Python 时） |
   | `NODE_ENV` | `production`（有 Node 时） |

6. 【必须】日志输出到 stdout/stderr，不写日志文件。

## 6. 安全

1. 【必须】CI 用 Trivy 扫描最终镜像：存在已有修复版本的 CRITICAL 漏洞时构建失败；HIGH 漏洞列入报告，一周内处理。
2. 【必须】最终镜像不含 `.git`、测试代码、开发依赖、本地 `.env`。
3. 【必须】生产部署引用版本号或 digest，不引用 `latest`。

## 7. 版本、标签与发布

1. 【必须】版本号采用语义化版本，**git tag `vX.Y.Z` 是唯一来源**。代码里如果也有版本号（如 `app/__init__.py`），CI 校验两者一致，不一致则发布失败；或者改为构建时通过 `ARG VERSION` 注入。
2. 【必须】镜像仓库：`ghcr.io/<所有者>/<镜像名>`。
3. 【必须】标签规则（用 `docker/metadata-action` 生成）：

   | 触发 | 标签 |
   |---|---|
   | 推送到 `main` | `main`、`sha-<7 位提交号>` |
   | 打 tag `vX.Y.Z` | `X.Y.Z`、`X.Y`、`sha-<7 位提交号>`、`latest` |

   `latest` 只指向最新的正式版本，不指向 `main`。
4. 【必须】镜像带 OCI 标签：`org.opencontainers.image.source`、`revision`、`version`、`created`（`metadata-action` 自动生成）。
5. 【必须】打 tag 时，CI 为每个架构导出离线包（`docker save | gzip`），连同 SHA-256 校验文件上传到 GitHub Release，文件名 `<镜像名>-<版本>-<架构>.tar.gz`。
6. 【必须】默认构建 `linux/amd64`。需要 arm64 时在仓库变量 `IMAGE_PLATFORMS` 中设置为 `linux/amd64,linux/arm64`。

## 8. CI

1. 【必须】所有项目调用本仓库提供的可复用 workflow 构建镜像，不各自复制一份构建逻辑（可复用 workflow 待建）。
2. 【必须】各触发条件下 CI 做的事：

   | 触发 | 构建 | 冒烟测试 | Trivy | 推送 | 离线包与环境清单 |
   |---|---|---|---|---|---|
   | PR | ✅ | ✅ | ✅ | — | — |
   | 推送到 `main` | ✅ | ✅ | ✅ | ✅ | — |
   | tag `vX.Y.Z` | ✅ | ✅ | ✅ | ✅ | ✅ |

3. 【必须】冒烟测试针对构建出的镜像本身运行，至少覆盖：
   - 用 `.env.example` 加测试值启动，健康检查在宽限期内变为 healthy；
   - 调用一个核心接口，返回正确；
   - `docker stop` 在 10 秒内退出，退出码为 0；
   - 重启容器后，数据卷里的数据仍在。

   项目已有的端到端检查（如 `agent-runtime` 的 `scripts/check_allinone.ts`）可以直接作为冒烟测试。

## 9. 文档

1. 【必须】每个镜像有一份《运行环境与依赖》文档，章节统一如下：
   1. 概览（一句话 + 架构图）
   2. 系统与运行时
   3. 运行用户
   4. 进程、端口与健康检查
   5. 应用依赖（只列直接依赖和作用）
   6. 镜像内目录与数据卷
   7. 环境变量（镜像预设 / 启动脚本设置 / 必填 / 常用可选）
   8. 运行时的外部依赖
   9. 宿主机要求
   10. 构建方式与版本固定
2. 【必须】手写文档只写不随构建变化的内容。具体版本号、全部依赖清单、镜像大小由 CI 在打 tag 时从镜像里读取，生成 `环境清单.md` 附在 Release 上，文档里链接过去，避免手工抄写后过时。

---

## 10. 现状对照与整改清单

### 10.1 对照表

✅ 符合　⚠️ 部分符合　❌ 不符合

| 条目 | doc-vector | agent-runtime |
|---|---|---|
| 2.1 标签写明 Debian 代号 | ❌ `python:3.12-slim`（实际解析为 trixie） | ✅ `-bookworm` |
| 2.2 使用 trixie | ✅ | ❌ bookworm |
| 2.3 基础镜像固定 digest | ❌ | ❌ |
| 2.3 基础镜像可替换 | ✅ `PYTHON_IMAGE` | ❌ |
| 3.1 多阶段构建 | ✅ | ✅ |
| 3.4 内网构建参数、CA 证书 | ✅ | ❌ |
| 3.5 uv 固定版本 | —（未用 uv） | ❌ `pip install uv` |
| 4.1 按锁文件安装 | ⚠️ 经 `requirements.txt` 中转 | ✅ `uv sync --frozen`、`npm ci` |
| 5.1 非 root，UID ≥ 10000 | ✅ 10001 | ⚠️ `node` 用户为 1000 |
| 5.2 PID 1 | ✅ exec uvicorn | ⚠️ bash 做 PID 1，无 tini |
| 5.3 HEALTHCHECK，不依赖 curl | ✅ | ✅ |
| 5.4 数据集中在 VOLUME | ✅ `/data/*` | ✅ `/app/data` |
| 5.5 必填配置缺失退出 64 | 未知 | ✅ |
| 5.5 预设 `TZ` | ✅ | ❌ |
| 7.1 语义化版本，以 tag 为准 | ⚠️ 版本在 `app/__init__.py` | ❌ 无版本号 |
| 7.3 `latest` 只指正式版 | ⚠️ | ❌ `latest` 指向 `main` |
| 7.2 CI 推送到 ghcr.io | ❌ 本地脚本构建 | ✅ |
| 7.5 CI 生成离线包 | ❌ 本地脚本导出 | ❌ |
| 8.3 CI 冒烟测试 | ⚠️ 有 `smoke_test.py`，未接入 CI | ✅ `check_allinone.ts` |

### 10.2 doc-vector 整改

1. 基础镜像改为 `python:3.12.14-slim-trixie@sha256:<digest>`。
2. 构建阶段改为 `uv sync --frozen --no-dev`，删除 `requirements.txt` 中转。
3. 版本号以 git tag 为准，CI 校验 `app/__init__.py` 与 tag 一致。
4. 查清镜像体积：解压后 933 MB，其中 venv 546 MB，剩余约 390 MB 明显多于基础镜像本身。用 `docker history doc-vector:1.0.0` 找出大的层，重点检查有没有 `RUN chown -R` 造成的重复层（第 3.2 条）。
5. 接入可复用 workflow：推送 ghcr.io、生成离线包；`scripts/smoke_test.py` 作为冒烟测试接入 CI。`scripts/build_image.sh` 保留给本地和内网构建用。
6. 确认 `milvus-lite`、`pymupdf` 有 arm64 wheel，再决定是否开启 arm64。

### 10.3 agent-runtime 整改

1. 所有阶段从 bookworm 换到 trixie：`python:3.12-slim-trixie`、`node:22-trixie-slim`，并固定 digest；增加 `PYTHON_IMAGE`、`NODE_IMAGE` 构建参数。
2. 增加 `PIP_INDEX_URL`、`NPM_REGISTRY` 构建参数和 `ca_cert` secret 支持。
3. `pip install uv` 改为从固定版本的 `UV_IMAGE` 拷入。
4. 安装 `tini`，`ENTRYPOINT ["tini", "--", "agent-runtime"]`。
5. `node` 用户 UID 从 1000 改为 10003。启动脚本已有"只改属主不对的文件"的逻辑，现有数据卷会在首次启动新版本时自动迁移；用宿主机目录挂载数据卷的部署需要提前说明。
6. 预设 `TZ=Asia/Shanghai`，确认有时区数据。
7. 引入语义化版本和 tag 发布；`latest` 改为只指正式版本。
8. 接入可复用 workflow，打 tag 时生成离线包和环境清单。
9. 数据目录保持 `/app/data`，不迁移。
