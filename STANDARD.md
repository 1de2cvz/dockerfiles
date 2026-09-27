# 容器镜像规范

本规范约束组织内所有应用镜像的构建、运行、发布和文档。所有项目基于同一个共享基础镜像（第 2 节）。制定时参照了两个现有项目：`doc-vector`（单进程 Python 服务）和 `agent-runtime`（Python + Node 多进程一体化镜像）。第 10 节是这两个项目的现状对照和整改清单。

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

所有项目共用一个基础镜像 [`images/base`](images/base/README.md)：Python 3.12 + Node.js 24，Debian 13 (trixie)，另有带 Java 8 的变体。环境只维护这一套，每个项目在上面加自己的依赖和代码，仍然各自发布独立的镜像。

1. 【必须】项目的构建阶段和最终阶段都基于共享基础镜像，不直接使用 `python:*`、`node:*`、`eclipse-temurin:*` 等官方镜像。按是否用到 Java 选变体：

   | 项目 | 构建阶段 | 最终阶段 |
   |---|---|---|
   | 不用 Java | `base:py3.12-node24-build` | `base:py3.12-node24` |
   | 用 Java | `base:py3.12-node24-java8-build`（JDK） | `base:py3.12-node24-java8`（JRE） |

   Java 单独做成变体，是因为 JRE 8 约 106 MB，不用 Java 的项目不应该背这个体积和漏洞面。基础镜像都通过构建参数引用，固定到 digest，由 Renovate 升级：

   ```dockerfile
   ARG BUILD_IMAGE=ghcr.io/1de2cvz/base:py3.12-node24-build@sha256:<digest>
   ARG RUNTIME_IMAGE=ghcr.io/1de2cvz/base:py3.12-node24@sha256:<digest>
   ```

2. 【必须】项目需要的系统包、运行时版本和基础镜像不同时，先提出来讨论能不能加进基础镜像，不在项目里另起一套环境。确实只有一个项目需要的系统包，在项目的最终阶段用基础镜像自带的 `apt-install <包>` 安装（自动处理内网 CA 证书、清理索引）。
3. 基础镜像自身遵守以下规则（维护 `images/base` 时适用）：
   - 上游镜像标签写明 Debian 代号，例如 `python:3.12-slim-trixie`，不写 `python:3.12-slim`。不带代号的标签会随上游切换 Debian 大版本，glibc 和系统库会悄悄变掉。
   - 统一使用 **Debian 13 (trixie)**。Debian 12 (bookworm) 已于 2026-07-11 结束常规安全支持，转入 LTS 维护。
   - 上游镜像固定到 digest。补丁版本和 digest 由 Renovate 自动提 PR，CI 检查通过后合并。
   - 所有构建阶段使用同一个 Debian 代号。从别的镜像拷贝可执行文件时（例如从 Node 镜像拷 `node`），来源的代号必须和目标一致，否则可能因为 glibc 版本不同而无法运行。例外：Temurin 的 JDK/JRE 是与发行版无关的通用构建，可以从任意 Temurin 镜像拷贝。
4. 【必须】运行时主版本以 [`images/base/versions.env`](images/base/versions.env) 为唯一来源，当前为：

   | 运行时 | 主版本 | 停止维护 | 下一步 |
   |---|---|---|---|
   | Debian | 13 (trixie) | 常规安全支持到 2028-08-09，LTS 到 2030-06-30 | — |
   | Python | 3.12 | 2028-10-31 | 2028 年上半年评估 3.14 |
   | Node.js | 24 LTS | 2028-04-30 | Node 26 于 2026-10-28 进入 LTS，2027 年评估 |
   | Java | 8（Eclipse Temurin） | 2030-12-31 | 由用到 Java 的项目决定是否升到 17 / 21 |

   日期来自 endoflife.date，以第 5 条的自动检查结果为准；本表只在升级时手工更新。
5. 【必须】版本维护靠自动检查，不靠人记：
   - `scripts/check_versions.py` 核对 Dockerfile 里的上游镜像与 `versions.env` 一致，并查询每个运行时的停止维护日期。
   - 基础镜像的 CI 在每个 PR 上做一致性检查，不一致就失败。
   - `versions` 工作流每周一运行：剩余不足 180 天时自动开 issue「运行时版本需要升级」，情况解除后自动关闭；已经停止维护时工作流失败。
   - 升级主版本的步骤：改 `versions.env` → 改 Dockerfile 的上游镜像 → CI 通过后发布新的环境标签（例如 `py3.12-node26`）。旧标签保留，同时给出各项目的切换期限；期限过后旧标签停止更新。
6. 【必须】项目在代码里声明运行时版本，让本地开发、IDE 和 CI 在版本不对时尽早报错，而不是等到构建镜像：

   | 运行时 | 在项目里声明 |
   |---|---|
   | 全部 | 根目录放 [`mise.toml`](templates/mise.toml)，本地用 mise 自动切换到相同的主版本 |
   | Python | `pyproject.toml`：`requires-python = ">=3.12,<3.13"` |
   | Node | `package.json`：`"engines": {"node": ">=24 <25"}`，并在 `.npmrc` 写 `engine-strict=true` |
   | Java | Maven：`maven.compiler.source` / `target` 设为 `1.8`；Gradle：`sourceCompatibility = 1.8` |

   基础镜像升级主版本时，以上声明随切换一起修改。

## 3. 构建

1. 【必须】多阶段构建。最终镜像不含编译工具链、构建工具（`uv`、`npm`、`esbuild`、`vite`、`tsc` 等）和包管理器缓存。
2. 【必须】用 `COPY --chown=<用户>:<组>` 设置属主，不在 `COPY` 之后 `RUN chown -R`。后者会把整份文件再复制一层，镜像体积翻倍。
3. 【必须】仓库里有 `.dockerignore`，至少排除 `.git`、`.venv`、`node_modules`、测试数据和本地 `.env`。
4. 【必须】支持内网构建，构建参数统一命名：

   | 构建参数 | 默认值 | 用途 |
   |---|---|---|
   | `BUILD_IMAGE`、`RUNTIME_IMAGE` | 带 digest 的共享基础镜像 | 构建阶段 / 最终阶段的基础镜像 |
   | `PIP_INDEX_URL` | `https://pypi.org/simple` | PyPI 源。用 uv 时在 Dockerfile 里转成 `UV_DEFAULT_INDEX` |
   | `NPM_REGISTRY` | `https://registry.npmjs.org` | npm 源，传给 `npm ci --registry` |
   | `APT_MIRROR` | 空（官方源） | Debian 源，只在需要 `apt-get install` 时使用 |
   | `--secret id=ca_cert` | 无 | HTTPS 解密代理的 CA 证书，只在安装依赖的 `RUN` 里挂载，不进镜像。按工具设置：pip 用 `PIP_CERT`，uv 用 `SSL_CERT_FILE`，npm 用 `NODE_EXTRA_CA_CERTS` |

5. 【必须】`uv`、`npm` 使用 build 基础镜像里的版本，不在项目里 `pip install uv` 或另外安装。
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
3. 【必须】UID 按角色统一登记，新角色在此表追加。基础镜像已创建 `app`，其他用户由项目按此表创建：

   | UID/GID | 用户名 | 角色 |
   |---|---|---|
   | 10001 | `app` | 默认应用用户（单进程镜像都用它） |
   | 10002 | `gateway` | 持有外部服务密钥的网关进程 |
   | 10003 | `node` | 多进程镜像中的 Node 服务进程 |

4. 【必须】启动脚本修正属主时，只改属主不对的文件（`find ... ! -uid <uid> -exec chown ...`），不在每次启动时全量 `chown -R`。

### 5.2 PID 1 与信号

1. 【必须】单进程镜像：用 exec 形式启动（`CMD ["uvicorn", ...]`，或在 shell 脚本最后一步 `exec`），让应用本身成为 PID 1，能收到 `SIGTERM`。
2. 【必须】多进程镜像：`ENTRYPOINT ["tini", "--", "<启动脚本>"]`（基础镜像已包含 `tini`）。bash 做 PID 1 时不会回收被托孤的孙进程，工具调用、子进程多的服务会积累僵尸进程。
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
5. 【必须】镜像统一预设（基础镜像已设置，项目不要覆盖）：

   | 变量 | 值 |
   |---|---|
   | `LANG` | `C.UTF-8` |
   | `TZ` | `Asia/Shanghai` |
   | `PYTHONUNBUFFERED`、`PYTHONDONTWRITEBYTECODE` | `1`（有 Python 时） |
   | `NODE_ENV` | `production`（有 Node 时） |

6. 【必须】日志输出到 stdout/stderr，不写日志文件。

### 5.6 前端静态文件与 Nginx

1. 【必须】共享基础镜像和应用镜像里不装 Nginx。
2. 【必须】前端页面在构建阶段编译成静态文件，运行时不跑 Vite、webpack 等开发服务器。按部署方式选择：

   | 情况 | 做法 |
   |---|---|
   | 前端和某个后端同属一个产品 | 由后端同源托管静态文件（`agent-runtime` 的做法），不需要 Nginx |
   | 独立的纯前端项目 | 单独一个镜像，基于官方 `nginxinc/nginx-unprivileged`（非 root，固定 digest），只放静态文件和站点配置 |
   | HTTPS、域名、多服务按路径转发 | 部署层统一一个反向代理（Nginx 或 Caddy），单独一个容器，放在 compose 里，不放进应用镜像 |

3. 【必须】页面只从同源加载脚本和字体，不引用外部 CDN，保证内网可用。

### 5.7 Java 进程

1. 【必须】设置 `-XX:MaxRAMPercentage=75.0`。JVM 默认只用容器内存限制的 1/4 作为最大堆，浪费内存，也容易误判为内存不足。
2. 【建议】用 `JAVA_OPTS` 之类的环境变量传入 JVM 参数，不写死在启动命令里。不要用 `JAVA_TOOL_OPTIONS`：它会让每次启动 JVM 都在日志里打印一行提示。
3. 【必须】需要显示或生成中文（图片、PDF、Excel 等）的项目自行安装中文字体：`apt-install fonts-noto-cjk`。基础镜像只带 DejaVu 字体。

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
| 2.1 使用共享基础镜像 | ❌ `python:3.12-slim` | ❌ `python:3.12-slim-bookworm` + `node:22-bookworm-slim` |
| 2.1 基础镜像固定 digest | ❌ | ❌ |
| 2.1 基础镜像可替换 | ✅ `PYTHON_IMAGE` | ❌ |
| 2.4 运行时主版本（Node 24） | —（不用 Node） | ❌ Node 22 |
| 3.1 多阶段构建 | ✅ | ✅ |
| 3.4 内网构建参数、CA 证书 | ✅ | ❌ |
| 3.5 使用基础镜像的 uv / npm | —（未用 uv） | ❌ `pip install uv` |
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
| 2.6 在项目里声明运行时版本 | 未知 | 未知 |
| 8.3 CI 冒烟测试 | ⚠️ 有 `smoke_test.py`，未接入 CI | ✅ `check_allinone.ts` |

### 10.2 doc-vector 整改

1. 构建阶段改为 `FROM` 基础镜像的 build 变体，用 `uv sync --frozen --no-dev` 安装到 `/opt/venv`，删除 `requirements.txt` 中转；最终阶段 `FROM` runtime 变体。可直接参照 [`templates/python-service.Dockerfile`](templates/python-service.Dockerfile)。
2. 删除 Dockerfile 里自己设置的时区、字符集、`app` 用户，改用基础镜像提供的（UID 同为 10001，数据卷不受影响）。
3. 版本号以 git tag 为准，CI 校验 `app/__init__.py` 与 tag 一致。
4. 查清镜像体积：解压后 933 MB，其中 venv 546 MB，剩余约 390 MB 明显多于基础镜像本身。用 `docker history doc-vector:1.0.0` 找出大的层，重点检查有没有 `RUN chown -R` 造成的重复层（第 3.2 条）。
   - 注意：基础镜像含 Node（约 121 MB），`doc-vector` 用不到，换基础镜像后体积会相应增加。这是统一环境的代价；如果离线包大小敏感，先完成上一步的体积排查。
5. 接入可复用 workflow：推送 ghcr.io、生成离线包；`scripts/smoke_test.py` 作为冒烟测试接入 CI。`scripts/build_image.sh` 保留给本地和内网构建用。
6. 确认 `milvus-lite`、`pymupdf` 有 arm64 wheel，再决定是否开启 arm64。
7. 按 2.6 在项目里声明版本：根目录加 `mise.toml`，`pyproject.toml` 写 `requires-python = ">=3.12,<3.13"`。

### 10.3 agent-runtime 整改

1. 五个构建阶段都改为 `FROM` 基础镜像的 build 变体（`sidecar-deps`、`sidecar-build`、`web` 用其中的 npm，`gateway-deps` 用其中的 uv），最终阶段 `FROM` runtime 变体。不再单独引入 `node:*` 镜像，也不再 `pip install uv`；Debian 随之从 bookworm 换到 trixie。
2. Node 从 22 升到 24。重点回归：`node:sqlite`（会话账本）、`mysql2`、pi（确认 `@earendil-works/pi-coding-agent` 的 `engines` 允许 Node 24），然后跑完整的 `scripts/check_allinone.ts`。
3. 增加 `PIP_INDEX_URL`、`NPM_REGISTRY` 构建参数和 `ca_cert` secret 支持。
4. `ENTRYPOINT ["tini", "--", "agent-runtime"]`（tini 由基础镜像提供）。
5. 新建 `gateway`（10002）、`node`（10003）用户，`node` 的 UID 从 1000 改为 10003。启动脚本已有"只改属主不对的文件"的逻辑，现有数据卷会在首次启动新版本时自动迁移；用宿主机目录挂载数据卷的部署需要提前说明。
6. 时区、字符集改用基础镜像提供的（`Asia/Shanghai`、`C.UTF-8`）。
7. 引入语义化版本和 tag 发布；`latest` 改为只指正式版本。
8. 接入可复用 workflow，打 tag 时生成离线包和环境清单。
9. 数据目录保持 `/app/data`，不迁移。
10. 按 2.6 在项目里声明版本：根目录加 `mise.toml`；`sidecar/`、`web/` 的 `package.json` 写 `"engines": {"node": ">=24 <25"}` 并开启 `engine-strict`；`gateway/pyproject.toml` 写 `requires-python = ">=3.12,<3.13"`。
11. 前端保持由对话服务同源托管（5.6），不需要引入 Nginx。
