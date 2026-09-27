# 前端镜像 `web`

独立的纯前端项目（单页应用）用它作为最终镜像：官方非 root 版 Nginx，里面只放编译好的静态文件。页面在构建阶段用共享基础镜像的 build 变体编译，最终镜像里没有 Node、npm。

| 项 | 值 |
|---|---|
| 镜像 | `ghcr.io/1de2cvz/web:nginx1.30`（另有不可变的 `nginx1.30-sha-<提交号>`） |
| 上游 | `nginxinc/nginx-unprivileged:1.30-trixie`（Nginx 1.30 稳定版，Debian 13），固定 digest |
| 平台 | `linux/amd64`、`linux/arm64` |
| 大小 | 解压后约 157 MB |
| 用户 | `nginx`，uid 101（官方镜像的用户）。没有数据卷，不受规范 UID ≥ 10000 的约束 |
| 端口 | `8080` |
| 页面目录 | `/usr/share/nginx/html`，属主 root，运行时只读 |
| 时区 / 字符集 | `Asia/Shanghai` / `C.UTF-8` |
| 健康检查 | `GET /healthz`，间隔 30 秒 |

## 内置的站点配置

| 路径 | 行为 |
|---|---|
| `/assets/*` | 带哈希的构建产物（Vite 默认输出目录）；缓存一年（`immutable`）；不存在时返回 404 |
| `/config.js` | 运行时配置，见下一节；不缓存 |
| `/healthz` | 返回 `ok`，不记访问日志 |
| 其他路径 | 找得到文件就返回文件，找不到回退到 `index.html`，交给前端路由；`index.html` 不缓存（`no-cache`），发版后浏览器马上拿到新页面 |

另外：gzip 压缩、不暴露 Nginx 版本号、所有响应带安全头（`X-Content-Type-Options`、`X-Frame-Options`、`Referrer-Policy`、`Content-Security-Policy`）。

默认 CSP 只允许同源资源（规范 5.6：页面不引用外部 CDN）。需要放宽时，在项目里覆盖：

```dockerfile
COPY security-headers.conf /etc/nginx/snippets/security-headers.conf
```

## 运行时配置 `/config.js`

同一个镜像在测试、生产等不同环境用不同配置，不重新构建。容器启动时把 `WEB_PUBLIC_` 开头的环境变量写成 `/config.js`：

```bash
docker run -e WEB_PUBLIC_API_BASE=https://api.example.com ghcr.io/1de2cvz/<项目>
```

```js
// GET /config.js
window.__APP_CONFIG__ = {"API_BASE": "https://api.example.com"};
```

页面在主程序之前引入：

```html
<script src="/config.js"></script>
```

- 只有 `WEB_PUBLIC_` 开头的变量会写进去，其他环境变量不会暴露。
- 这些值会原样发给浏览器，**不要放密钥**。
- 值里的引号、反斜杠、换行、`<` 都已转义。

## 项目怎么用

完整模板见 [`templates/static-site.Dockerfile`](../../templates/static-site.Dockerfile)：

```dockerfile
FROM ghcr.io/1de2cvz/base:py3.12-node24-build AS build
# npm ci && npm run build → /src/dist

FROM ghcr.io/1de2cvz/web:nginx1.30
COPY --from=build /src/dist/ /usr/share/nginx/html/
```

约定：`npm run build` 输出到 `dist/`，带哈希的资源放在 `dist/assets/`（Vite 默认如此；其他构建工具按此配置）。

## 什么时候不用它

- 前端属于某个后端服务（例如 `agent-runtime`）：由后端同源提供静态文件，不单独做前端镜像。
- HTTPS、域名、多个服务按路径转发：交给部署层的反向代理，不在这个镜像里做。

## 检查与升级

- `test.sh`：用示例站点启动容器，检查路由回退、404、缓存头、安全头、gzip、`/config.js` 的内容和转义、非 root、只读、健康检查、优雅退出。

  ```bash
  images/web/test.sh <镜像>
  ```

- CI：`.github/workflows/web-image.yml`，PR 上构建、检查、扫描漏洞，合并到 `main` 后发布。
- 版本：`versions.env` 的 `NGINX` 为唯一来源，`scripts/check_versions.py` 核对 Dockerfile 与它一致。补丁版本和 digest 由 Renovate 升级。
- 换稳定版：Nginx 每年 4 月发布新的稳定版（偶数次版本号，如 1.32），上一个稳定版随即停止维护，`versions` 工作流会报出来。届时改 `versions.env` 和 Dockerfile 的 `NGINX_IMAGE`，发布新标签 `nginx1.32`，各项目切换。
