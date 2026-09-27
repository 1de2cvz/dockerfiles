# syntax=docker/dockerfile:1
#
# Python 服务模板：基于共享基础镜像，只加本项目的依赖和代码。
# 复制到项目根目录改名为 Dockerfile，按注释替换 <...> 处。

ARG BUILD_IMAGE=ghcr.io/1de2cvz/base:py3.12-node24-build
ARG RUNTIME_IMAGE=ghcr.io/1de2cvz/base:py3.12-node24

# ---- 依赖：按 uv.lock 安装到 /opt/venv ----
FROM ${BUILD_IMAGE} AS deps

ARG PIP_INDEX_URL=https://pypi.org/simple
ENV UV_DEFAULT_INDEX=${PIP_INDEX_URL} \
    UV_PROJECT_ENVIRONMENT=/opt/venv

WORKDIR /src
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=secret,id=ca_cert,required=false \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    if [ -s /run/secrets/ca_cert ]; then export SSL_CERT_FILE=/run/secrets/ca_cert; fi; \
    uv sync --frozen --no-dev --no-install-project

# ---- 运行 ----
FROM ${RUNTIME_IMAGE} AS runtime

ENV PATH=/opt/venv/bin:$PATH \
    PORT=8000

COPY --from=deps /opt/venv /opt/venv
COPY app/ /app/app/

# 数据目录属于 app 用户；代码目录属于 root，运行时只读。
RUN install -d -o app -g app /data
VOLUME ["/data"]

USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import os, urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/healthz', timeout=4)"

CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port \"$PORT\""]
