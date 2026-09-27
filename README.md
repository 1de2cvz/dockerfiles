# dockerfiles

组织内镜像的公共部分：规范、共享基础镜像和项目模板。各项目的 Dockerfile 仍放在项目自己的仓库里。

| 路径 | 内容 |
|---|---|
| [`STANDARD.md`](STANDARD.md) | 容器镜像规范 |
| [`images/base/`](images/base/README.md) | 共享基础镜像：Python 3.12 + Node.js 24，Debian 13 |
| [`templates/`](templates/) | 项目 Dockerfile 模板 |
| [`.github/workflows/base-image.yml`](.github/workflows/base-image.yml) | 基础镜像的检查与发布 |
| [`renovate.json`](renovate.json) | 基础镜像和 Actions 的自动升级 |
