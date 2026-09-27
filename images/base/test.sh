#!/usr/bin/env bash
# 检查基础镜像的内容是否符合约定。用法：test.sh <runtime 镜像> <build 镜像>
set -euo pipefail

runtime=$1
build=$2
fail=0

check() {
  local name=$1 image=$2 cmd=$3 expect=$4 out
  out=$(docker run --rm --entrypoint sh "$image" -c "$cmd" 2>&1) || true
  if [[ "$out" == *"$expect"* ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: 期望包含 [$expect]，实际 [$out]"
    fail=1
  fi
}

for image in "$runtime" "$build"; do
  echo "== $image"
  check "Debian 13"      "$image" '. /etc/os-release; echo $VERSION_CODENAME' 'trixie'
  check "Python 3.12"    "$image" 'python3 -V'                                'Python 3.12.'
  check "Node 24"        "$image" 'node -v'                                   'v24.'
  check "node 可运行"    "$image" 'node -e "console.log(1+1)"'               '2'
  check "node:sqlite"    "$image" 'node -e "new (require(\"node:sqlite\").DatabaseSync)(\":memory:\"); console.log(\"sqlite ok\")" 2>/dev/null' 'sqlite ok'
  check "tini"           "$image" 'tini --version'                            'tini version'
  check "时区"           "$image" 'date +%Z'                                  'CST'
  check "Python 时区"    "$image" 'python3 -c "import time; print(time.strftime(\"%z\"))"' '+0800'
  check "Node 时区"      "$image" 'node -e "console.log(new Date().getTimezoneOffset())"' '-480'
  check "字符集"         "$image" 'python3 -c "import sys; print(sys.getfilesystemencoding())"' 'utf-8'
  check "app 用户"       "$image" 'id app'                                    'uid=10001(app) gid=10001(app)'
  check "HTTPS 证书"     "$image" 'test -s /etc/ssl/certs/ca-certificates.crt && echo yes' 'yes'
done

echo "== 只在 build 里有"
check "npm"            "$build"   'npm -v'                   '.'
check "npx"            "$build"   'npx --version'            '.'
check "uv"             "$build"   'uv --version'             'uv '
check "uv 用系统 Python" "$build" 'uv python find'           '/usr/local/bin/python'
check "NODE_ENV 未设置" "$build"  'echo "[${NODE_ENV:-}]"'   '[]'

echo "== 只在 runtime 里有"
check "没有 npm"       "$runtime" 'command -v npm || echo none' 'none'
check "没有 uv"        "$runtime" 'command -v uv || echo none'  'none'
check "NODE_ENV"       "$runtime" 'echo $NODE_ENV'              'production'

exit $fail
