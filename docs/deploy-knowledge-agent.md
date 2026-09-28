# 知识库与 Agent 服务部署手册

按顺序从第 0 步做到第 7 步，每一步验证通过再往下走。命令都可以直接复制执行，`<尖括号>` 里的内容要换成实际值。

本手册适用于能联网的环境。正式环境离线、使用内网模型 API 时，见[离线部署手册](deploy-offline.md)。

| 仓库 | 使用的版本 |
| --- | --- |
| [doc-vector](https://github.com/1de2cvz/doc-vector) | 镜像 `ghcr.io/1de2cvz/doc-vector:sha-8a8bda2`（CI 发布，含 #6、#7） |
| [digital-employee](https://github.com/1de2cvz/digital-employee) | `main`（`cb42af6`，含 #2–#5） |
| [AgentRuntime](https://github.com/1de2cvz/AgentRuntime) | 镜像 `ghcr.io/1de2cvz/agent-runtime:sha-e2f68bc`（含 #12） |
| [pangpt](https://github.com/1de2cvz/pangpt) | `main`（含 #1、#2） |

---

## 0. 部署结构

```
浏览器 ──▶ pangpt（nginx，k8s，端口 80）
             │  /rest/**、/rest/agent/**
             ▼
          digital-employee（Java，9448，/rest）──▶ doc-vector（8000）──▶ 硅基流动（嵌入、重排）
             │ ▲                                    Milvus Lite 在数据卷里
     代理对话 │ │ kb_search 回调
             ▼ │
          AgentRuntime（8770）──▶ 硅基流动（DeepSeek-V3.2）
```

- 浏览器只访问 Java。Java 核对登录令牌和会话归属后代理到 AgentRuntime；模型查知识库时调用 kb_search 回到 Java，由 Java 决定能查哪些库：个人库只查本人的，专业库全部可查。
- 本手册假设 **doc-vector、Java、AgentRuntime 在同一台 Linux 服务器上**（下称「服务器」），pangpt 仍按原来的 Jenkins + k8s 发布。分开部署时要改的地方用 **【分机】** 标出。

| 服务 | 端口 | 对外 |
| --- | --- | --- |
| doc-vector | 8000 | 只给 Java 用，建议只绑本机 |
| digital-employee | 9448（路径前缀 `/rest`） | 给 pangpt 的 nginx 和 AgentRuntime 用 |
| AgentRuntime 对话 | 8770 | 对外开放，安全组只放行 Java 服务器和你自己的 IP |
| AgentRuntime 管理 | 8771 | 不开 |
| pangpt | 80 | k8s Service |

---

## 1. 准备

### 1.1 检查服务器

```bash
docker --version          # 20.10 或更高
docker compose version    # v2
uname -m                  # x86_64；GHCR 上的镜像只有 amd64
df -h /var/lib/docker     # 建议剩余 10GB 以上
java -version             # 1.8，运行 Java 用
umask                     # 应为 0022；是 0077 的话先执行 umask 022，否则拉下来的代码只有 root 能读，容器和 nginx 读不到
```

- 服务器要能访问 `https://api.siliconflow.cn`、`https://ghcr.io`、`https://github.com`。
- 打包 Java 的机器需要 JDK 8 和 Maven 3；打包 pangpt 的机器要能访问你们的私有 npm 源（`@panui-vue/utils` 在那里）。

- [ ] 检查通过

### 1.2 登录 GHCR

doc-vector 和 AgentRuntime 的镜像都是私有的。在 GitHub → Settings → Developer settings → Personal access tokens 建一个只带 `read:packages` 权限的令牌：

```bash
echo '<GitHub 令牌>' | docker login ghcr.io -u 1de2cvz --password-stdin
```

- [ ] 显示 `Login Succeeded`

### 1.3 生成密钥文件

所有密钥集中放在服务器的 `~/deploy-secrets.env` 里，后面每一步都从这里读取，不用来回复制。硅基流动的 Key 请用**新建的**，之前在对话里发过的那个先作废。

```bash
read -rsp "粘贴硅基流动 API Key 后回车（不显示）: " SF; echo
# umask 077 只放在括号里（子 shell），不影响当前终端之后的操作
( umask 077
cat > ~/deploy-secrets.env <<EOF
SF_KEY=$SF
DV_KEY=$(openssl rand -hex 32)
AUTH_TOKEN_SECRET=$(openssl rand -hex 32)
AGENT_TOOL_TOKEN=$(openssl rand -hex 32)
AGENT_RUNTIME_TOKEN=$(openssl rand -hex 32)
TEST_TOKEN=$(openssl rand -hex 32)
PLATFORM_TOKEN=$(openssl rand -hex 32)
ADMIN_TOKEN=$(openssl rand -hex 32)
EOF
)
unset SF
chmod 600 ~/deploy-secrets.env
cat ~/deploy-secrets.env | cut -d= -f1      # 只看名字，确认 8 项都在
```

| 名字 | 用途 |
| --- | --- |
| `SF_KEY` | 硅基流动：doc-vector 的嵌入和重排，AgentRuntime 的对话模型 |
| `DV_KEY` | doc-vector 的访问密钥（doc-vector `API_KEY` = Java `DOC_VECTOR_API_KEY`） |
| `AUTH_TOKEN_SECRET` | Java 签发登录令牌用的密钥 |
| `AGENT_TOOL_TOKEN` | kb_search 工具令牌（Java `AGENT_TOOL_TOKEN` = AgentRuntime `TOOL_API_TOKEN`） |
| `AGENT_RUNTIME_TOKEN` | Java 调 AgentRuntime 用的调用方令牌 |
| `TEST_TOKEN` | 你自己测试 AgentRuntime 用的调用方令牌 |
| `PLATFORM_TOKEN` | AgentRuntime 内部网关令牌 |
| `ADMIN_TOKEN` | AgentRuntime 管理令牌 |

- 这个文件不要提交到 Git，也不要贴到聊天或工单里。部署完成后建议存进密码管理器。
- **【分机】** 服务不在同一台机器时，用 `scp` 把这个文件拷过去，并保持 `chmod 600`。

- [ ] 密钥文件已生成

---

## 2. 部署 doc-vector

### 2.1 取 compose 文件、写配置

镜像由 doc-vector 的 CI 构建好了，服务器上不构建。代码仓库只用来取 `docker-compose.yml`。

```bash
git clone https://github.com/1de2cvz/doc-vector.git ~/doc-vector      # 已经 clone 过就 git pull
cd ~/doc-vector && git checkout main
. ~/deploy-secrets.env
( umask 077
cat > .env <<EOF
API_KEY=${DV_KEY}
LOG_LEVEL=INFO
MAX_UPLOAD_MB=100
UPLOAD_TTL_HOURS=168
MILVUS_MODE=lite
EMBEDDING_BASE_URL=https://api.siliconflow.cn
EMBEDDING_MODEL=BAAI/bge-m3
EMBEDDING_DIMENSION=1024
EMBEDDING_API_KEY=${SF_KEY}
RERANK_BASE_URL=https://api.siliconflow.cn
RERANK_MODEL=BAAI/bge-reranker-v2-m3
RERANK_API_KEY=${SF_KEY}
UPSTREAM_TIMEOUT=60
IMAGE_REPO=ghcr.io/1de2cvz/doc-vector
IMAGE_TAG=sha-8a8bda2
HOST_PORT=127.0.0.1:8000
WORKERS=1
EOF
)
```

- `IMAGE_TAG` 写具体的提交号标签，不要写 `latest`。升级、回滚时只改这一行。
- `HOST_PORT=127.0.0.1:8000` 表示只让本机访问。**【分机】** Java 在别的机器上时改成 `8000`，并用安全组只放行 Java 服务器。
- `MILVUS_MODE=lite` 时 `WORKERS` 必须是 1。

### 2.2 拉取镜像并启动

```bash
docker compose pull
docker compose up -d --no-build
docker compose ps              # STATUS 显示 healthy
```

- `--no-build`：compose 文件里保留了本地构建用的 `build` 段，加上这个参数，镜像拉不下来时会直接报错，而不是在服务器上开始构建。

### 2.3 验证

```bash
curl -fsS http://127.0.0.1:8000/api/v1/health; echo          # "status":"UP"
curl -fsS http://127.0.0.1:8000/api/v1/health/ready; echo    # "ready":true
docker exec doc-vector python scripts/smoke_test.py; echo "退出码 $?"   # 退出码 0
```

- `ready` 返回 503：看 `data` 里哪一项是 false。Embedding 或 Rerank 不通，通常是 Key 错了或连不上 `api.siliconflow.cn`。
- 自检会建一个测试用 Collection `doc_vector_smoke_test`，留着不影响业务。

- [ ] `ready` 为 true，自检退出码 0

---

## 3. 部署 digital-employee（Java）

### 3.1 打包

在有 JDK 8 和 Maven 的机器上：

```bash
git clone https://github.com/1de2cvz/digital-employee.git ~/digital-employee
cd ~/digital-employee && git checkout main
export LANG=C.UTF-8 LC_ALL=C.UTF-8     # 源码里有中文文件名
mvn -B package                         # POM 默认跳过测试
ls -l target/digital-employee-1.0.0.jar
```

把 jar 传到服务器的 `/opt/digital-employee/`。

### 3.2 备份旧版

```bash
sudo mkdir -p /opt/digital-employee/backup
# 把现在在跑的 jar 和启动配置（启动脚本、环境变量）拷到 backup 里，回滚时要用
```

- [ ] 旧 jar 和旧配置已备份

### 3.3 写环境变量

先建文件，再把**原有**的数据库、FastDFS 等配置填进去。这个文件每行一个 `变量=值`，**不能在行尾写注释**。

```bash
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
sudo vi /etc/digital-employee.env      # 填上前 7 项；用到 ENCRYPT_SECRET_KEY 的话加一行
```

- 旧配置里的 `SMART_SEGMENT_PYTHON_BASE_URL` 不要再加，新版不读它。
- **【分机】** doc-vector 或 AgentRuntime 在别的机器上时，`DOC_VECTOR_BASE_URL`、`AGENT_RUNTIME_BASE_URL` 改成它们的地址。

### 3.4 启动

还没有启动脚本的话用 systemd：

```bash
sudo tee /etc/systemd/system/digital-employee.service >/dev/null <<'EOF'
[Unit]
Description=digital-employee
After=network-online.target

[Service]
EnvironmentFile=/etc/digital-employee.env
Environment=LANG=C.UTF-8
WorkingDirectory=/opt/digital-employee
ExecStart=/usr/bin/java -jar /opt/digital-employee/digital-employee-1.0.0.jar
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
# 先停掉旧的 Java 进程，再启动新版
sudo systemctl daemon-reload && sudo systemctl enable --now digital-employee
journalctl -u digital-employee -f      # 看到 Started DigitalEmployeeApplication 后 Ctrl+C
```

### 3.5 验证

```bash
# 1) 服务起来了：返回 "running":false
curl -fsS http://127.0.0.1:9448/rest/kb/vector/rebuild/status; echo

# 2) 登录会签发令牌：data 里有 token 和 token_expires_at
curl -s -X POST http://127.0.0.1:9448/rest/pansoft/sys/login -H 'Content-Type: application/json' \
  -d '{"account":"<账号>","password":"<密码>"}'; echo

# 3) Agent 接口会校验令牌：没带令牌返回 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:9448/rest/agent/v1/sessions \
  -H 'Content-Type: application/json' -d '{"sessionId":"x"}'
```

- 第 2 步没有 `token`：`AUTH_TOKEN_SECRET` 没配上，或少于 32 个字符（少于 32 个字符时 Java 会直接启动失败）。
- 第 3 步返回 503：`AUTH_TOKEN_SECRET`、`AGENT_RUNTIME_BASE_URL`、`AGENT_RUNTIME_TOKEN` 没配齐。

- [ ] 三项都符合预期

### 3.6 全量重新向量化

已有的切片要全部写进 doc-vector 一次，否则检索不到任何内容。先在数据库里数一下应该有多少条：

```sql
SELECT U.KB_TYPE, COUNT(*)
FROM ZSK_PRO_FILE_SLICE S
JOIN ZSK_PRO_FILE_UPLOAD U ON U.FILE_ID = S.FILE_ID AND U.UPLOAD_ID = S.UPLOAD_ID AND U.STATUS = 1
WHERE NVL(S.IS_DELETED, 0) = 0 AND NVL(S.STATUS, 1) = 1
GROUP BY U.KB_TYPE;
```

启动重建（后台执行，立即返回）：

```bash
curl -X POST 'http://127.0.0.1:9448/rest/kb/vector/rebuild?userId=<操作人账号>'; echo
# 每隔一会儿查一次，直到 running 变成 false
curl -s http://127.0.0.1:9448/rest/kb/vector/rebuild/status; echo
```

- 完成标准：`succeededSlices` 等于上面 SQL 的总数，`failedSlices`、`failedFiles` 都是 0。
- 有失败时先看 `lastError` 和 Java 日志，处理后再执行一次重建。按切片 ID 写入，重复执行不会产生重复数据。日志里有 429 是硅基流动限流，等几分钟再跑。
- 只想先试一类库：加 `&kbType=0`（个人）或 `&kbType=1`（专业）。

- [ ] 重建完成，数量对得上

### 3.7 试一次导入

在页面上用智能分段导入一份真实的 PDF：切片列表有内容、序号从 1 开始；向量化后用文档里的一句话搜索，能搜到这份文件。`docker logs doc-vector` 里能看到 `POST /api/v1/documents/parse`，紧跟着一条 `DELETE /api/v1/documents/...`。

- [ ] 导入和检索正常

---

## 4. 部署 AgentRuntime

### 4.1 写配置

```bash
mkdir -p ~/agent-runtime && cd ~/agent-runtime
. ~/deploy-secrets.env
( umask 077
cat > .env <<EOF
GATEWAY_UPSTREAM_KEY=${SF_KEY}
GATEWAY_UPSTREAM_BASE=https://api.siliconflow.cn/v1
GATEWAY_UPSTREAM_MODEL=deepseek-ai/DeepSeek-V3.2
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
IMAGE_TAG=sha-e2f68bc
EOF
)
```

- 硅基流动的地址要带 `/v1`：网关会在后面拼 `/chat/completions`。doc-vector 那边不带。
- `GATEWAY_UPSTREAM_MODEL` 把所有请求的模型名改成 `deepseek-ai/DeepSeek-V3.2`。
- `USER_TOKENS` 里 Java 那一项的 `userId` 必须是 `digital-employee`（与 Java 的 `AGENT_RUNTIME_CALLER_ID` 默认值一致），否则 kb_search 会被 Java 拒绝。
- 不要配 `CONSOLE_TENANT`：端口对外开放时，配了它就不需要令牌也能打开对话页。
- **【分机】** Java 不在这台机器时，`TOOL_API_BASE`、`TOOL_HTTP_ALLOWED_ORIGINS` 改成 Java 的地址（后者只写协议、主机和端口）。

### 4.2 启动

在 `~/agent-runtime/` 下写 compose 文件，和 `.env` 放在一起：

```bash
cd ~/agent-runtime
cat > compose.yaml <<'EOF'
services:
  agent-runtime:
    image: ghcr.io/1de2cvz/agent-runtime:${IMAGE_TAG:?在 .env 里设置 IMAGE_TAG}
    container_name: agent-runtime
    restart: unless-stopped
    env_file: .env
    extra_hosts: ["host.docker.internal:host-gateway"]
    ports: ["8770:8770"]
    volumes: [agent-data:/app/data]
    logging:
      options: { max-size: 50m, max-file: "5" }

volumes:
  agent-data:
    name: agent-data
EOF
docker compose pull
docker compose up -d
docker compose logs -f            # 看到「全部就绪」后 Ctrl+C
```

- `extra_hosts` 不能删：Linux 上的 Docker 默认没有 `host.docker.internal`，AgentRuntime 要靠它回调 Java 的 kb_search。
- 版本号在 `.env` 的 `IMAGE_TAG` 里，和 doc-vector 一样；`compose.yaml` 写好后不用再改。
- 升级、回滚：改 `.env` 里的 `IMAGE_TAG`，再执行 `docker compose pull && docker compose up -d`。改了 `.env` 的其他配置也是执行 `docker compose up -d`，容器会重建；只 `restart` 不会重新读取 `.env`。
- 之前用 `docker run` 启动过的，先 `docker rm -f agent-runtime` 再执行上面的命令。数据卷还是 `agent-data`，会话不会丢。

在云服务器的安全组（或防火墙）里，8770 端口只放行 Java 服务器和你自己的 IP。这里走的是明文 HTTP，令牌和对话内容在网络上都可见。

### 4.3 验证

```bash
. ~/deploy-secrets.env
B=http://127.0.0.1:8770            # 在自己电脑上测试时写 http://<服务器公网 IP>:8770

# 1) 服务健康
curl -fsS $B/healthz; echo

# 2) 两个 Agent 都在：general-assistant、knowledge-assistant
curl -fsS -H "Authorization: Bearer $TEST_TOKEN" $B/v1/agents; echo

# 3) 问答：确认硅基流动能调通，事件流里陆续出现回答的文字
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

- 第 3 步出现 401/404 或 model not found：检查 `SF_KEY`、地址是否带 `/v1`、模型名，再看 `docker logs agent-runtime`。
- 第 4 步返回 401：`TOOL_API_TOKEN` 与 Java 的 `AGENT_TOOL_TOKEN` 不一致；503：Java 没配 `AGENT_TOOL_TOKEN`；报错或超时：容器连不上 Java，检查 `--add-host` 和宿主机防火墙（Docker 网桥到 9448 要放行）。
- 用 `TEST_TOKEN` 创建的 knowledge-assistant 会话查不到知识库（Java 只接受它自己创建的会话），这是预期行为。知识库问答要从 pangpt 页面测。

- [ ] 四项都符合预期

---

## 5. 部署 pangpt 前端

### 5.1 改 nginx 转发地址

编辑仓库里的 `nginx/default.conf`，这份配置会打进镜像（需要 pangpt#2 已合并）：

- `location /rest/agent/` 的 `proxy_pass` 改成 Java 的地址：`proxy_pass http://<Java 地址>:9448;`。**不要带路径**，Java 的 context-path 就是 `/rest`，要原样保留。
- 同时核对 `location /rest/` 和 `location /v1/workflows/run` 的地址。
- `/rest/agent/` 段里的 `proxy_buffering off`、`proxy_read_timeout 3600s` 不要删，否则回答会最后才一次性出现，或者中途断开。

检查语法：

```bash
docker run --rm -v "$PWD/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.30-alpine nginx -t
```

### 5.2 打包

在能访问私有 npm 源的机器上（`umask` 要是 0022，否则 dist 里的文件 nginx 读不到，页面 403）：

```bash
cd ~/pangpt && git checkout main && git pull
pnpm install
pnpm build          # 产物在 dist/
```

### 5.3 构建镜像并发布

按原来的方式走 Jenkins（`docker build` → 推送 → `kubectl apply -f deploy/`）。镜像会带上 `nginx/default.conf`，监听 80 端口，与 k8s 配置一致。

- 内网基础镜像 `192.168.254.37:5000/base/nginx` 如果自带的站点配置不叫 `default.conf`，会出现两个都监听 80 的站点，要在 Dockerfile 里删掉那个文件。
- 前面如果还有一层网关或负载均衡，也要关闭对 `/rest/agent/` 的缓冲。

### 5.4 验证

1. 打开页面并重新登录一次：升级前就登录的用户本地没有令牌，第一次提问会被带到登录页，这是正常的。
2. 在知识库检索页提一个问题：浏览器开发者工具的网络面板里，`/rest/agent/v1/sessions/.../events` 的 EventStream 应该逐条出现事件，回答注明了来源文件。

- [ ] 页面正常，回答逐字出现并注明来源

---

## 6. 验收

- [ ] doc-vector 的 `smoke_test.py` 退出码为 0
- [ ] 全量重建完成：`succeededSlices` 等于 SQL 数出的切片数，`failedSlices` 为 0
- [ ] 智能分段导入一份新 PDF，切片正常，向量化后能搜到
- [ ] 登录响应里有 `token`；不带令牌调用 `/rest/agent` 返回 401
- [ ] kb_search 连通自检返回 403
- [ ] 在 pangpt 知识库检索页提问：回答注明了来源文件，事件是逐条出现的
- [ ] 个人库隔离：两个账号各自上传一份笔记，问同一个问题，各自只看到自己的内容
- [ ] 选定专业库后问个人的问题，回答说明这次只查了专业库

---

## 7. 停掉旧的 Python 切片服务

1. 观察旧服务的访问日志至少一个工作日，确认没有新请求。如果还有请求，说明还有别的系统在用它，先查清楚。
2. 停止进程或容器，但先不要删除：镜像、配置和它用的 Milvus Collection 至少保留一周，作为回滚备份。
3. 一周内没有问题，再删除旧服务和旧 Collection。

- [ ] 旧服务已停

---

## 附录 A：常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `docker compose pull` 报 `unauthorized` 或 `denied` | 没登录 GHCR，或令牌没有 `read:packages` | 重做 1.2 |
| doc-vector 一直 Restarting，日志里有 `PermissionError: ... /app/app/__init__.py` | 用的是 doc-vector #6 之前在本地构建的镜像，构建时代码是在 `umask 077` 下检出的 | 改用 CI 发布的镜像（2.1 的 `IMAGE_REPO`、`IMAGE_TAG`） |
| 拉取镜像时报 `no space left on device` | Docker 数据目录（默认 `/var/lib/docker`，在系统盘上）空间不够 | `docker image prune -f`（删掉不用的旧镜像）；仍不够就把 Docker 的 `data-root` 挪到数据盘 |
| doc-vector `health/ready` 返回 503 | 硅基流动 Key 错误或网络不通 | 看 `data` 里哪一项是 false，在服务器上 `curl https://api.siliconflow.cn` 试一下 |
| Java 报「文档向量服务未配置：doc-vector.base-url」 | 没有设 `DOC_VECTOR_BASE_URL` | 补上后重启 Java |
| Java 报 `UNAUTHORIZED`（调 doc-vector 时） | `DOC_VECTOR_API_KEY` 与 doc-vector 的 `API_KEY` 不一致 | 改成同一个值 |
| Java 报 `COLLECTION_NOT_READY` | Milvus 里已有同名但结构不同的 Collection（只会在连接旧 Milvus 时出现） | 用 `smart-segment.vector.*-collection-name` 换一个名字，或删掉旧 Collection |
| 导入报「PDF解析失败：… INVALID_ARGUMENT」 | 高级分段的 `chunk_size` 不在 50～10000 之间，或缺少 separator | 调整分段参数 |
| 导入报「PDF解析失败：… FILE_INVALID」 | 文件不是真正的 PDF 或已损坏 | 换一份文件 |
| 大 PDF 解析超时 | 超过 300 秒读超时，或超过 doc-vector 的 `MAX_UPLOAD_MB`（100） | 调大 `doc-vector.parse-timeout-ms` 或 `MAX_UPLOAD_MB` |
| 重建时部分切片失败，日志里有 429 | 硅基流动限流 | 等几分钟后再执行一次重建 |
| Java 启动失败，提到 `auth.token-secret` | `AUTH_TOKEN_SECRET` 少于 32 个字符 | 用 `openssl rand -hex 32` 重新生成 |
| `/rest/agent` 返回 503「Agent 服务未配置」 | Java 缺 `AUTH_TOKEN_SECRET`、`AGENT_RUNTIME_BASE_URL` 或 `AGENT_RUNTIME_TOKEN` | 补齐后重启 Java |
| pangpt 提问后被带到登录页 | 本地没有令牌（升级前登录的），或令牌过期（默认 12 小时） | 重新登录；反复出现就检查登录响应里有没有 `token` |
| `/rest/agent` 返回 403「无权访问该会话」 | 会话不属于当前登录用户 | 这是越权拦截，属于正常行为；新建会话再问 |
| 回答说检索工具出错，Java 日志有「拒绝非本系统会话的 kb_search 调用」 | AgentRuntime `USER_TOKENS` 里的 `userId` 与 Java 的 `AGENT_RUNTIME_CALLER_ID` 不一致 | 改成一致（默认 `digital-employee`），重启 AgentRuntime |
| kb_search 自检返回 401 | `TOOL_API_TOKEN` 与 `AGENT_TOOL_TOKEN` 不同 | 改成相同的值 |
| 新建会话报「没有这个 Agent：knowledge-assistant」 | AgentRuntime 数据卷里是旧的注册中心（之前部署过旧版本） | 按 AgentRuntime `DEPLOY.md`「接入知识库」一节把新文件拷进卷里，重启 |
| AgentRuntime 启动失败，日志提到 `TOOL_BASEURL_ALLOWLIST` | 改过允许列表但没保留 `TOOL_API_BASE` | 加回 `TOOL_API_BASE`，或删掉这个变量用默认值 |
| AgentRuntime 没有回答，日志里有 404 | `GATEWAY_UPSTREAM_BASE` 少了 `/v1` | 改成 `https://api.siliconflow.cn/v1` 后重建容器 |
| 回答最后才一次性出现 | nginx 或更前面的网关缓冲了事件流 | 每一层代理都关闭对 `/rest/agent/` 的缓冲 |

## 附录 B：回滚

- **Java**：换回备份的旧 jar 和旧配置（包括 `SMART_SEGMENT_PYTHON_BASE_URL`），重启。前提是旧 Python 服务还没停，所以验收前不要停它。旧 jar 没有 `/rest/agent`，要和 pangpt 一起回滚。
- **注意**：新版运行期间导入或修改的切片，向量只写到了 doc-vector。回滚后要把这些切片在旧服务里重新向量化一次。
- **doc-vector**：`cd ~/doc-vector && docker compose down`，数据卷会保留；不要加 `-v`。
- **AgentRuntime**：`~/agent-runtime/.env` 里的 `IMAGE_TAG` 改回原来的，`docker compose up -d`。会话数据在 `agent-data` 卷里。
- **doc-vector 升级到有问题的版本**：`.env` 里的 `IMAGE_TAG` 改回原来的，`docker compose up -d --no-build`。
- **pangpt**：发布上一版镜像。

## 附录 C：日常命令

```bash
# 日志
docker compose -f ~/doc-vector/docker-compose.yml logs -f --tail=200
journalctl -u digital-employee -f
docker compose -f ~/agent-runtime/compose.yaml logs -f --tail=200

# 重启
docker compose -f ~/doc-vector/docker-compose.yml restart
sudo systemctl restart digital-employee
docker compose -f ~/agent-runtime/compose.yaml restart

# 备份 AgentRuntime 数据（停机几秒）
docker stop agent-runtime
docker run --rm --entrypoint tar -v agent-data:/app/data -v "$PWD":/backup ghcr.io/1de2cvz/agent-runtime:sha-e2f68bc \
  czf /backup/agent-data-$(date +%Y%m%d%H%M%S).tgz -C /app/data .
docker start agent-runtime
```

更多细节：doc-vector 的 [Docker部署手册](https://github.com/1de2cvz/doc-vector/blob/main/docs/Docker%E9%83%A8%E7%BD%B2%E6%89%8B%E5%86%8C.md)、AgentRuntime 的 [DEPLOY.md](https://github.com/1de2cvz/AgentRuntime/blob/main/DEPLOY.md)、digital-employee 的 [README](https://github.com/1de2cvz/digital-employee/blob/main/README.md)。
