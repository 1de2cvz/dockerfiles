# syntax=docker/dockerfile:1
#
# 纯前端项目的运行时基础镜像：官方非 root 版 Nginx（Debian 13），只提供静态文件。
# 项目在构建阶段用 base:*-build 编译页面，最终阶段 FROM 本镜像，只复制编译结果：
#   COPY --from=build /src/dist/ /usr/share/nginx/html/
# Nginx 版本以 versions.env 为准。

ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:1.30-trixie@sha256:0918d093d6088225655ddf602fdf00679c1c0c9a89c01c6dcdce5ee5e6c2f3f3

FROM ${NGINX_IMAGE}

ENV LANG=C.UTF-8 \
    TZ=Asia/Shanghai

USER root

RUN set -eux; \
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime; \
    echo "$TZ" > /etc/timezone; \
    rm -f /etc/nginx/conf.d/default.conf /usr/share/nginx/html/*

COPY conf.d/ /etc/nginx/conf.d/
COPY snippets/ /etc/nginx/snippets/
COPY --chmod=755 40-web-config.sh /docker-entrypoint.d/

# 官方镜像的 nginx 用户（uid 101）。静态站点没有数据卷，不受 UID ≥ 10000 的约束。
USER 101

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:8080/healthz || exit 1
