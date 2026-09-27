# syntax=docker/dockerfile:1
#
# 共享基础镜像：Python 3.12 + Node.js 24，Debian 13 (trixie)。
#
# 两个目标：
#   runtime  运行时基础。python、node、tini，没有 npm / uv。项目的最终阶段 FROM 它。
#   build    构建基础。在 runtime 之上加 npm、uv。项目的构建阶段 FROM 它。
#
# 两个目标来自同一个 core 阶段，构建阶段和运行阶段的 glibc、Python、Node 完全一致。

ARG PYTHON_IMAGE=python:3.12.14-slim-trixie@sha256:f77ac9e44ae96ef2c90b8053ea08c31f8be030f824196b0ae4db6d462c84e51f
ARG NODE_IMAGE=node:24.21.0-trixie-slim@sha256:8ec5d7557396cfe32d21c3f9c13072355ceab22b584578ca4bb28af31120cffe
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.12.19

FROM ${NODE_IMAGE} AS node
FROM ${UV_IMAGE} AS uv

FROM ${PYTHON_IMAGE} AS core

# 内网构建时替换 Debian 源，例如 https://mirrors.aliyun.com。留空则用官方源。
ARG APT_MIRROR=

ENV LANG=C.UTF-8 \
    TZ=Asia/Shanghai \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# ca_cert：HTTPS 解密代理或内网源的 CA 证书，只在本步骤挂载，不进镜像。
RUN --mount=type=secret,id=ca_cert,required=false \
    set -eux; \
    if [ -n "$APT_MIRROR" ]; then \
        sed -i "s#http://deb.debian.org#${APT_MIRROR%/}#g" /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt_opts=""; \
    if [ -s /run/secrets/ca_cert ]; then apt_opts="-o Acquire::https::CaInfo=/run/secrets/ca_cert"; fi; \
    apt-get $apt_opts update; \
    apt-get $apt_opts install -y --no-install-recommends tini tzdata; \
    rm -rf /var/lib/apt/lists/*; \
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime; \
    echo "$TZ" > /etc/timezone; \
    groupadd --gid 10001 app; \
    useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin app

COPY --from=node /usr/local/bin/node /usr/local/bin/node

WORKDIR /app


FROM core AS build

COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
COPY --from=uv /uv /uvx /usr/local/bin/

RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# uv 只用镜像里的 Python，不自行下载；copy 模式配合 BuildKit 缓存挂载。
ENV UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON=/usr/local/bin/python3 \
    UV_LINK_MODE=copy


FROM core AS runtime

ENV NODE_ENV=production
