#!/usr/bin/env bash
# reach-doctor.sh — channels.yml에 선언된 후보를 읽기 전용 probe로 진단한다.
# usage: reach-doctor.sh [--json]
# 종료코드: 0=가용 후보 있음, 2=채널 계약 위반, 3=가용 후보 없음, 64=사용법 오류
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3

[ $# -eq 0 ] || [ $# -eq 1 -a "$1" = "--json" ] || usage_die "usage: $0 [--json]"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 - "$SCRIPT_DIR/../contracts/channels.yml" "${1:-}" <<'PY'
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

PATH, JSON_MODE = sys.argv[1:3]
LISTS = ("backends", "ladder", "modes", "commands", "url_prefixes", "probes", "when")
SECRET = re.compile(r"(?i)(\b[\w-]*(?:key|token|cookie|secret|session|auth|cred)[\w-]*\s*[:=]\s*)([^\s,;&]+)")
QUERY_SECRET = re.compile(r"(?i)([?&][^=&\s]*(?:key|token|cookie|secret|session|auth|cred)[^=&\s]*=)[^&#\s]*")

def die(code, message): print(message, file=sys.stderr); raise SystemExit(code)
def scrub(value):
    text = SECRET.sub(r"\1[REDACTED]", str(value))
    return QUERY_SECRET.sub(lambda m: m.group(1).split("=", 1)[0] + "=[REDACTED]", text)
def uncomment(line):
    quote = None
    for index, char in enumerate(line):
        if char in "'\"": quote = None if quote == char else (char if quote is None else quote)
        elif char == "#" and quote is None: return line[:index]
    return line
def scalar(value):
    value = value.strip()
    if len(value) > 1 and value[0] == value[-1] and value[0] in "'\"": return value[1:-1]
    if value.startswith("[") and value.endswith("]"):
        return [scalar(item) for item in re.split(r",(?=(?:[^'\"]|'[^']*'|\"[^\"]*\")*$)", value[1:-1]) if item.strip()]
    return value
def load(path):
    try: lines = open(path, encoding="utf-8").read().splitlines()
    except FileNotFoundError: die(3, "channels.yml 없음: " + path)
    except OSError as exc: die(2, "channels.yml 읽기 실패: " + scrub(exc))
    rows, row = [], None
    for raw in lines:
        line = uncomment(raw).rstrip()
        if not line.strip(): continue
        body, indent = line.lstrip(), len(line) - len(line.lstrip())
        if body.startswith("- ") and not indent:
            if row is not None: rows.append(row)
            row, body = {}, body[2:]
        if row is None or ":" not in body: die(2, "channels.yml은 최상위 채널 목록이어야 한다.")
        key, value = body.split(":", 1); row[key.strip()] = scalar(value)
    if row is not None: rows.append(row)
    if not rows: die(2, "channels.yml에 채널이 없다.")
    for row in rows:
        if not row.get("name"): die(2, "channels.yml 채널 name이 없다.")
        for field in LISTS:
            if not isinstance(row.get(field), list) or not row[field]: die(2, "channels.yml " + str(row["name"]) + "." + field + " 목록이 없다.")
        count = len(row["backends"])
        if any(len(row[field]) != count for field in LISTS): die(2, "channels.yml 후보 목록 길이가 다르다.")
        row["steps"] = [dict(zip(LISTS, values)) for values in zip(*(row[field] for field in LISTS))]
    return rows
def command_probe(argv):
    if not argv or not shutil.which(argv[0]): return "missing", (argv[0] + " 없음" if argv else "빈 probe")
    try: done = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8, check=False)
    except subprocess.TimeoutExpired: return "timeout", "8초 초과"
    except OSError as exc: return "broken", type(exc).__name__
    return ("ok", "probe 성공") if done.returncode == 0 else ("broken", "probe exit " + str(done.returncode))
def http_probe(url):
    try:
        request = urllib.request.Request(url, headers={"User-Agent":"assay-doctor/1"})
        with urllib.request.urlopen(request, timeout=8) as response: response.read(1)
        return "ok", "읽기 probe 성공"
    except urllib.error.HTTPError as exc: return "warn", "HTTP " + str(exc.code) + " (클라이언트는 가용)"
    except (urllib.error.URLError, TimeoutError, OSError) as exc: return "warn", "네트워크 미확인: " + type(exc).__name__
def probe(step):
    if str(step["modes"]) == "manual": return "warn", "사람 수동 입력 전용"
    value = str(step["probes"]).strip()
    if not value: return "broken", "probe 선언 없음"
    if value.startswith("http://") or value.startswith("https://"): return http_probe(value)
    try: return command_probe(shlex.split(value))
    except ValueError: return "broken", "probe 인용부호 오류"
def choose(candidates):
    for candidate in candidates:
        if candidate["backend"] != "manual" and candidate["status"] == "ok": return candidate
    for candidate in candidates:
        if candidate["backend"] != "manual" and candidate["status"] == "warn": return candidate
    return None
def main():
    reports = []
    for row in load(PATH):
        candidates = []
        for step in row["steps"]:
            status, note = probe(step)
            candidates.append({"ladder":str(step["ladder"]),"backend":str(step["backends"]),"status":status,"note":scrub(note)})
        active = choose(candidates); status = active["status"] if active else "missing"
        reports.append({"name":str(row["name"]),"status":status,"active_backend":active["backend"] if active else None,"note":active["note"] if active else "가용 후보 없음","candidates":candidates})
    if JSON_MODE: print(json.dumps({"channels":reports}, ensure_ascii=False, separators=(",", ":")))
    else:
        for report in reports:
            print("[" + report["status"] + "] " + report["name"] + ": " + (report["active_backend"] or "-") + " — " + report["note"])
            for candidate in report["candidates"]: print("  " + candidate["ladder"] + " " + candidate["backend"] + ": " + candidate["status"] + " — " + candidate["note"])
    return 0 if any(report["status"] in ("ok", "warn") for report in reports) else 3
try: raise SystemExit(main())
except BrokenPipeError: raise SystemExit(2)
PY
