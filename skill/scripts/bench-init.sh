#!/usr/bin/env bash
# bench-init.sh — 합격선·축·readonly 범위·R5 계측 전제를 한 번만 봉인한다.
# usage: bench-init.sh <run-dir> <axes-csv> <min-req> <sum-req> <readonly>
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3

[ "$#" -eq 5 ] || usage_die "usage: $0 <run-dir> <axes-csv> <min-req> <sum-req> <readonly>"

PYTHONPATH="$(dirname "$0")${PYTHONPATH:+:$PYTHONPATH}" python3 - "$@" <<'PY'
import datetime as dt
import json
import os
import re
import shlex
import sys
from decimal import Decimal, InvalidOperation

from _pylib import atomic_write, verify_reach_receipt
run_arg, axes_raw, minimum_raw, total_raw, readonly = sys.argv[1:]

REACH_RECEIPT_FIELDS = (
    "ts",
    "reach_conf_sha256",
    "anchors_sha256",
    "usable",
    "primary",
    "confirmed_anchors",
)

def die(message, code=2):
    print("!! " + message, file=sys.stderr)
    raise SystemExit(code)

def receipt_check(run):
    try:
        verify_reach_receipt(run, REACH_RECEIPT_FIELDS)
    except (OSError, TypeError, ValueError) as exc:
        die(str(exc))

def metric_gate(anchor, lineno):
    measure = anchor["measure"].strip()
    if any(c in measure for c in "\t\r\n"):
        die(f"anchors.jsonl:{lineno}: measure에 제어문자를 쓸 수 없습니다.")
    if "|" in measure:
        fields = [part.strip() for part in measure.split("|")]
        if len(fields) == 4:
            instrument, metric, op, number = fields
        elif len(fields) == 5 and fields[0] == anchor["aid"]:
            _, instrument, metric, op, number = fields
        else:
            die(f"anchors.jsonl:{lineno}: R5 measure 형식이 아닙니다.")
    else:
        try:
            fields = shlex.split(measure)
        except ValueError as exc:
            die(f"anchors.jsonl:{lineno}: measure 파싱 실패: {exc}")
        if len(fields) != 4:
            die(f"anchors.jsonl:{lineno}: R5 measure는 계측기 metric op n 형식이어야 합니다.")
        instrument, metric, op, number = fields
    if instrument in {"measure-skill.sh", "measure-repo.sh"}:
        instrument = instrument[:-3]
    if instrument not in {"measure-skill", "measure-repo"}:
        die(f"anchors.jsonl:{lineno}: R5 계측기는 measure-skill 또는 measure-repo여야 합니다.")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", metric) or op not in {">=", "<=", "==", ">", "<"}:
        die(f"anchors.jsonl:{lineno}: R5 metric 또는 연산자가 잘못되었습니다.")
    try:
        parsed = Decimal(number)
    except InvalidOperation:
        die(f"anchors.jsonl:{lineno}: R5 임계값이 숫자가 아닙니다.")
    if not number or not parsed.is_finite() or any(c in number for c in "=|\t\r\n"):
        die(f"anchors.jsonl:{lineno}: R5 임계값 형식이 잘못되었습니다.")
    return "|".join((anchor["aid"], instrument, metric, op, number))

run = os.path.abspath(run_arg)
receipt_check(run)
axes = axes_raw.split(",")
axis_re = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")
if not 3 <= len(axes) <= 7 or any(not axis_re.fullmatch(axis) for axis in axes) or len(set(axes)) != len(axes):
    die("축은 3~7개의 유일한 ^[A-Za-z][A-Za-z0-9_-]*$ ID여야 합니다.")
if not minimum_raw.isascii() or not minimum_raw.isdecimal() or not total_raw.isascii() or not total_raw.isdecimal():
    die("합격선은 0 이상의 ASCII 정수여야 합니다.")
minimum, total = int(minimum_raw), int(total_raw)
if minimum > 4 or total > len(axes) * 4:
    die("합격선이 축별 최대점 또는 총점을 초과합니다.")
if not readonly or any(c in readonly for c in "\t\r\n"):
    die("READONLY는 비어 있거나 제어문자를 포함할 수 없습니다.")
if any(c in run for c in "\t\r\n"):
    die("런 경로에 제어문자를 사용할 수 없습니다.")

parent = os.path.dirname(run)
target = os.path.dirname(parent) if os.path.basename(parent) == ".assay" else parent
gate, seal = os.path.join(run, "gate.conf"), os.path.join(run, "gate.conf.seal")
if os.path.exists(gate):
    die(f"{gate} 이미 존재 — 합격선·축 재선언은 반칙(S0).", 1)
if os.path.exists(seal) or os.path.exists(os.path.join(run, "scores.tsv")) or os.path.exists(os.path.join(run, "rounds.jsonl")):
    die("gate.conf 없는 기존 bench 봉인물이 있어 초기화할 수 없습니다.")

gates, aids = [], set()
anchors_path = os.path.join(run, "anchors.jsonl")
try:
    source = open(anchors_path, encoding="utf-8")
except OSError as exc:
    die(f"anchors.jsonl을 읽을 수 없습니다: {exc}")
for lineno, raw in enumerate(source, 1):
    if not raw.strip():
        die(f"anchors.jsonl:{lineno}: 빈 JSONL 행입니다.")
    try:
        anchor = json.loads(raw)
    except json.JSONDecodeError as exc:
        die(f"anchors.jsonl:{lineno}: JSON 오류: {exc.msg}")
    if not isinstance(anchor, dict):
        die(f"anchors.jsonl:{lineno}: 객체여야 합니다.")
    if anchor.get("measured") is not True:
        continue
    required = ("aid", "excerpt", "measure")
    if (anchor.get("kind") != "metric" or anchor.get("active") is not True or anchor.get("verdict") != "CONFIRMED"
            or any(not isinstance(anchor.get(key), str) or not anchor[key].strip() for key in required)):
        die(f"anchors.jsonl:{lineno}: R5 실측 앵커는 metric·active:true·CONFIRMED·aid/excerpt/measure를 모두 가져야 합니다.")
    if anchor["aid"] in aids:
        die(f"anchors.jsonl:{lineno}: R5 aid가 중복됩니다.")
    aids.add(anchor["aid"])
    gates.append(metric_gate(anchor, lineno))

try:
    os.makedirs(run, exist_ok=True)
    os.makedirs(os.path.join(run, "anchors"), exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    content = [
        f"# 봉인: {stamp} — 이 파일은 루프 종료까지 수정 금지(S0).",
        f"AXES={axes_raw}",
        f"N_AXES={len(axes)}",
        f"MIN_REQ={minimum}",
        f"SUM_REQ={total}",
        "MAX_SCORE=4",
        "STALL_LIMIT=3",
        f"READONLY={readonly}",
        f"TARGET_DIR={target}",
        f"R5_GATES={len(gates)}",
    ]
    content.extend("METRIC_GATE=" + gate_line for gate_line in gates)
    score_header = [
        "round",
        "axis",
        *axes,
        "min",
        "sum",
        "gate",
        "verdict",
        "note",
    ]
    outputs = [
        (gate, "\n".join(content) + "\n"),
        (os.path.join(run, "scores.tsv"), "\t".join(score_header) + "\n"),
        (os.path.join(run, "rounds.jsonl"), ""),
    ]
    for path, text in outputs:
        atomic_write(path, text)
except OSError as exc:
    die(f"bench 봉인물을 쓸 수 없습니다: {exc}")
print(f"초기화 완료: {run}")
print(f"  축 {len(axes)}개: {axes_raw}")
print(f"  합격선: min>={minimum} AND sum>={total} / {len(axes) * 4}  [봉인됨]")
print(f"  READONLY: {readonly}")
print(f"  R5 승격 계측 게이트: {len(gates)}개")
PY

seal_write "$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")/gate.conf"
