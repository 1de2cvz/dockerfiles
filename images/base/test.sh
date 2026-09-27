#!/usr/bin/env bash
# 检查命令在容器里执行，单引号是有意的。
# shellcheck disable=SC2016,SC1091
# 检查基础镜像的内容是否符合约定，版本号以 versions.env 为准。
# 用法：test.sh <runtime 镜像> <build 镜像> [<runtime-java 镜像> <build-java 镜像>]
set -euo pipefail

cd "$(dirname "$0")"
. ./versions.env

runtime=$1
build=$2
runtime_java=${3:-}
build_java=${4:-}
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

common() {
  local image=$1
  echo "== $image"
  check "Debian $DEBIAN"     "$image" '. /etc/os-release; echo "v=$VERSION_ID"'  "v=$DEBIAN"
  check "Python $PYTHON"     "$image" 'python3 -V'                                "Python $PYTHON."
  check "Node $NODE"         "$image" 'node -v'                                   "v$NODE."
  check "node 可运行"        "$image" 'node -e "console.log(1+1)"'               '2'
  check "node:sqlite"        "$image" 'node -e "new (require(\"node:sqlite\").DatabaseSync)(\":memory:\"); console.log(\"sqlite ok\")" 2>/dev/null' 'sqlite ok'
  check "tini"               "$image" 'tini --version'                            'tini version'
  check "apt-install"        "$image" 'command -v apt-install'                    '/usr/local/bin/apt-install'
  check "时区"               "$image" 'date +%Z'                                  'CST'
  check "Python 时区"        "$image" 'python3 -c "import time; print(time.strftime(\"%z\"))"' '+0800'
  check "Node 时区"          "$image" 'node -e "console.log(new Date().getTimezoneOffset())"' '-480'
  check "字符集"             "$image" 'python3 -c "import sys; print(sys.getfilesystemencoding())"' 'utf-8'
  check "app 用户"           "$image" 'id app'                                    'uid=10001(app) gid=10001(app)'
  check "HTTPS 证书"         "$image" 'test -s /etc/ssl/certs/ca-certificates.crt && echo yes' 'yes'
}

build_tools() {
  local image=$1
  check "npm"                "$image" 'npm -v'                   '.'
  check "npx"                "$image" 'npx --version'            '.'
  check "uv"                 "$image" 'uv --version'             'uv '
  check "uv 用系统 Python"   "$image" 'uv python find'           '/usr/local/bin/python'
  check "NODE_ENV 未设置"    "$image" 'echo "[${NODE_ENV:-}]"'   '[]'
}

no_build_tools() {
  local image=$1
  check "没有 npm"           "$image" 'command -v npm || echo none' 'none'
  check "没有 uv"            "$image" 'command -v uv || echo none'  'none'
  check "NODE_ENV"           "$image" 'echo $NODE_ENV'              'production'
}

# Java 8 的版本号写作 1.8.0_xxx，之后的版本写作 11.0.x 这样。
java_version_prefix() { if [ "$JAVA" = 8 ]; then echo "1.8.0_"; else echo "\"$JAVA."; fi; }

# JRE 里没有 javac，这里只查版本、编码和字体文件；实际渲染字体在 build-java 里编译一段程序检查。
java_common() {
  local image=$1
  check "Java $JAVA"         "$image" 'java -version 2>&1'       "$(java_version_prefix)"
  check "JAVA_HOME"          "$image" 'echo $JAVA_HOME'          '/opt/java/openjdk'
  check "fontconfig 有字体"  "$image" 'fc-list | head -1'        '.ttf'
  check "Java 编码"          "$image" 'java -XshowSettings:properties -version 2>&1 | grep "file.encoding ="' 'UTF-8'
}

common "$runtime";  no_build_tools "$runtime"
common "$build";    build_tools "$build"

if [ -n "$runtime_java" ]; then
  common "$runtime_java"; no_build_tools "$runtime_java"; java_common "$runtime_java"
  check "JRE 里没有 javac" "$runtime_java" 'command -v javac || echo none' 'none'
fi
if [ -n "$build_java" ]; then
  common "$build_java"; build_tools "$build_java"; java_common "$build_java"
  check "javac"            "$build_java" 'javac -version 2>&1' 'javac'
  # 编译并运行一段用到时区、编码、字体的程序，覆盖 JRE 检查不到的部分。
  check "Java 时区/编码/字体" "$build_java" 'cd /tmp && cat > T.java <<EOF
import java.awt.*; import java.awt.image.*; import java.util.*;
public class T { public static void main(String[] a) {
  Graphics2D g = new BufferedImage(10, 10, BufferedImage.TYPE_INT_RGB).createGraphics();
  g.setFont(new Font("SansSerif", Font.PLAIN, 12));
  System.out.println(TimeZone.getDefault().getID() + " " + System.getProperty("file.encoding") + " font=" + (g.getFontMetrics().stringWidth("abc") > 0));
}}
EOF
javac T.java && java -Djava.awt.headless=true T' 'Asia/Shanghai UTF-8 font=true'
fi

exit $fail
