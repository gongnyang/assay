#!/usr/bin/env bash
# reach-init.sh — 조사 런의 질문과 수집 하한을 한 번만 봉인한다.
# 질문을 먼저 고정해야 이후 수집물이 질문에 맞춰 재해석되는 일을 막을 수 있다.
#
# usage: reach-init.sh <run-dir> <question-file> <min-sources> <poc-max-pct>
#   질문 파일: `질문: 한 문장으로 끝나는 질문?` 와 `소비처: 이 조사의 결정`을 포함한다.
# 종료코드: 0=봉인 완료, 1=reach.conf 재선언, 2=입력 계약 위반, 64=사용법 오류
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3

[ $# -eq 4 ] || {
  usage_die "usage: $0 <run-dir> <question-file> <min-sources> <poc-max-pct>"
}

PYTHONPATH="$(dirname "$0")${PYTHONPATH:+:$PYTHONPATH}" python3 - "$1" "$2" "$3" "$4" <<'PY'
import datetime as dt
import _pylib, hashlib
from decimal import Decimal, InvalidOperation
from pathlib import Path
import re
import sys
import unicodedata

run_arg, question_arg, min_raw, poc_raw = sys.argv[1:]

def fail(message, code=2):
    print(f"!! {message}", file=sys.stderr)
    raise SystemExit(code)

if not run_arg:
    fail("run-dir가 비어 있다")
run = Path(run_arg)
if run.exists() and not run.is_dir():
    fail(f"런 디렉터리가 아니다: {run}")
conf_path = run / "reach.conf"
if conf_path.exists():
    print(f"!! {conf_path} 이미 존재 — 질문·수집 하한 재선언은 거부한다(R0).", file=sys.stderr)
    raise SystemExit(1)

try:
    raw_question = Path(question_arg).read_bytes()
    question_text = raw_question.decode("utf-8")
except (OSError, UnicodeDecodeError) as exc:
    fail(f"질문 파일을 UTF-8로 읽을 수 없다: {question_arg} ({exc})")

consumer_values, question_lines = [], []
for original in question_text.lstrip("\ufeff").splitlines():
    line = original.strip()
    if not line:
        continue
    consumer = re.fullmatch(r"(?:소비처|consumer)\s*:\s*(.*)", line, flags=re.IGNORECASE)
    if consumer:
        consumer_values.append(consumer.group(1).strip())
        continue
    question = re.fullmatch(r"(?:질문|question)\s*:\s*(.*)", line, flags=re.IGNORECASE)
    question_lines.append((question.group(1) if question else line).strip())

if len(consumer_values) != 1 or not consumer_values[0]:
    fail("질문 파일에는 비어 있지 않은 소비처: 필드가 정확히 하나 필요하다")
if len(question_lines) != 1 or not question_lines[0]:
    fail("질문 파일에는 소비처를 제외한 구동 질문 한 문장만 있어야 한다")
normalized_question = unicodedata.normalize("NFKC", question_lines[0]).rstrip()
if not normalized_question.endswith("?") or normalized_question[:-1].count("?") != 0:
    fail("구동 질문은 물음표로 끝나는 단일 문장이어야 한다")

if not re.fullmatch(r"[1-9][0-9]*", min_raw):
    fail("min-sources는 1 이상의 정수여야 한다")
if not re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.[0-9]+)?", poc_raw):
    fail("poc-max-pct는 0 이상 100 이하의 숫자여야 한다")
try:
    poc_pct = Decimal(poc_raw)
except InvalidOperation:
    fail("poc-max-pct를 숫자로 해석할 수 없다")
if not Decimal("0") <= poc_pct <= Decimal("100"):
    fail("poc-max-pct는 0 이상 100 이하여야 한다")
poc_text = format(poc_pct.normalize(), "f") if poc_pct else "0"

created_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
question_sha = hashlib.sha256(raw_question).hexdigest()
conf = "\n".join((
    f"# R0 봉인: {created_at} — 이 값들은 R1 이후 수정하지 않는다.",
    f"QUESTION_SHA256={question_sha}",
    f"MIN_SOURCES={min_raw}",
    "MIN_PRIMARY=2",
    f"POC_MAX_PCT={poc_text}",
    "MANUAL_MAX_PCT=33",
    "AXES_MIN=3",
    "AXES_MAX=7",
    "",
))
try:
    _pylib.atomic_write(run / "question.md", raw_question, binary=True)
except Exception as exc:
    fail(f"봉인 파일을 쓸 수 없다: {run / 'question.md'} ({exc})")
try:
    _pylib.atomic_write(conf_path, conf)
except Exception as exc:
    fail(f"봉인 파일을 쓸 수 없다: {conf_path} ({exc})")
PY

seal_write "$1/reach.conf"

echo "R0 봉인 완료: $1"
echo "  질문 해시와 수집 하한을 $1/reach.conf에 기록했다."
echo "다음: reach-fanout.sh $1 <axes.tsv>"
