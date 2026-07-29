#!/usr/bin/env bash
# measure-skill.sh — 스킬 디렉터리의 구조 수치를 재현 가능하게 계측하고 봉인 임계값을 판정한다.
# gate.conf를 셸 코드로 실행하지 않는 것이 이 스크립트의 존재 이유다 — 계측 게이트는 데이터여야 한다.
#
# usage: measure-skill.sh <skill-dir> <run-dir>
# gate.conf: METRIC_GATE=<aid>|<instrument>|<metric>|<op>|<number>
# 종료코드: 0=계측·임계 통과, 1=봉인 임계 미달, 2=계약 위반, 3=환경 미비, 64=사용법 오류
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3

[ $# -eq 2 ] || { echo "usage: $0 <skill-dir> <run-dir>" >&2; exit 64; }
TARGET=$1
RUN=$2
[ -d "$TARGET" ] && [ -f "$TARGET/SKILL.md" ] || {
  echo "스킬 디렉터리 또는 SKILL.md 없음: $TARGET" >&2; exit 2;
}

PYTHONPATH="$(cd -- "$(dirname -- "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" exec python3 - "$RUN" "$TARGET" <<'PY'
import csv
import hashlib
import json
import os
import re
import sys
from _pylib import atomic_write
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

run = Path(sys.argv[1])
target = Path(sys.argv[2])
gate = run / "gate.conf"
metric_names = {
    "core_lines", "core_fences", "cmdish", "scripts", "md_files",
    "md_lines", "md_fences", "checks",
}

def die(message, code=2):
    print(message, file=sys.stderr)
    raise SystemExit(code)

def text(path):
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        die(f"읽기 실패: {path}: {exc}")

def files_under(root):
    result = []
    for base, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = [d for d in dirs if d not in {".assay", ".bench", ".git"}]
        for name in names:
            path = Path(base) / name
            if path.is_file():
                result.append(path)
    return result

core = text(target / "SKILL.md")
all_files = files_under(target)
md_files = [p for p in all_files if p.suffix.lower() == ".md"]
script_suffixes = {".py", ".mjs", ".js", ".sh"}
values = {
    "core_lines": core.count("\n"),
    "core_fences": len(re.findall(r"^```", core, re.M)) // 2,
    "cmdish": len(re.findall(
        r"(?:^|[`>\s])(git|npm|npx|uv|python3?|node|bash|sh|grep|awk|sed|curl|mkdir|cp|mv|rm|wc|find)(?=[\s/])",
        core, re.M)),
    "scripts": sum(p.suffix.lower() in script_suffixes for p in all_files),
    "md_files": len(md_files),
    "md_lines": sum(text(p).count("\n") for p in md_files),
    "md_fences": sum(len(re.findall(r"^```", text(p), re.M)) for p in md_files) // 2,
    "checks": len(re.findall(r"^- \[ \]", core, re.M)),
}

def parse_gate():
    gates = []
    if not gate.exists():
        return gates
    if not gate.is_file():
        die(f"gate.conf가 일반 파일이 아닙니다: {gate}", 2)
    for lineno, raw in enumerate(text(gate).splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if key != "METRIC_GATE":
            continue
        fields = [p.strip() for p in value.split("|")]
        if len(fields) != 5 or any(not p for p in fields):
            die(f"gate.conf:{lineno}: METRIC_GATE 형식 오류", 2)
        _, instrument, metric, op, expected = fields
        if instrument != "measure-skill":
            continue
        if metric not in metric_names or op not in {">=", "<=", "==", ">", "<"}:
            die(f"gate.conf:{lineno}: 알 수 없는 스킬 계측 임계값", 2)
        try:
            number = Decimal(expected)
        except InvalidOperation:
            die(f"gate.conf:{lineno}: 수치 임계값이 아님", 2)
        if not number.is_finite():
            die(f"gate.conf:{lineno}: 수치 임계값이 유한하지 않음", 2)
        gates.append((metric, op, number))
    return gates

def latest_round():
    path = run / "rounds.jsonl"
    if not path.exists():
        return "UNRECORDED"
    latest = "UNRECORDED"
    for lineno, raw in enumerate(text(path).splitlines(), 1):
        if not raw.strip():
            continue
        try:
            record = json.loads(raw)
        except json.JSONDecodeError as exc:
            die(f"rounds.jsonl:{lineno}: JSON 오류: {exc.msg}", 2)
        if isinstance(record, dict) and isinstance(record.get("round"), str) and record["round"]:
            latest = record["round"]
    return latest

gates = parse_gate()
ordered = ["core_lines", "core_fences", "cmdish", "scripts", "md_files", "md_lines", "md_fences", "checks"]
round_id = latest_round()
out_dir = run / "metrics"
try:
    out_dir.mkdir(parents=True, exist_ok=True)
except OSError as exc:
    die(f"metrics 기록 실패: {exc}")
tsv_path = out_dir / "measure-skill.tsv"
header = ["round", "target", *ordered]
old_rows = []
if tsv_path.exists():
    try:
        with tsv_path.open(encoding="utf-8", newline="") as source:
            old_rows = list(csv.reader(source, delimiter="\t"))
    except OSError as exc:
        die(f"metrics 읽기 실패: {exc}")
    if not old_rows or old_rows[0] != header or any(len(row) != len(header) for row in old_rows[1:]):
        die("measure-skill.tsv 형식이 계약과 일치하지 않습니다.")
    old_rows = old_rows[1:]
new_row = [round_id, str(target), *(str(values[k]) for k in ordered)]
rows = [row for row in old_rows if row[:2] != new_row[:2]] + [new_row]
body = "\n".join("\t".join(row) for row in [header, *rows]) + "\n"
payload = body.encode("utf-8")
try:
    atomic_write(tsv_path, payload, binary=True)
except OSError as exc:
    die(f"metrics 기록 실패: {exc}")
provenance = {
    "instrument": "measure-skill.sh", "argv": sys.argv[1:],
    "ts": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "tsv_sha256": hashlib.sha256(payload).hexdigest(), "rows": len(rows),
}
try:
    atomic_write(out_dir / "measure-skill.tsv.prov",
                 (json.dumps(provenance, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"), binary=True)
except OSError as exc:
    die(f"metrics 기록 실패: {exc}")

failed = []
for metric, op, expected in gates:
    actual = Decimal(values[metric])
    ok = {">=": actual >= expected, "<=": actual <= expected,
          "==": actual == expected, ">": actual > expected, "<": actual < expected}[op]
    if not ok:
        failed.append(f"{metric}={actual} {op} {expected}")

if failed:
    print("봉인 임계 미달: " + ", ".join(failed), file=sys.stderr)
    raise SystemExit(1)
PY
