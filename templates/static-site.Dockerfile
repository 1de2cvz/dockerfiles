# syntax=docker/dockerfile:1
#
# 纯前端项目模板：用共享基础镜像的 build 变体编译页面，最终镜像基于 web（非 root Nginx），只放编译结果。
# 复制到项目根目录改名为 Dockerfile。约定：
#   - `npm run build` 把页面输出到 dist/，带哈希的资源在 dist/assets/（Vite 默认）
#   - 按环境变化的配置用 WEB_PUBLIC_* 环境变量传入，页面通过 /config.js 读取，不在构建时写死

ARG BUILD_IMAGE=ghcr.io/1de2cvz/base:py3.12-node24-build
ARG RUNTIME_IMAGE=ghcr.io/1de2cvz/web:nginx1.30

# ---- 编译 ----
FROM ${BUILD_IMAGE} AS build

ARG NPM_REGISTRY=https://registry.npmjs.org

WORKDIR /src
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=secret,id=ca_cert,required=false \
    if [ -s /run/secrets/ca_cert ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/ca_cert; fi; \
    npm ci --registry "$NPM_REGISTRY"

COPY . .
RUN npm run build

# ---- 运行 ----
FROM ${RUNTIME_IMAGE}

# 属主保持 root：nginx 用户只读。
COPY --from=build /src/dist/ /usr/share/nginx/html/
