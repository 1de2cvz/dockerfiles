# dockerfiles

组织内镜像的公共部分：规范、共享基础镜像和项目模板。各项目的 Dockerfile 仍放在项目自己的仓库里。

| 路径 | 内容 |
|---|---|
| [`STANDARD.md`](STANDARD.md) | 容器镜像规范 |
| [`images/base/`](images/base/README.md) | 共享基础镜像：Python 3.12 + Node.js 24，Debian 13；另有 Java 8 变体 |
| [`images/base/versions.env`](images/base/versions.env) | 运行时主版本的唯一来源 |
| [`templates/`](templates/) | 项目模板：Python 服务 Dockerfile、本地开发版本 `mise.toml` |
| [`scripts/check_versions.py`](scripts/check_versions.py) | 核对版本一致性，查询运行时停止维护日期 |
| [`.github/workflows/`](.github/workflows/) | `base-image`：基础镜像检查与发布；`versions`：每周维护期提醒 |
| [`renovate.json`](renovate.json) | 基础镜像和 Actions 的自动升级 |
