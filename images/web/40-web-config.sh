#!/bin/sh
# 把 WEB_PUBLIC_ 开头的环境变量写成 /config.js，让同一个镜像在不同环境使用不同配置：
#   WEB_PUBLIC_API_BASE=/api  →  window.__APP_CONFIG__ = {"API_BASE": "/api"};
# 页面在加载主程序之前引入：<script src="/config.js"></script>
# 这些值会原样发给浏览器，不要放密钥。
set -eu

mkdir -p /tmp/web
awk 'BEGIN {
    n = 0
    for (k in ENVIRON)
        if (k ~ /^WEB_PUBLIC_[A-Za-z0-9_]+$/) keys[++n] = k
    for (i = 2; i <= n; i++) {            # 排序，输出稳定
        k = keys[i]
        for (j = i - 1; j > 0 && keys[j] > k; j--) keys[j + 1] = keys[j]
        keys[j + 1] = k
    }
    printf "window.__APP_CONFIG__ = {"
    for (i = 1; i <= n; i++) {
        v = ENVIRON[keys[i]]
        gsub(/\\/, "\\\\", v)
        gsub(/"/, "\\\"", v)
        gsub(/\n/, "\\n", v)
        gsub(/\r/, "\\r", v)
        gsub(/\t/, "\\t", v)
        gsub(/</, "\\u003c", v)
        printf "%s\"%s\": \"%s\"", (i > 1 ? ", " : ""), substr(keys[i], 12), v
    }
    print "};"
}' > /tmp/web/config.js

echo "$0: 已生成 /config.js（$(grep -o '": "' /tmp/web/config.js | wc -l) 项）"
