#!/usr/bin/env bash
# reach-fetch.sh — 선언된 접근 사다리를 순서대로 실행해 스냅샷과 접근 이력을 남긴다.
# R2가 쓰는 kind/confidence는 사다리별 정책 초기값일 뿐이다. 사람·에이전트는 R3
# (reach-gate.sh)에서 근거를 보고 이를 상향·하향 조정해 최종 신뢰도를 확정한다.
# usage: reach-fetch.sh <run-dir> <url> <axis-id> [--channel <name>]
# 종료코드: 0=ok, 1=전수 시도 후 실패, 2=계약 위반, 3=환경 미비, 64=사용법 오류
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3

[ $# -eq 3 ] || [ $# -eq 5 ] || usage_die "usage: $0 <run-dir> <url> <axis-id> [--channel <name>]"
[ $# -ne 5 ] || [ "$4" = "--channel" ] || usage_die "usage: $0 <run-dir> <url> <axis-id> [--channel <name>]"
seal_verify "$1/reach.conf"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 - "$SCRIPT_DIR/.." "$@" <<'PY'
import datetime as dt
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

SKILL, RUN, RAW_URL, AXIS = sys.argv[1:5]
CHANNEL_ARG = sys.argv[6] if len(sys.argv) == 7 else None
VERDICTS = {"ok", "partial", "challenge", "auth_required", "not_found", "rate_limited", "blocked"}
LISTS = ("backends", "ladder", "modes", "commands", "url_prefixes", "probes", "when")
SECRET = re.compile(r"(?i)(\b[\w-]*(?:key|token|cookie|secret|session|auth|cred)[\w-]*\s*[:=]\s*)([^\s,;&]+)")
QUERY_SECRET = re.compile(r"(?i)([?&][^=&\s]*(?:key|token|cookie|secret|session|auth|cred)[^=&\s]*=)[^&#\s]*")

def die(code, message): print(message, file=sys.stderr); raise SystemExit(code)
def stamp(): return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
def scrub(value):
    text = SECRET.sub(r"\1[REDACTED]", str(value))
    text = QUERY_SECRET.sub(lambda m: m.group(1).split("=", 1)[0] + "=[REDACTED]", text)
    return re.sub(r"//[^/@\s:]+:[^/@\s]+@", "//[REDACTED]@", text)
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
def load_channels(path):
    try: lines = open(path, encoding="utf-8").read().splitlines()
    except FileNotFoundError: die(3, "channels.yml 없음 — reach-doctor.sh로 환경을 확인하라.")
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
            value = row.get(field)
            if not isinstance(value, list) or not value: die(2, "channels.yml " + str(row["name"]) + "." + field + " 목록이 없다.")
        count = len(row["backends"])
        if any(len(row[field]) != count for field in LISTS): die(2, "channels.yml 후보 목록 길이가 다르다.")
        if len(set(row["ladder"])) != count or any(not re.fullmatch(r"L[0-4]", str(x)) for x in row["ladder"]): die(2, "channels.yml ladder는 중복 없는 L0~L4 목록이어야 한다.")
        if any(str(mode) not in {"command", "command-json", "http", "prefix-http", "manual"} for mode in row["modes"]): die(2, "channels.yml backend mode이 잘못되었다.")
        row["match"] = row.get("match", ["*"]); row["match"] = row["match"] if isinstance(row["match"], list) else [row["match"]]
        row["steps"] = [dict(zip(LISTS, values)) for values in zip(*(row[field] for field in LISTS))]
    return rows
def choose(rows):
    if CHANNEL_ARG:
        for row in rows:
            if row["name"] == CHANNEL_ARG: return row
        die(2, "알 수 없는 채널: " + CHANNEL_ARG)
    parsed = urllib.parse.urlsplit(RAW_URL); target = (parsed.hostname or "") + parsed.path
    for row in rows:
        if any(fnmatch.fnmatchcase(target, str(pattern)) or fnmatch.fnmatchcase(RAW_URL, str(pattern)) for pattern in row["match"]): return row
    die(2, "URL을 처리할 channels.yml 채널이 없다.")
def network_url(value):
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.netloc: die(2, "url은 공개 http(s) URL이어야 한다.")
    try: port = parsed.port
    except ValueError: die(2, "url 포트 형식이 올바르지 않다.")
    host = (parsed.hostname or "").encode("idna").decode("ascii")
    netloc = host + ((":" + str(port)) if port else "")
    return urllib.parse.urlunsplit((parsed.scheme, netloc, urllib.parse.quote(parsed.path, safe="/%:@"), parsed.query, ""))
def classify(text):
    low = text.lower()
    if "challenge" in low or "captcha" in low or "turnstile" in low or "access denied" in low: return "challenge"
    if "auth" in low: return "auth_required"
    if "404" in low: return "not_found"
    if "429" in low: return "rate_limited"
    return "blocked"
def http_fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "assay-reach-fetch/1"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read().decode(response.headers.get_content_charset() or "utf-8", "replace")
        return ("challenge" if classify(body) == "challenge" else ("partial" if len(body.strip()) < 80 else "ok")), body, ""
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        return ({401:"auth_required",404:"not_found",429:"rate_limited"}.get(exc.code, "challenge" if exc.code == 403 and classify(body) == "challenge" else "blocked")), "", "HTTP " + str(exc.code)
    except (urllib.error.URLError, TimeoutError, OSError) as exc: return "blocked", "", "network: " + type(exc).__name__
def command_fetch(step, url):
    try: argv = [item.replace("{url}", url) for item in shlex.split(str(step["commands"]))]
    except ValueError: die(2, "channels.yml command 인용부호 오류")
    if not argv: die(2, "channels.yml command가 비어 있다.")
    if not shutil.which(argv[0]): return None, "", "tool_missing: " + argv[0]
    try: done = subprocess.run(argv, text=True, capture_output=True, timeout=45, check=False)
    except subprocess.TimeoutExpired: return "blocked", "", "timeout"
    output = done.stdout
    if done.returncode: return classify(output + done.stderr), "", "backend failed"
    if step["modes"] == "command-json":
        try:
            data = json.loads(output); output = str(data.get("content", data.get("text", data.get("body", ""))))
        except (json.JSONDecodeError, AttributeError): pass
    return ("ok" if output.strip() else "partial"), output, ""
def run_step(step, url):
    mode = str(step["modes"])
    if mode == "command" or mode == "command-json": return command_fetch(step, url)
    if mode == "http": return http_fetch(url)
    if mode == "prefix-http":
        prefix = str(step["url_prefixes"])
        if not prefix: die(2, "channels.yml prefix-http에 url_prefixes가 없다.")
        return http_fetch(prefix + url)
    die(2, "실행할 수 없는 backend mode")
def append(path, row):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try: os.write(fd, (json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))
        finally: os.close(fd)
    except OSError as exc: die(2, "기록 쓰기 실패: " + scrub(exc))
def sid_for(path):
    used = set()
    try:
        if os.path.exists(path):
            for line in open(path, encoding="utf-8"):
                if line.strip(): used.add(json.loads(line).get("sid", ""))
    except (OSError, json.JSONDecodeError) as exc: die(2, "기존 sources.jsonl 계약 위반: " + scrub(exc))
    number = 1
    while True:
        value, letters = number, ""
        while value: value, rem = divmod(value - 1, 26); letters = chr(65 + rem) + letters
        if "R-" + letters not in used: return "R-" + letters
        number += 1
def main():
    channel, url = choose(load_channels(os.path.join(SKILL, "contracts", "channels.yml"))), network_url(RAW_URL)
    if not os.path.isdir(RUN): die(2, "런 디렉터리 없음 — reach-init.sh 먼저 실행하라.")
    try: axes = {line.rstrip("\n").split("\t", 1)[0] for line in open(os.path.join(RUN, "axes.tsv"), encoding="utf-8") if line.strip()}
    except OSError as exc: die(2, "axes.tsv 읽기 실패: " + scrub(exc))
    if AXIS not in axes: die(2, "축 ID가 axes.tsv에 없음: " + AXIS)
    srcdir = os.path.join(RUN, "sources"); os.makedirs(srcdir, exist_ok=True)
    sources, logs = os.path.join(RUN, "sources.jsonl"), os.path.join(RUN, "fetch-log.jsonl"); sid = sid_for(sources)
    attempts, missing, untried, success, last, terminal = 0, 0, [], None, None, False
    def log(step, verdict, note, attempted, skipped="", remaining=()):
        now = stamp(); row = {"sid":sid,"axis":AXIS,"url":scrub(RAW_URL),"channel":channel["name"],"ladder":step["ladder"],"backend":step["backends"],"started_at":now,"finished_at":now,"verdict":verdict,"attempted":attempted,"untried_ladder":list(remaining),"note":scrub(note)}
        if skipped: row["skipped"] = skipped
        append(logs, row)
    for index, step in enumerate(channel["steps"]):
        mode, level = str(step["modes"]), str(step["ladder"]); remaining = [str(x["ladder"]) for x in channel["steps"][index + 1:] if x["modes"] != "manual"]
        if mode == "manual": log(step, "blocked", "원문은 사람이 제공해야 한다.", False, "manual_handoff"); continue
        if terminal:
            untried.append(level); log(step, "blocked", "terminal verdict 뒤 자동 시도 금지", False, "terminal", remaining); continue
        if str(step["when"]) == "challenge" and last not in ("challenge", "blocked"):
            log(step, "blocked", "차단 계열 verdict가 아니어서 적용하지 않음", False, "condition_not_met", remaining); continue
        verdict, body, note = run_step(step, url)
        if verdict is None:
            missing += 1; untried.append(level); log(step, "blocked", note, False, "tool_missing", remaining); continue
        attempts += 1; last = verdict; log(step, verdict, note, True, remaining=remaining)
        if verdict == "ok": success = (step, body); untried.extend(remaining); break
        if verdict in ("auth_required", "not_found"): terminal = True
    if attempts == 0 and missing:
        die(3, "자동 접근 사다리의 모든 도구가 없다 — reach-doctor.sh로 환경을 확인하라.")
    now = stamp(); stopped = success[0] if success else next((step for step in reversed(channel["steps"]) if step["modes"] != "manual" and str(step["ladder"]) not in untried), channel["steps"][-1])
    # R2 정책 초기값이다. 신뢰도 확정은 R3 단일 지점이므로 이 값은 이후 R3에서
    # 사람·에이전트가 근거에 맞춰 상향·하향 조정할 수 있다.
    defaults = {"L0":("primary","high"),"L1":("secondary","med"),"L2":("secondary","med"),"L3":("secondary","med"),"L4":("secondary","med")}
    stopped_ladder = str(stopped["ladder"])
    if stopped_ladder not in defaults: die(2, "channels.yml 사다리 정지 단이 잘못되었다.")
    kind, confidence = defaults[stopped_ladder]
    base = {"sid":sid,"worker_id":"reach-fetch","axis":AXIS,"url":scrub(RAW_URL),"title":urllib.parse.urlsplit(RAW_URL).hostname or RAW_URL,"channel":channel["name"],"ladder":stopped["ladder"],"backend":stopped["backends"],"fetched_at":now,"observed_at":now,"valid_at":now[:10],"attempts":attempts,"ladder_stopped_at":int(str(stopped["ladder"])[1:]),"untried_ladder":untried,"kind":kind,"confidence":confidence}
    if success:
        clean = scrub(success[1]); digest = hashlib.sha256(clean.encode("utf-8")).hexdigest(); rel = "sources/" + sid + ".md"; target = os.path.join(RUN, rel)
        try:
            fd, temp = tempfile.mkstemp(prefix=".fetch-", dir=srcdir)
            try: os.write(fd, clean.encode("utf-8"))
            finally: os.close(fd)
            os.replace(temp, target)
        except OSError as exc: die(2, "스냅샷 쓰기 실패: " + scrub(exc))
        base.update({"status":"ok","snapshot":rel,"sha256":digest,"access_note":""}); append(sources, base); print("[" + sid + "] ok " + str(stopped["ladder"]) + " → " + rel + " (초기 kind/confidence=" + kind + "/" + confidence + "; R3에서 사람·에이전트가 조정·확정)"); return 0
    if untried: die(2, "untried_ladder가 비어 있지 않아 접근 실패를 확정할 수 없다.")
    status = last if last in ("auth_required", "not_found") else "blocked"
    base.update({"status":status,"snapshot":"","sha256":"","access_note":"manual 경로로 인계"}); append(sources, base); print("[" + sid + "] 접근 실패: " + status + " (초기 kind/confidence=" + kind + "/" + confidence + "; R3에서 사람·에이전트가 조정·확정)", file=sys.stderr); return 1
try: raise SystemExit(main())
except BrokenPipeError: raise SystemExit(2)
PY
