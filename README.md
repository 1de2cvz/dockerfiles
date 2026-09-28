# dockerfiles

组织内镜像的公共部分：规范、共享基础镜像和项目模板。各项目的 Dockerfile 仍放在项目自己的仓库里。

| 路径 | 内容 |
|---|---|
| [`STANDARD.md`](STANDARD.md) | 容器镜像规范 |
| [`docs/deploy-knowledge-agent.md`](docs/deploy-knowledge-agent.md) | 知识库与 Agent 服务（doc-vector、digital-employee、AgentRuntime、pangpt）部署手册 |
| [`docs/deploy-offline.md`](docs/deploy-offline.md) | 同上，正式环境（离线、使用内网模型 API）的部署手册 |
| [`images/base/`](images/base/README.md) | 共享基础镜像：Python 3.12 + Node.js 24，Debian 13；另有 Java 8 变体 |
| [`images/web/`](images/web/README.md) | 纯前端项目的镜像：非 root Nginx，只放静态文件 |
| `images/*/versions.env` | 各镜像运行时主版本的唯一来源 |
| [`templates/`](templates/) | 项目模板：Python 服务、纯前端站点的 Dockerfile，本地开发版本 `mise.toml` |
| [`scripts/check_versions.py`](scripts/check_versions.py) | 核对版本一致性，查询运行时停止维护日期 |
| [`.github/workflows/`](.github/workflows/) | `base-image` / `web-image`：镜像检查与发布；`versions`：每周维护期提醒 |
| [`renovate.json`](renovate.json) | 基础镜像和 Actions 的自动升级 |
