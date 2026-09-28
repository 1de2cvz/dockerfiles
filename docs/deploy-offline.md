# 知识库与 Agent 服务：正式环境（离线）部署手册

正式环境不能访问外网。做法是：在开发环境（能联网）把镜像和 jar 准备好，摆渡到正式环境导入；嵌入、重排、对话模型改用正式环境的内网 API。

各服务的原理、参数含义和常见问题，见联网环境的[部署手册](deploy-knowledge-agent.md)。本手册只写离线环境的步骤和不同之处。命令都可以直接复制执行，`<尖括号>` 里的内容要换成实际值。

---

## 0. 正式环境要带什么

**代码已经在镜像里了，正式环境不需要源代码，也不需要 Git、GHCR、pip 源、npm 源或硅基流动。**

| 服务 | 交付物 | 里面已经有 | 正式环境另外需要 |
| --- | --- | --- | --- |
| doc-vector | 镜像 `ghcr.io/1de2cvz/doc-vector:sha-f5a41c0`（CI 构建） | Python 代码、全部依赖、Milvus Lite | `docker-compose.yml`、`.env` |
| AgentRuntime | 镜像 `ghcr.io/1de2cvz/agent-runtime:sha-e2f68bc`（CI 构建） | 对话服务、模型网关、对话页、默认注册中心（Agent 和 kb_search 工具定义；第一次启动时拷进数据卷） | `compose.yaml`（9.2 现写）、`.env` |
| digital-employee（Java） | `digital-employee-1.0.0.jar`（不是镜像） | 编译好的代码和全部依赖（Spring Boot fat jar） | JDK 8、`/etc/digital-employee.env`、systemd 服务文件 |
| pangpt | 镜像 | 打包好的前端页面、nginx 配置 | 正式环境的镜像仓库和 k8s |

注意：

- **pangpt 的 nginx 配置在镜像里，Java 地址是写死的**。所以要在开发环境用正式环境的 Java 地址单独打一个镜像（见 1.2）。
- 数据不迁移：
  - 向量在正式环境从正式库重新生成（第 8 步）。开发环境的向量对应的是开发库的切片，两边对不上。
  - 开发环境的会话是测试数据，也不带。
- 以后升级也走同一条路：CI 构建镜像 → 开发环境拉取、验证 → 导出 → 摆渡 → 正式环境导入。**正式环境不做构建。**

部署后的结构与联网环境相同，只是三个模型改成了内网 API：

```
浏览器 ──▶ pangpt（nginx，k8s）──▶ Java（9448）──▶ doc-vector（127.0.0.1:8000）──▶ 内网嵌入 API、内网重排 API
                                     │ ▲
                              代理对话 │ │ kb_search 回调
                                     ▼ │
                                  AgentRuntime（127.0.0.1:8770）──▶ 内网对话 API
```

| 服务 | 端口 | 谁能访问 |
| --- | --- | --- |
| doc-vector | 8000 | 只绑本机，只给 Java 用 |
| Java | 9448 | 防火墙只放行 pangpt 所在的 k8s 节点和 Docker 网桥（`172.17.0.0/16`） |
| AgentRuntime | 8770 | 只绑本机；要在别的机器上测试时见 9.2 |

---

## 1. 开发环境：准备交付物

在开发服务器上操作。

### 1.1 拉取镜像，确认 jar

镜像由 CI 构建，开发服务器只负责拉取。镜像标签就是构建它的提交号，一眼能看出版本。

```bash
docker login ghcr.io -u 1de2cvz       # 令牌需要 read:packages 权限，见部署手册 1.2；登录过就跳过
docker pull ghcr.io/1de2cvz/doc-vector:sha-f5a41c0
docker pull ghcr.io/1de2cvz/agent-runtime:sha-e2f68bc
ls -l /opt/digital-employee/digital-employee-1.0.0.jar     # 换成你实际放 jar 的路径
```

- 用开发环境验证通过的那两个标签：doc-vector 看它 `.env` 里的 `IMAGE_TAG`，AgentRuntime 看它 `.env` 里的 `TAG`。
- 缺 jar：见部署手册 3.1。服务器上没有 Maven 时，可以用容器打包：

  ```bash
  cd ~/digital-employee && git pull
  docker run --rm -v "$PWD":/src -v "$HOME/.m2":/root/.m2 -w /src -e LANG=C.UTF-8 \
    maven:3.9-eclipse-temurin-8 mvn -B package
  ls -l target/digital-employee-1.0.0.jar
  ```

### 1.2 打正式环境用的 pangpt 镜像

在能访问私有 npm 源的机器上操作。

```bash
cd ~/pangpt && git checkout main && git pull
vi nginx/default.conf
```

把 `/rest/`、`/rest/agent/`、`/v1/workflows/run` 三处的 `proxy_pass` 改成**正式环境**的地址。`/rest/agent/` 写 `proxy_pass http://<正式 Java 地址>:9448;`，不要带路径。

```bash
docker run --rm -v "$PWD/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.30-alpine nginx -t
umask                      # 要是 0022，否则 dist 里的文件 nginx 读不到
pnpm install && pnpm build
TAG=prod-$(date +%Y%m%d)
docker build -t pangpt:$TAG .
docker save pangpt:$TAG | gzip > ~/pangpt-image.tar.gz
git checkout nginx/default.conf        # 恢复开发环境的配置，正式地址不提交
```

`~/pangpt-image.tar.gz` 在 1.3 放进导出目录。

### 1.3 导出

```bash
OUT=~/offline-$(date +%Y%m%d) && mkdir -p "$OUT" && cd "$OUT"

# 镜像：docker save 会带上基础镜像的所有层，正式环境不需要再拉
docker save ghcr.io/1de2cvz/doc-vector:sha-f5a41c0 ghcr.io/1de2cvz/agent-runtime:sha-e2f68bc | gzip > server-images.tar.gz
cp ~/pangpt-image.tar.gz .      # 1.2 生成的；pangpt 在别的机器上打包的话，从那里拷过来

# 其余文件
cp ~/doc-vector/docker-compose.yml doc-vector-compose.yml
cp /opt/digital-employee/digital-employee-1.0.0.jar .      # 换成实际路径
cp ~/digital-employee/sql/oracle/01_schema.sql .            # 正式库还没建表时要用

sha256sum * > SHA256SUMS
ls -lh
```

- **不要带** `.env`、`deploy-secrets.env` 等含密钥的文件，正式环境重新生成。
- 正式服务器如果没有 Docker 或 JDK 8，还要一起带离线安装包：
  - Docker 静态二进制包：`download.docker.com/linux/static/stable/x86_64/`；
  - compose 插件：GitHub `docker/compose` 的 Releases；
  - JDK 8：用你们常用的发行版。

- [ ] 导出目录里有 2 个镜像包、compose 文件、jar、建表脚本、`SHA256SUMS`

---

## 2. 摆渡与校验

用摆渡机或 U 盘，把整个导出目录拷到正式服务器的 `~/offline/`，然后校验：

```bash
cd ~/offline && sha256sum -c SHA256SUMS      # 每一行都是 OK
```

- [ ] 校验通过

---

## 3. 正式环境：检查服务器

```bash
uname -m                  # 必须是 x86_64，和开发环境一致，否则镜像跑不起来
docker --version          # 20.10 或更高
docker compose version    # v2
java -version             # 1.8
df -h /var/lib/docker     # 剩余空间至少是镜像包大小的 3 倍
umask                     # 应为 0022；是 0077 的话先执行 umask 022
```

从这台服务器能连通以下地址：

- Oracle、GaussDB、FastDFS；
- 嵌入、重排、对话三个内网 API（第 4 步会逐个验证）；
- pangpt 所在的 k8s 节点能访问这台机器的 9448 端口。

- [ ] 检查通过

---

## 4. 验证内网模型 API

### 4.1 记下模型地址

```bash
cat > ~/deploy-models.env <<'EOF'
EMB_BASE=http://<嵌入服务IP:端口>
EMB_MODEL=<嵌入模型名>
EMB_DIM=<嵌入维度，4.3 第 1 条会打印>
RR_BASE=http://<重排服务IP:端口>
RR_MODEL=<重排模型名>
LLM_BASE=http://<对话服务IP:端口>/v1
LLM_MODEL=<对话模型名>
EOF
vi ~/deploy-models.env
```

注意地址的写法：

- **嵌入、重排的地址写到 `/v1` 之前为止**：doc-vector 会自己拼上 `/v1/embeddings`、`/v1/rerank`。如果接口带前缀（例如 `http://x/api/v1/embeddings`），就写成 `http://x/api`。
- **对话的地址要带上 `/v1`**：网关只在后面拼 `/chat/completions`。

### 4.2 生成密钥文件

```bash
read -rsp "嵌入 API Key（没有直接回车）: " EMB; echo
read -rsp "重排 API Key（没有直接回车）: " RR; echo
read -rsp "对话 API Key（没有直接回车）: " LLM; echo
# umask 077 只放在括号里（子 shell），不影响当前终端之后的操作
( umask 077
cat > ~/deploy-secrets.env <<EOF
EMB_KEY=$EMB
RR_KEY=$RR
LLM_KEY=${LLM:-none}
DV_KEY=$(openssl rand -hex 32)
AUTH_TOKEN_SECRET=$(openssl rand -hex 32)
AGENT_TOOL_TOKEN=$(openssl rand -hex 32)
AGENT_RUNTIME_TOKEN=$(openssl rand -hex 32)
TEST_TOKEN=$(openssl rand -hex 32)
PLATFORM_TOKEN=$(openssl rand -hex 32)
ADMIN_TOKEN=$(openssl rand -hex 32)
EOF
)
unset EMB RR LLM
chmod 600 ~/deploy-secrets.env
cut -d= -f1 ~/deploy-secrets.env      # 只看名字，确认 10 项都在
```

- 对话接口不需要 Key 时，这里会自动填 `none`：网关要求 Key 不能为空。
- 各令牌的用途见部署手册 1.3。这些值全部在正式环境新生成，**不要沿用开发环境的**。

### 4.3 逐个调用

```bash
. ~/deploy-models.env; . ~/deploy-secrets.env
auth() { [ -n "$1" ] && printf '%s\n' -H "Authorization: Bearer $1"; }
mapfile -t EA < <(auth "$EMB_KEY"); mapfile -t RA < <(auth "$RR_KEY"); mapfile -t LA < <(auth "$LLM_KEY")

# 1) 嵌入：打印「2 条, 维度 N」，把 N 填回 ~/deploy-models.env 的 EMB_DIM
curl -sS "$EMB_BASE/v1/embeddings" -H 'Content-Type: application/json' "${EA[@]}" \
  -d "{\"model\":\"$EMB_MODEL\",\"input\":[\"测试一下\",\"第二句\"]}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(len(d), "条, 维度", len(d[0]["embedding"]))'

# 2) 重排：results 里每条都有 index 和 relevance_score（或 score），「苹果是水果」的分数更高
curl -sS "$RR_BASE/v1/rerank" -H 'Content-Type: application/json' "${RA[@]}" \
  -d "{\"model\":\"$RR_MODEL\",\"query\":\"苹果\",\"documents\":[\"香蕉很甜\",\"苹果是水果\"],\"top_n\":2}"; echo

# 3) 对话 + 工具调用：返回里有 choices[0].message.tool_calls
curl -sS "$LLM_BASE/chat/completions" -H 'Content-Type: application/json' "${LA[@]}" -d "{
  \"model\":\"$LLM_MODEL\",
  \"messages\":[{\"role\":\"user\",\"content\":\"查一下知识库里的报销流程\"}],
  \"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"kb_search\",\"description\":\"检索知识库\",
    \"parameters\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}}}]}"; echo

# 4) 流式输出：陆续打印 data: 行，最后有一行带 usage
curl -sSN "$LLM_BASE/chat/completions" -H 'Content-Type: application/json' "${LA[@]}" \
  -d "{\"model\":\"$LLM_MODEL\",\"stream\":true,\"stream_options\":{\"include_usage\":true},
       \"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}" | grep -v '^$' | tail -n 3
```

四项都符合预期才往下走。不符合时见附录 A 的「内网模型 API 不兼容」。

- [ ] 嵌入、重排、工具调用、流式输出四项都正常，`EMB_DIM` 已填

---

## 5. 导入镜像

```bash
cd ~/offline
gunzip -c server-images.tar.gz | docker load
docker images | grep -E 'doc-vector|agent-runtime'
```

pangpt 的镜像包留到第 10 步，在能推送到正式环境镜像仓库的机器上导入。

- [ ] 两个镜像都在

---

## 6. 部署 doc-vector

### 6.1 写配置

```bash
mkdir -p ~/doc-vector && cd ~/doc-vector
cp ~/offline/doc-vector-compose.yml docker-compose.yml
. ~/deploy-models.env; . ~/deploy-secrets.env
( umask 077
cat > .env <<EOF
API_KEY=${DV_KEY}
LOG_LEVEL=INFO
MAX_UPLOAD_MB=100
UPLOAD_TTL_HOURS=168
MILVUS_MODE=lite
EMBEDDING_BASE_URL=${EMB_BASE}
EMBEDDING_MODEL=${EMB_MODEL}
EMBEDDING_DIMENSION=${EMB_DIM}
EMBEDDING_API_KEY=${EMB_KEY}
RERANK_BASE_URL=${RR_BASE}
RERANK_MODEL=${RR_MODEL}
RERANK_API_KEY=${RR_KEY}
UPSTREAM_TIMEOUT=60
IMAGE_REPO=ghcr.io/1de2cvz/doc-vector
IMAGE_TAG=sha-f5a41c0
HOST_PORT=127.0.0.1:8000
WORKERS=1
EOF
)
grep -E '^(EMBEDDING|RERANK)_(BASE_URL|MODEL|DIMENSION)' .env     # 核对，不含 Key；不能有尖括号
```

- **`EMBEDDING_DIMENSION` 必须等于 4.3 第 1 条打印的维度。** 向量集合在第一次写入时按这个维度创建，之后再改就会报「Embedding 维度不一致」，只能删掉数据卷重新生成向量。
- Key 为空时，doc-vector 调用模型不带 `Authorization` 请求头。

### 6.2 启动

```bash
docker compose up -d --no-build
docker compose ps              # STATUS 显示 healthy
```

- **一定要加 `--no-build`**。compose 文件里写了 `build`，不加的话，镜像名或标签一对不上它就会尝试构建，离线环境会失败。
- 报 `pull access denied` 或 `no such image`：`.env` 里的 `IMAGE_REPO`、`IMAGE_TAG` 和第 5 步导入的镜像不一致，用 `docker images | grep doc-vector` 对一下。

### 6.3 验证

```bash
curl -fsS http://127.0.0.1:8000/api/v1/health; echo          # "status":"UP"
curl -fsS http://127.0.0.1:8000/api/v1/health/ready; echo    # "ready":true
docker exec doc-vector python scripts/smoke_test.py; echo "退出码 $?"   # 退出码 0
```

- `ready` 返回 503：看 `data` 里哪一项是 false，对照 4.3 检查地址和 Key。

- [ ] `ready` 为 true，自检退出码 0

---

## 7. 部署 Java（digital-employee）

### 7.1 放 jar，写环境变量

```bash
sudo mkdir -p /opt/digital-employee
sudo cp ~/offline/digital-employee-1.0.0.jar /opt/digital-employee/
. ~/deploy-secrets.env
sudo install -m 600 /dev/null /etc/digital-employee.env
sudo tee /etc/digital-employee.env >/dev/null <<EOF
DB_URL=
DB_USERNAME=
DB_PASSWORD=
GAUSSDB_URL=
GAUSSDB_USERNAME=
GAUSSDB_PASSWORD=
FASTDFS_TRACKER=
DOC_VECTOR_BASE_URL=http://127.0.0.1:8000
DOC_VECTOR_API_KEY=${DV_KEY}
AUTH_TOKEN_SECRET=${AUTH_TOKEN_SECRET}
AGENT_RUNTIME_BASE_URL=http://127.0.0.1:8770
AGENT_RUNTIME_TOKEN=${AGENT_RUNTIME_TOKEN}
AGENT_TOOL_TOKEN=${AGENT_TOOL_TOKEN}
EOF
sudo vi /etc/digital-employee.env      # 填上正式环境的数据库、FastDFS；用到 ENCRYPT_SECRET_KEY 的话加一行
```

这个文件每行一个 `变量=值`，行尾不能写注释。

正式库还没有建表的话，先执行 digital-employee 仓库的 `sql/oracle/01_schema.sql`（见部署手册 3.2，要在 1.3 导出时一起带过来）。**不要执行 `02_external_tables_dev.sql`**：正式环境的用户表等外部表由现有的主数据、数仓提供。

### 7.2 启动

```bash
sudo tee /etc/systemd/system/digital-employee.service >/dev/null <<'EOF'
[Unit]
Description=digital-employee
After=network-online.target

[Service]
EnvironmentFile=/etc/digital-employee.env
Environment=LANG=C.UTF-8
WorkingDirectory=/opt/digital-employee
ExecStart=/usr/bin/java -Xms1g -Xmx2g -jar /opt/digital-employee/digital-employee-1.0.0.jar
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now digital-employee
journalctl -u digital-employee -f      # 看到 Started DigitalEmployeeApplication 后 Ctrl+C
```

- `-Xmx` 按内存大小调整。不设的话，JVM 默认最多占物理内存的 1/4，还要给 Docker 里的服务留出内存。

### 7.3 防火墙

9448 端口只放行 pangpt 所在的 k8s 节点和 Docker 网桥（AgentRuntime 回调 kb_search 要用）。现有的业务接口直接信任请求里的 `userId`，这个端口不能对其他机器开放。以 firewalld 为例：

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=<k8s 节点网段> port port=9448 protocol=tcp accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=172.17.0.0/16 port port=9448 protocol=tcp accept'
sudo firewall-cmd --reload
```

用的是云安全组或其他防火墙的话，按同样的规则配置。

### 7.4 验证

```bash
curl -fsS http://127.0.0.1:9448/rest/kb/vector/rebuild/status; echo       # "running":false
curl -s -X POST http://127.0.0.1:9448/rest/pansoft/sys/login -H 'Content-Type: application/json' \
  -d '{"account":"<账号>","password":"<密码>"}'; echo                      # data 里有 token
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:9448/rest/agent/v1/sessions \
  -H 'Content-Type: application/json' -d '{"sessionId":"x"}'               # 401
```

- [ ] 三项都符合预期

---

## 8. 生成向量

### 8.1 数一下应有多少切片

在正式库执行：

```sql
SELECT U.KB_TYPE, COUNT(*)
FROM ZSK_PRO_FILE_SLICE S
JOIN ZSK_PRO_FILE_UPLOAD U ON U.FILE_ID = S.FILE_ID AND U.UPLOAD_ID = S.UPLOAD_ID AND U.STATUS = 1
WHERE NVL(S.IS_DELETED, 0) = 0 AND NVL(S.STATUS, 1) = 1
GROUP BY U.KB_TYPE;
```

### 8.2 全量重建

```bash
curl -X POST 'http://127.0.0.1:9448/rest/kb/vector/rebuild?userId=<操作人账号>'; echo
# 每隔一会儿查一次，直到 running 变成 false
curl -s http://127.0.0.1:9448/rest/kb/vector/rebuild/status; echo
```

- 完成标准：`succeededSlices` 等于 8.1 的总数，`failedSlices`、`failedFiles` 都是 0。
- 有失败的话，先看 `lastError` 和 Java 日志，处理后再执行一次。重复执行不会产生重复数据。
- 内网嵌入 API 有并发限制的话，重建会比较慢，但不影响结果。

### 8.3 试一次导入

在页面上用智能分段导入一份 PDF，向量化完成后，用文档里的一句话搜索，能搜到这份文件。

- [ ] 重建数量对得上，新导入的文件能搜到

---

## 9. 部署 AgentRuntime

### 9.1 写配置

```bash
mkdir -p ~/agent-runtime && cd ~/agent-runtime
. ~/deploy-models.env; . ~/deploy-secrets.env
( umask 077
cat > .env <<EOF
GATEWAY_UPSTREAM_KEY=${LLM_KEY}
GATEWAY_UPSTREAM_BASE=${LLM_BASE}
GATEWAY_UPSTREAM_MODEL=${LLM_MODEL}
GATEWAY_TOKENS=${PLATFORM_TOKEN}:prod
AGENTOPS_TOKEN=${PLATFORM_TOKEN}
AGENTOPS_TENANT=prod
ADMIN_TOKEN=${ADMIN_TOKEN}
USER_TOKENS='{"${AGENT_RUNTIME_TOKEN}":{"userId":"digital-employee","tenantId":"prod","roles":["user"]},"${TEST_TOKEN}":{"userId":"tester","tenantId":"prod","roles":["user"]}}'
SESSION_STORE=sqlite
TOOL_API_BASE=http://host.docker.internal:9448/rest
TOOL_HTTP_ALLOWED_ORIGINS=http://host.docker.internal:9448
TOOL_API_TOKEN=${AGENT_TOOL_TOKEN}
TOOL_CREDENTIAL_ALLOWLIST=TOOL_API_TOKEN
IMAGE_PREFIX=ghcr.io/1de2cvz/
TAG=sha-e2f68bc
EOF
)
```

`USER_TOKENS` 里 Java 那一项的 `userId` 必须是 `digital-employee`，否则 kb_search 会被 Java 拒绝。

### 9.2 启动

compose 文件就是 AgentRuntime 仓库里的 `compose.allinone.yaml`，改名为 `compose.yaml`。下面直接写出它的内容：

```bash
cd ~/agent-runtime
cat > compose.yaml <<'EOF'
name: agent-runtime

services:
  agent-runtime:
    image: ${IMAGE_PREFIX:-}agent-runtime:${TAG:?在 .env 里设置 TAG，如 sha-<短提交号>}
    container_name: agent-runtime
    restart: unless-stopped
    env_file: .env
    extra_hosts:
      # 工具经 host.docker.internal 访问宿主机上的业务系统（如 kb_search 回调 Java）。
      # Linux 上的 Docker 默认没有这个主机名，要显式加上
      - host.docker.internal:host-gateway
    ports:
      # 默认只绑回环。要从别的机器访问对话端口时在 .env 里设 CHAT_HOST_PORT=8770，并用防火墙限制来源
      - "${CHAT_HOST_PORT:-127.0.0.1:8770}:8770"
      # 管理服务只在 .env 里设了 ADMIN_ENABLED=1 和 ADMIN_TOKEN 时启动；只绑回环，经 SSH 隧道访问
      - "${ADMIN_HOST_PORT:-127.0.0.1:8771}:8771"
    volumes:
      # 会话、注册中心、网关用量都在这里，见 DEPLOY.md「备份与恢复」
      - agent-data:/app/data
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"

volumes:
  agent-data:
    # 固定卷名，和 docker run 方式用的是同一个卷，两种方式可以互相切换
    name: agent-data
EOF
docker compose up -d
docker compose logs -f            # 看到「全部就绪」后 Ctrl+C
```

- 镜像第 5 步已经导入了，这里不用 `pull`。
- 这个文件写好后不用再改。版本号在 `.env` 的 `TAG` 里（镜像前缀是 `IMAGE_PREFIX`），变量名沿用 AgentRuntime 仓库的约定。
- `extra_hosts` 不能删：Linux 上的 Docker 默认没有 `host.docker.internal`，AgentRuntime 要靠它回调 Java 的 kb_search。
- 端口默认只绑本机，Java 在同一台机器上，够用了。要从内网其他机器测试的话，二选一：
  - 用 SSH 隧道：`ssh -N -L 8770:127.0.0.1:8770 <用户>@<服务器>`，然后在本机访问 `http://127.0.0.1:8770`；
  - 在 `.env` 里加 `CHAT_HOST_PORT=8770`，执行 `docker compose up -d`，并在防火墙里只放行测试机的 IP。
- 改了 `.env` 以后，执行 `docker compose up -d`，容器会重建。只 `restart` 不会重新读取 `.env`。

### 9.3 验证

```bash
. ~/deploy-secrets.env
B=http://127.0.0.1:8770

# 1) 服务健康
curl -fsS $B/healthz; echo

# 2) 两个 Agent 都在：general-assistant、knowledge-assistant
curl -fsS -H "Authorization: Bearer $TEST_TOKEN" $B/v1/agents; echo

# 3) 问答：事件流里陆续出现回答的文字
SID=$(curl -fsS -X POST $B/v1/sessions -H "Authorization: Bearer $TEST_TOKEN" \
  -H 'Content-Type: application/json' -d '{"agentId":"general-assistant"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessionId"])')
curl -fsS -X POST $B/v1/sessions/$SID/prompt -H "Authorization: Bearer $TEST_TOKEN" \
  -H 'Content-Type: application/json' -d '{"text":"用一句话介绍你自己"}'; echo
curl -N --max-time 60 "$B/v1/sessions/$SID/events?cursor=0" \
  -H "Authorization: Bearer $TEST_TOKEN" -H 'Accept: text/event-stream'
```

```bash
# 4) kb_search 能连到 Java：预期输出 403（令牌对，调用方故意写错）
docker exec agent-runtime node -e "fetch(process.env.TOOL_API_BASE+'/agent/kb/search',{method:'POST',headers:{'Authorization':'Bearer '+process.env.TOOL_API_TOKEN,'Content-Type':'application/json','X-AgentOps-User':'probe','X-AgentOps-Session':'probe'},body:'{\"query\":\"x\"}'}).then(r=>console.log(r.status))"
```

- 第 3 步没有回答：`docker logs agent-runtime` 里看网关打出的上游状态码，对照附录 A。
- 第 4 步报错或超时：容器连不上 Java，检查 7.3 的防火墙是否放行了 `172.17.0.0/16`。

- [ ] 四项都符合预期

---

## 10. 部署 pangpt

在能推送到正式环境镜像仓库的机器上：

```bash
gunzip -c pangpt-image.tar.gz | docker load
docker tag pangpt:prod-<日期> <正式镜像仓库>/<项目>/pangpt:prod-<日期>
docker push <正式镜像仓库>/<项目>/pangpt:prod-<日期>
```

然后按正式环境的 k8s 发布流程：把 k8s 部署文件里的镜像地址改成上面推送的这个，再 `kubectl apply`。

- 前面如果还有一层网关或负载均衡，也要关闭对 `/rest/agent/` 的缓冲，否则回答会最后才一次性出现。

- [ ] 页面正常

---

## 11. 验收

- [ ] doc-vector `smoke_test.py` 退出码为 0
- [ ] 全量重建完成，数量对得上
- [ ] 智能分段导入一份新 PDF，向量化后能搜到
- [ ] 登录响应里有 `token`；不带令牌调用 `/rest/agent` 返回 401
- [ ] kb_search 连通自检返回 403
- [ ] 在 pangpt 知识库检索页提问：回答逐字出现，并注明了来源文件
- [ ] 个人库隔离：两个账号各自上传一份笔记，问同一个问题，各自只看到自己的内容
- [ ] 选定专业库后问个人的问题，回答说明这次只查了专业库
- [ ] 从其他机器访问不到内部端口：`curl http://<服务器>:8000`、`:8770`、`:8771` 都连不上；`:9448` 只有 k8s 节点能连上

**对话模型换了，最后这几项一定要实际问一遍。** 不同模型调用工具和转述结果的方式不一样，开发环境通过了，不代表正式环境也能通过。

---

## 12. 以后怎么升级

原则和联网环境一样（见[部署手册](deploy-knowledge-agent.md)第 7 章）：compose 文件不改，只改 `.env` 里的版本号；数据在数据卷里，升级不受影响。区别只在于新镜像要从开发环境带过来。

### 12.1 开发环境：升级、验证、导出

1. 代码合并到 main 后，CI 会发布新镜像，标签是 `sha-<提交号>`。先在开发环境按部署手册第 7 章升级并验证通过。
2. 导出有变化的镜像，连同校验文件一起带走：

   ```bash
   OUT=~/upgrade-$(date +%Y%m%d) && mkdir -p "$OUT" && cd "$OUT"
   docker save ghcr.io/1de2cvz/doc-vector:sha-<新提交号> | gzip > doc-vector.tar.gz          # doc-vector 有更新时
   docker save ghcr.io/1de2cvz/agent-runtime:sha-<新提交号> | gzip > agent-runtime.tar.gz    # AgentRuntime 有更新时
   cp /opt/digital-employee/digital-employee-1.0.0.jar .                                    # Java 有更新时
   sha256sum * > SHA256SUMS
   ```

   用具体的提交号标签，不要用 `latest`，回滚时要用。

### 12.2 正式环境：备份、导入、切换

```bash
cd ~/<升级包目录> && sha256sum -c SHA256SUMS
for f in *.tar.gz; do gunzip -c "$f" | docker load; done
grep -H -E '^(IMAGE_TAG|TAG)=' ~/doc-vector/.env ~/agent-runtime/.env     # 记下当前版本，回滚时要用
```

先按附录 B 备份两个数据卷，然后逐个切换：

```bash
# doc-vector：改版本号，补新增的配置项（先预览，确认后加 --write），重建
cd ~/doc-vector
sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=sha-<新提交号>/' .env
IMAGE=$(docker compose config --images)
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work --entrypoint python "$IMAGE" scripts/env_sync.py /work/.env
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work --entrypoint python "$IMAGE" scripts/env_sync.py /work/.env --write
docker compose up -d --no-build
docker exec doc-vector python scripts/smoke_test.py; echo "退出码 $?"

# AgentRuntime：改版本号，重建
cd ~/agent-runtime
sed -i 's/^TAG=.*/TAG=sha-<新提交号>/' .env
docker compose up -d
```

- env_sync 补上的配置项用的是 `.env.example` 里的默认值。**离线环境要特别检查**：新增的配置项里如果有模型地址、外网地址，要改成内网的值。
- Java：替换 jar，执行 `sudo systemctl restart digital-employee`。
- 升级完成后，按第 11 步把验收项再过一遍。

### 12.3 回滚

- doc-vector：`IMAGE_TAG` 改回旧值，执行 `docker compose up -d --no-build`。想把 `.env` 也完全还原，就用 `.env.bak.<时间>` 覆盖。
- AgentRuntime：`TAG` 改回旧值，执行 `docker compose up -d`。
- Java：换回旧 jar，然后重启。
- 旧镜像不要急着 `docker rmi`，回滚时要用。数据格式有变化、改回旧版本号也起不来时，用附录 B 的备份恢复数据卷，做法同部署手册 7.6。

---

## 附录 A：内网模型 API 不兼容

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 嵌入或重排返回 404 | 路径不是 `/v1/embeddings`、`/v1/rerank` | 只是多了一段前缀的话，把前缀写进 `*_BASE_URL`；路径完全不同的话，要改 doc-vector 代码 |
| 嵌入返回的条数和输入不一致 | 接口不支持一次传多条 | 在 doc-vector `.env` 里加 `EMBEDDING_BATCH_SIZE=1`（会变慢），或者让接口方支持批量 |
| 重排的返回里没有 `results` | 返回格式和 Xinference、Jina 的格式不同 | 要改 doc-vector 代码，把一次完整的请求和返回（去掉 Key）发给开发 |
| 对话返回 400，提到 `stream_options` | 网关的流式请求里固定带 `stream_options.include_usage`（用于统计用量），有些接口不认这个参数 | 要给网关加开关，把报错发给开发 |
| 4.3 第 3 条没有 `tool_calls`，只返回了文字 | 对话模型或接口没开启工具调用 | Agent 就无法检索知识库。需要让模型服务方开启工具调用（例如 vLLM 要加 `--enable-auto-tool-choice` 和对应的 `--tool-call-parser`），或者换支持工具调用的模型 |
| 报 SSL 或证书错误 | 内网 API 用的是 https 自签证书 | 能用 http 就改用 http；不行的话，要把内网 CA 证书打进镜像 |
| 网关报 500「网关未配置上游密钥」 | `GATEWAY_UPSTREAM_KEY` 为空 | 随便填一个值（例如 `none`），然后重建容器 |
| doc-vector 报「Embedding 维度不一致」 | `EMBEDDING_DIMENSION` 和模型实际输出的维度不一致 | 改对后：`docker compose down`，`docker volume rm doc-vector-milvus`，`docker compose up -d --no-build`，再做一次第 8 步 |

其他问题（令牌、端口、nginx 缓冲等）和联网环境一样，见部署手册附录 A。

## 附录 B：日常命令

```bash
# 日志
docker compose -f ~/doc-vector/docker-compose.yml logs -f --tail=200
journalctl -u digital-employee -f
docker compose -f ~/agent-runtime/compose.yaml logs -f --tail=200

# 重启
docker compose -f ~/doc-vector/docker-compose.yml restart
sudo systemctl restart digital-employee
docker compose -f ~/agent-runtime/compose.yaml restart

# 备份：停机几秒。AgentRuntime 的会话只能靠备份恢复；向量可以用第 8 步重新生成，备份是为了更快恢复
mkdir -p ~/backup && cd ~/backup
docker compose -f ~/agent-runtime/compose.yaml stop
docker run --rm --entrypoint tar -v agent-data:/app/data -v "$PWD":/backup \
  "$(docker compose -f ~/agent-runtime/compose.yaml config --images)" \
  czf /backup/agent-data-$(date +%Y%m%d%H%M%S).tgz -C /app/data .
docker compose -f ~/agent-runtime/compose.yaml start
docker compose -f ~/doc-vector/docker-compose.yml stop
docker run --rm -u 0 --entrypoint tar -v doc-vector-milvus:/data/milvus -v "$PWD":/backup \
  "$(docker compose -f ~/doc-vector/docker-compose.yml config --images)" \
  czf /backup/doc-vector-milvus-$(date +%Y%m%d%H%M%S).tgz -C /data/milvus .
docker compose -f ~/doc-vector/docker-compose.yml start
```
