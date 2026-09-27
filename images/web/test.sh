#!/usr/bin/env bash
# 检查前端镜像：用一个示例站点启动容器，验证路由、缓存头、安全头、运行时配置、用户和优雅退出。
# 用法：test.sh <web 镜像>
# shellcheck disable=SC2016,SC1091,SC2329
set -euo pipefail

cd "$(dirname "$0")"
. ./versions.env

web=$1
site="web-test-site:local"
name=web-test-$$
port=18080
work=$(mktemp -d)
fail=0

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

mkdir -p "$work/dist/assets"
echo '<!doctype html><title>t</title><script src="/config.js"></script>index-page' > "$work/dist/index.html"
{ echo 'console.log("app")'; for _ in $(seq 1 200); do echo '// padding so the file is large enough to be gzipped'; done; } > "$work/dist/assets/app-Bx12Kd9a.js"
printf 'FROM %s\nCOPY dist/ /usr/share/nginx/html/\n' "$web" > "$work/Dockerfile"
docker build -q -t "$site" "$work" >/dev/null

docker run -d --name "$name" --health-interval=1s -p "127.0.0.1:$port:8080" \
  -e WEB_PUBLIC_API_BASE=/api \
  -e 'WEB_PUBLIC_TITLE=A "quoted" \ value</script>' \
  -e SECRET_NOT_PUBLIC=hidden \
  "$site" >/dev/null

for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break; sleep 0.5; done

check() {
  local name=$1 actual=$2 expect=$3
  if [[ "$actual" == *"$expect"* ]]; then echo "ok   $name"; else echo "FAIL $name: 期望包含 [$expect]，实际 [$actual]"; fail=1; fi
}
get()     { curl -s "http://127.0.0.1:$port$1"; }
status()  { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port$1"; }
headers() { curl -s -D - -o /dev/null "http://127.0.0.1:$port$1" | tr -d '\r'; }
inside()  { docker exec "$name" sh -c "$1" 2>&1; }

check "Nginx $NGINX"             "$(inside 'nginx -v')"                    "nginx/$NGINX."
check "Debian $DEBIAN"           "$(inside '. /etc/os-release; echo "v=$VERSION_ID"')" "v=$DEBIAN"
check "非 root"                  "$(inside 'id -u')"                       "101"
check "时区"                     "$(inside 'date +%Z')"                    "CST"
check "页面目录只读"             "$(inside 'touch /usr/share/nginx/html/x || echo denied')" "denied"
check "healthz"                  "$(get /healthz)"                         "ok"
check "首页"                     "$(get /)"                                "index-page"
check "前端路由回退到首页"       "$(get /some/client/route)"               "index-page"
check "静态资源"                 "$(get /assets/app-Bx12Kd9a.js)"          'console.log("app")'
check "缺失的资源返回 404"       "$(status /assets/missing.js)"            "404"
check "资源长期缓存"             "$(headers /assets/app-Bx12Kd9a.js)"      "immutable"
check "首页不缓存"               "$(headers /)"                            "Cache-Control: no-cache"
check "首页安全头"               "$(headers /)"                            "Content-Security-Policy: default-src 'self'"
check "资源也带安全头"           "$(headers /assets/app-Bx12Kd9a.js)"      "X-Content-Type-Options: nosniff"
check "不暴露版本号"             "$(headers /)"                            "Server: nginx"$'\n'
check "gzip"                     "$(curl -s -D - -o /dev/null -H 'Accept-Encoding: gzip' "http://127.0.0.1:$port/assets/app-Bx12Kd9a.js" | tr -d '\r')" "Content-Encoding: gzip"
check "config.js 内容"           "$(get /config.js)"                       'window.__APP_CONFIG__ = {"API_BASE": "/api", "TITLE": "A \"quoted\" \\ value\u003c/script>"};'
check "config.js 不含其他变量"   "$(get /config.js | grep -c hidden || true)" "0"
check "config.js 不缓存"         "$(headers /config.js)"                   "Cache-Control: no-store"
check "config.js 类型"           "$(headers /config.js)"                   "Content-Type: application/javascript"
check "config.js 是合法 JS"      "$(get /config.js | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const window={};eval(s);console.log(window.__APP_CONFIG__.TITLE)})' 2>&1)" 'A "quoted" \ value</script>'

health=starting
for _ in $(seq 1 30); do
  health=$(docker inspect "$name" --format '{{.State.Health.Status}}')
  [ "$health" = starting ] || break
  sleep 1
done
check "健康检查"                 "$health"                                 "healthy"

start=$(date +%s)
docker stop "$name" >/dev/null
took=$(( $(date +%s) - start ))
check "docker stop 10 秒内退出"  "$([ "$took" -lt 10 ] && echo fast || echo "slow ${took}s")" "fast"
check "退出码 0"                 "$(docker inspect "$name" --format '{{.State.ExitCode}}')" "0"

exit $fail
