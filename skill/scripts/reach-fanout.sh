#!/usr/bin/env bash
# reach-fanout.sh — 봉인된 질문을 서로 다른 하위 질문 축과 워커 브리프로 나눈다.
# 축마다 수집 워커를 하나로 고정해야 근거의 담당 경계와 누락을 추적할 수 있다.
#
# usage: reach-fanout.sh <run-dir> <axes.tsv>
#   axes.tsv: axis_id<TAB>question<TAB>target_sources (첫 행 헤더는 선택)
# 종료코드: 0=브리프 생성, 1=3-gram 중복률 초과, 2=축 계약 위반, 64=사용법 오류
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3

[ $# -eq 2 ] || {
  usage_die "usage: $0 <run-dir> <axes.tsv>"
}

seal_verify "$1/reach.conf"

python3 - "$1" "$2" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unicodedata

run_arg, axes_arg = sys.argv[1:]

def fail(message, code=2):
    print(f"!! {message}", file=sys.stderr)
    raise SystemExit(code)

def read_conf(path):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"reach.conf를 읽을 수 없다: {path} ({exc})")
    for line in lines:
        if not line or line.lstrip().startswith("#"):
            continue
        if "=" not in line:
            fail(f"reach.conf 형식 오류: {line!r}")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in values:
            fail(f"reach.conf 키 오류: {key!r}")
        values[key] = value
    required = {"QUESTION_SHA256", "MIN_SOURCES", "MIN_PRIMARY", "POC_MAX_PCT", "MANUAL_MAX_PCT", "AXES_MIN", "AXES_MAX"}
    if required - values.keys():
        fail("reach.conf에 R0 봉인 필드가 빠져 있다")
    if not re.fullmatch(r"[0-9a-f]{64}", values["QUESTION_SHA256"]):
        fail("reach.conf의 QUESTION_SHA256 형식이 잘못되었다")
    try:
        axes_min, axes_max = int(values["AXES_MIN"]), int(values["AXES_MAX"])
    except ValueError:
        fail("reach.conf의 AXES_MIN/MAX가 정수가 아니다")
    if axes_min < 1 or axes_max < axes_min:
        fail("reach.conf의 AXES_MIN/MAX 범위가 잘못되었다")
    return values, axes_min, axes_max

def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.replace(temporary, path)
    except OSError as exc:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        fail(f"브리프 파일을 쓸 수 없다: {path} ({exc})")

if not run_arg:
    fail("run-dir가 비어 있다")
run = Path(run_arg)
conf, axes_min, axes_max = read_conf(run / "reach.conf")
question_path = run / "question.md"
try:
    question_bytes = question_path.read_bytes()
    question_text = question_bytes.decode("utf-8")
except (OSError, UnicodeDecodeError) as exc:
    fail(f"봉인된 질문 파일을 읽을 수 없다: {question_path} ({exc})")
if hashlib.sha256(question_bytes).hexdigest() != conf["QUESTION_SHA256"]:
    fail("question.md 해시가 R0 봉인값과 다르다 — 질문 변경은 허용하지 않는다")

source = Path(axes_arg)
try:
    raw_axes = source.read_text(encoding="utf-8")
except (OSError, UnicodeDecodeError) as exc:
    fail(f"axes.tsv를 UTF-8로 읽을 수 없다: {source} ({exc})")

rows = []
for number, raw_line in enumerate(raw_axes.lstrip("\ufeff").splitlines(), start=1):
    if not raw_line.strip() or raw_line.lstrip().startswith("#"):
        continue
    fields = [field.strip() for field in raw_line.split("\t")]
    if not rows and [field.casefold() for field in fields] in (["axis_id", "question", "target_sources"], ["axis", "question", "target_sources"]):
        continue
    if len(fields) != 3:
        fail(f"axes.tsv {number}행은 axis_id, question, target_sources 세 열이어야 한다")
    axis_id, question, target = fields
    canonical_id = unicodedata.normalize("NFC", axis_id)
    if (not canonical_id.startswith("AX-") or len(canonical_id) == 3 or
            any(char in canonical_id for char in "/\\\x00")):
        fail(f"axes.tsv {number}행의 축 ID는 경로 문자가 없는 AX-* 형식이어야 한다")
    if not question:
        fail(f"axes.tsv {number}행의 하위 질문이 비어 있다")
    if not re.fullmatch(r"[1-9][0-9]*", target):
        fail(f"axes.tsv {number}행의 목표 소스 수가 양의 정수가 아니다")
    rows.append((number, canonical_id, question, str(int(target))))

if not axes_min <= len(rows) <= axes_max:
    fail(f"축 수 범위 이탈: {len(rows)}개 (허용 {axes_min}~{axes_max})")
seen = set()
for number, axis_id, _, _ in rows:
    if axis_id in seen:
        fail(f"축 ID 중복: {axis_id} (axes.tsv {number}행)")
    seen.add(axis_id)

def trigrams(sentence):
    compact = "".join(unicodedata.normalize("NFKC", sentence).casefold().split())
    return {compact[index:index + 3] for index in range(max(0, len(compact) - 2))}

overlaps = []
for index, (_, left_id, left_question, _) in enumerate(rows):
    left = trigrams(left_question)
    for _, right_id, right_question, _ in rows[index + 1:]:
        right = trigrams(right_question)
        rate = len(left & right) / len(left | right) if left or right else 0.0
        if rate >= 0.6:
            overlaps.append((left_id, right_id, rate))
if overlaps:
    detail = ", ".join(f"{left}/{right}={rate:.3f}" for left, right, rate in overlaps)
    fail(f"축 문장 3-gram 중복률이 0.6 이상이다: {detail}", code=1)

canonical_axes = "".join(
    f"{axis_id}\t{question}\t{target}\n" for _, axis_id, question, target in rows
)
destination = run / "axes.tsv"
try:
    destination_bytes = destination.read_bytes() if destination.exists() else None
    source_is_destination = source.resolve() == destination.resolve()
except OSError as exc:
    fail(f"기존 axes.tsv를 확인할 수 없다: {destination} ({exc})")
if destination_bytes is not None and not source_is_destination and destination_bytes != canonical_axes.encode("utf-8"):
    fail("axes.tsv가 이미 다른 축으로 봉인되어 있다 — 축 재선언은 허용하지 않는다")
if destination_bytes is not None and source_is_destination and (run / "briefs").exists() and destination_bytes != canonical_axes.encode("utf-8"):
    fail("봉인 뒤 axes.tsv를 바꿀 수 없다 — 새 런을 시작하라")

schema = {
    "sid": "R-<대문자 ID>", "worker_id": "<담당 수집 워커 ID>", "axis": "<담당 축 ID>", "url": "<원 URL>", "title": "<제목>",
    "channel": "<channels.yml 채널>", "ladder": "L0~L4", "backend": "<실제 백엔드>",
    "fetched_at": "<UTC ISO-8601>", "observed_at": "<UTC ISO-8601>", "valid_at": "<내용 기준 시점>",
    "status": "ok|manual|blocked|auth_required|not_found|timeout", "attempts": 1,
    "ladder_stopped_at": 0, "untried_ladder": [], "kind": "",
    "confidence": "", "snapshot": "sources/R-<ID>.md", "sha256": "<sha256>", "access_note": ""
}
return_path = str(run / "sources.jsonl")
for _, axis_id, question, target in rows:
    brief = "\n".join((
        f"# 수집 워커 브리프 — {axis_id} 축의 원문 스냅샷만 수집한다.",
        "# 워커가 판정까지 맡으면 수집과 신뢰도 태깅의 경계가 사라지므로 반환 형식을 고정한다.",
        "",
        f"담당 축 ID: {axis_id}",
        f"하위 질문: {question}",
        f"목표 소스 수: {target}",
        "동시성: 기본 5, 상한 15. 하위 질문 1개에는 이 워커 1개만 배정한다.",
        "",
        "## 구동 질문과 소비처",
        question_text.rstrip(),
        "",
        "## 반환 형식 (고정)",
        f"1. 담당 축 ID: {axis_id}",
        f"2. 반환 파일 경로: {return_path} (한 줄에 JSON 객체 하나씩 append)",
        "3. 반환 스키마: sources.jsonl §5.1 그대로",
        "```json",
        json.dumps(schema, ensure_ascii=False, separators=(",", ":")),
        "```",
        "",
        "원문 본문은 sources/<sid>.md에 저장하고 sha256을 기록한다. 앵커·루브릭·최종 판정은 만들지 않는다.",
        "신뢰도 태깅은 R3의 단일 지점에서 확정한다. 수집 워커는 접근 사실과 스냅샷만 남긴다.",
        "",
    ))
    atomic_write(run / "briefs" / f"{axis_id}.md", brief)
atomic_write(destination, canonical_axes)
PY

echo "R1 팬아웃 완료: $1"
echo "  축별 워커 브리프: $1/briefs/AX-*.md"
echo "  다음: 각 워커는 자기 축의 소스만 수집해 $1/sources.jsonl에 append한다."
