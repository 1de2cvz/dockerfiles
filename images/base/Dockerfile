# syntax=docker/dockerfile:1
#
# 共享基础镜像：Python 3.12 + Node.js 24，Debian 13 (trixie)；可选 Java 8。
# 主版本以 versions.env 为准，修改上游镜像时两边保持一致。
#
# 目标（target）：
#   runtime       运行时基础：python、node、tini。项目的最终阶段 FROM 它。
#   build         构建基础：runtime + npm、uv。项目的构建阶段 FROM 它。
#   runtime-java  runtime + Java 8 JRE。
#   build-java    build + Java 8 JDK。
#
# 所有目标来自同一个 core 阶段，glibc、Python、Node 完全一致。

ARG PYTHON_IMAGE=python:3.12.14-slim-trixie@sha256:f77ac9e44ae96ef2c90b8053ea08c31f8be030f824196b0ae4db6d462c84e51f
ARG NODE_IMAGE=node:24.21.0-trixie-slim@sha256:8ec5d7557396cfe32d21c3f9c13072355ceab22b584578ca4bb28af31120cffe
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.12.19
# Temurin 是与发行版无关的通用 Linux 构建，只取 /opt/java/openjdk，所以不要求 Debian 代号一致。
# 标签 8-jre / 8-jdk 跟随 Java 8 最新更新，由 digest 固定，Renovate 负责升级 digest。
ARG JRE_IMAGE=eclipse-temurin:8-jre@sha256:66a7b358772dfdcc1486919a5ede66d6c7275f203a5fefddb39565c2a151a485
ARG JDK_IMAGE=eclipse-temurin:8-jdk@sha256:6f9f640cdc1a35e64b77daf1f48fcf7527953d9aa804916c8557e1aae954ecd5

FROM ${NODE_IMAGE} AS node
FROM ${UV_IMAGE} AS uv
FROM ${JRE_IMAGE} AS jre
FROM ${JDK_IMAGE} AS jdk

FROM ${PYTHON_IMAGE} AS core

# 内网构建时替换 Debian 源，例如 https://mirrors.aliyun.com。留空则用官方源。
ARG APT_MIRROR=

ENV LANG=C.UTF-8 \
    TZ=Asia/Shanghai \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# apt-install：装 Debian 包的统一入口，项目也用它（自动处理 ca_cert、清理索引）。
COPY apt-install /usr/local/bin/apt-install

# ca_cert：HTTPS 解密代理或内网源的 CA 证书，只在装包时挂载，不进镜像。
RUN --mount=type=secret,id=ca_cert,required=false \
    set -eux; \
    if [ -n "$APT_MIRROR" ]; then \
        sed -i "s#http://deb.debian.org#${APT_MIRROR%/}#g" /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-install tini tzdata; \
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


# Java 需要 fontconfig（连带一套 DejaVu 字体），否则生成图片、PDF、Excel 等用到字体的功能会报错。
# 中文字体按项目需要自行安装：apt-install fonts-noto-cjk
FROM build AS build-java

ENV JAVA_HOME=/opt/java/openjdk
ENV PATH=${JAVA_HOME}/bin:${PATH}

RUN --mount=type=secret,id=ca_cert,required=false apt-install fontconfig
COPY --from=jdk /opt/java/openjdk /opt/java/openjdk


FROM runtime AS runtime-java

ENV JAVA_HOME=/opt/java/openjdk
ENV PATH=${JAVA_HOME}/bin:${PATH}

RUN --mount=type=secret,id=ca_cert,required=false apt-install fontconfig
COPY --from=jre /opt/java/openjdk /opt/java/openjdk
