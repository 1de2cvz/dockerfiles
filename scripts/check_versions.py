#!/usr/bin/env python3
"""检查基础镜像的运行时版本：

1. 一致性：images/base/Dockerfile 里的上游镜像和 images/base/versions.env 是否一致。
2. 维护期：到 endoflife.date 查询每个运行时的停止维护日期，快到期或已到期时提醒。

只用标准库。用法：

    scripts/check_versions.py                 # 两项都查
    scripts/check_versions.py --offline       # 只查一致性（无法访问外网时）
    scripts/check_versions.py --strict        # 有运行时已停止维护时返回非 0
    scripts/check_versions.py --issue-file f  # 有需要处理的项时，把 issue 正文写到 f

退出码：0 正常；1 版本不一致；2 已停止维护（仅 --strict）；3 查询失败（仅 --strict）。
环境变量 EOL_API_BASE 可替换 endoflife.date 的地址（内网镜像或测试用）。
"""

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / "images" / "base"
API = os.environ.get("EOL_API_BASE", "https://endoflife.date").rstrip("/")

DEBIAN_CODENAMES = {"12": "bookworm", "13": "trixie", "14": "forky"}

# 名称、versions.env 里的键、endoflife.date 的产品 ID、按哪个日期算到期。
# Debian 按常规安全支持结束（eoas）算，之后的 LTS 只修部分软件包。
RUNTIMES = [
    ("Debian", "DEBIAN", "debian", "eoas"),
    ("Python", "PYTHON", "python", "eol"),
    ("Node.js", "NODE", "nodejs", "eol"),
    ("Java (Temurin)", "JAVA", "eclipse-temurin", "eol"),
]

WARN_DAYS = 180


def read_env(path):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def read_dockerfile_args(path):
    args = {}
    for match in re.finditer(r"^ARG\s+(\w+)=(\S+)", path.read_text(encoding="utf-8"), re.M):
        args[match.group(1)] = match.group(2)
    return args


def check_consistency(versions, args):
    """返回问题列表，每项是一句说明。"""
    codename = DEBIAN_CODENAMES.get(versions["DEBIAN"])
    if codename is None:
        return [f"versions.env 的 DEBIAN={versions['DEBIAN']} 没有对应的代号，请补充 DEBIAN_CODENAMES"]

    py, node, java = (re.escape(versions[k]) for k in ("PYTHON", "NODE", "JAVA"))
    digest = r"@sha256:[0-9a-f]{64}$"
    rules = {
        "PYTHON_IMAGE": (rf"^python:{py}\.\d+-slim-{codename}{digest}",
                         f"python:{versions['PYTHON']}.<补丁>-slim-{codename}@sha256:..."),
        "NODE_IMAGE": (rf"^node:{node}\.\d+\.\d+-{codename}-slim{digest}",
                       f"node:{versions['NODE']}.<次>.<补丁>-{codename}-slim@sha256:..."),
        "JRE_IMAGE": (rf"^eclipse-temurin:{java}(u[\w.-]*)?-jre(-[\w.]+)?{digest}",
                      f"eclipse-temurin:{versions['JAVA']}-jre@sha256:..."),
        "JDK_IMAGE": (rf"^eclipse-temurin:{java}(u[\w.-]*)?-jdk(-[\w.]+)?{digest}",
                      f"eclipse-temurin:{versions['JAVA']}-jdk@sha256:..."),
        "UV_IMAGE": (r"^[\w./-]+:\d+\.\d+\.\d+(@sha256:[0-9a-f]{64})?$",
                     "ghcr.io/astral-sh/uv:<固定版本>"),
    }
    problems = []
    for arg, (pattern, expected) in rules.items():
        value = args.get(arg)
        if value is None:
            problems.append(f"Dockerfile 缺少 `ARG {arg}`")
        elif not re.match(pattern, value):
            problems.append(f"Dockerfile 的 `{arg}={value}` 与 versions.env 不一致，应为 `{expected}`")
    return problems


def fetch_json(url):
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "check_versions"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def to_date(value):
    """endoflife.date 的日期字段可能是日期字符串、true/false 或空。"""
    if isinstance(value, str):
        return dt.date.fromisoformat(value[:10])
    return None


def fetch_release(product, cycle):
    """返回 {'eol': date|None, 'eoas': date|None, 'latest': str|None}。先用 v1 接口，失败再用旧接口。"""
    try:
        result = fetch_json(f"{API}/api/v1/products/{product}/releases/{cycle}")["result"]
        latest = result.get("latest") or {}
        return {
            "eol": to_date(result.get("eolFrom")),
            "eoas": to_date(result.get("eoasFrom")),
            "latest": latest.get("name") if isinstance(latest, dict) else latest,
        }
    except (urllib.error.URLError, KeyError, ValueError, TimeoutError):
        pass
    data = fetch_json(f"{API}/api/{product}/{cycle}.json")
    return {
        "eol": to_date(data.get("eol")),
        "eoas": to_date(data.get("support")),
        "latest": data.get("latest"),
    }


def check_eol(versions, today):
    rows = []
    for name, key, product, field in RUNTIMES:
        cycle = versions[key]
        row = {"name": name, "cycle": cycle, "field": field, "date": None, "days": None,
               "latest": None, "status": "unknown", "error": None}
        try:
            release = fetch_release(product, cycle)
            row["latest"] = release["latest"]
            # 没有 eoas 的产品（如 Temurin）退回用 eol。
            row["date"] = release[field] or release["eol"]
            if row["date"] is None:
                row["status"] = "ok"
            else:
                row["days"] = (row["date"] - today).days
                row["status"] = "expired" if row["days"] < 0 else "warn" if row["days"] < WARN_DAYS else "ok"
        except Exception as exc:  # noqa: BLE001 - 查询失败不应掩盖其他结果
            row["error"] = f"{type(exc).__name__}: {exc}"
        rows.append(row)
    return rows


STATUS_TEXT = {"ok": "✅ 正常", "warn": "⚠️ 即将到期", "expired": "❌ 已停止维护", "unknown": "❔ 查询失败"}


def render(problems, rows, today):
    lines = [f"## 基础镜像运行时版本（{today}）", ""]
    if problems:
        lines += ["### ❌ 版本不一致", ""] + [f"- {p}" for p in problems] + [""]
    else:
        lines += ["✅ Dockerfile 与 versions.env 一致。", ""]
    if rows is not None:
        lines += [
            "| 运行时 | 主版本 | 停止维护 | 剩余天数 | 最新补丁 | 状态 |",
            "|---|---|---|---|---|---|",
        ]
        for r in rows:
            date = "—" if r["date"] is None else f"{r['date']}{'（常规安全支持）' if r['field'] == 'eoas' else ''}"
            days = "—" if r["days"] is None else str(r["days"])
            status = STATUS_TEXT[r["status"]] + (f"：{r['error']}" if r["error"] else "")
            lines.append(f"| {r['name']} | {r['cycle']} | {date} | {days} | {r['latest'] or '—'} | {status} |")
        lines += ["", f"剩余不足 {WARN_DAYS} 天即提醒。数据来源：endoflife.date。"]
    return "\n".join(lines) + "\n"


def render_issue(problems, rows):
    todo = [r for r in rows or [] if r["status"] in ("warn", "expired")]
    if not todo and not problems:
        return None
    lines = ["以下运行时需要安排升级（由 `versions` 工作流自动维护，处理完后会自动关闭）：", ""]
    for r in todo:
        verb = "已于" if r["status"] == "expired" else "将于"
        lines.append(f"- **{r['name']} {r['cycle']}** {verb} {r['date']} 停止维护（剩余 {r['days']} 天）")
    for p in problems:
        lines.append(f"- {p}")
    lines += ["", "升级步骤见 `images/base/README.md` 的「升级」一节。"]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--offline", action="store_true", help="只查一致性，不访问 endoflife.date")
    parser.add_argument("--strict", action="store_true", help="已停止维护或查询失败时返回非 0")
    parser.add_argument("--issue-file", type=Path, help="有需要处理的项时，把 issue 正文写到这个文件")
    parser.add_argument("--today", type=dt.date.fromisoformat, default=dt.date.today(), help=argparse.SUPPRESS)
    opts = parser.parse_args()

    versions = read_env(BASE / "versions.env")
    problems = check_consistency(versions, read_dockerfile_args(BASE / "Dockerfile"))
    rows = None if opts.offline else check_eol(versions, opts.today)

    report = render(problems, rows, opts.today)
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(report)

    if opts.issue_file:
        body = render_issue(problems, rows)
        if body:
            opts.issue_file.write_text(body, encoding="utf-8")
        elif opts.issue_file.exists():
            opts.issue_file.unlink()

    if problems:
        return 1
    if opts.strict and rows:
        if any(r["status"] == "expired" for r in rows):
            return 2
        if any(r["status"] == "unknown" for r in rows):
            return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
