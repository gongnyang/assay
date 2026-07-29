#!/usr/bin/env bash
# rubric-lint.sh — 루브릭이 실제 앵커와 계측 근거를 가리키는지 정적 검사한다.
# S3 전에 막아야 점수가 인상비평으로 흘러가지 않기 때문에 존재한다.
#
# usage: rubric-lint.sh <run-dir>
# 종료코드: 0=통과, 1=루브릭 설계 결함, 2=계약·참조 무결성 위반, 64=사용법 오류
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3
[ "$#" -eq 1 ] || usage_die "usage: $0 <run-dir>"
RUN=$1
[ -f "$RUN/gate.conf" ] || die 2 "gate.conf가 없다 — bench-init.sh를 먼저 실행하라."
seal_verify "$RUN/gate.conf"

PYTHONPATH="$(dirname "$0")${PYTHONPATH:+:$PYTHONPATH}" exec python3 - "$RUN" <<'PY'
import json, re, shlex, sys
from pathlib import Path

from _pylib import verify_reach_receipt
run = Path(sys.argv[1])
def stop(code, messages):
    for message in messages:
        print(f"!! {message}", file=sys.stderr)
    sys.exit(code)
# S2는 현재 anchors.jsonl·reach.conf가 축1 통과 당시의 것인지 먼저 확인한다.
def reach_receipt(run):
    required_fields = (
        "anchors_sha256",
        "reach_conf_sha256",
    )
    try:
        return verify_reach_receipt(run, required_fields)
    except (OSError, TypeError, ValueError) as exc:
        stop(2, [str(exc)])
reach_receipt(run)

def conf(path):
    values = {}
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
    except OSError as exc:
        stop(2, [f"gate.conf 읽기 실패: {exc}"])
    return values
gate_path = run / "gate.conf"
rubric_path = run / "rubric.md"
anchor_path = run / "anchors.jsonl"
if not gate_path.is_file() or not rubric_path.is_file() or not anchor_path.is_file():
    stop(2, ["gate.conf·rubric.md·anchors.jsonl은 모두 있어야 한다."])

gate = conf(gate_path)
axes = [item.strip() for item in gate.get("AXES", "").split(",") if item.strip()]
try:
    declared_n = int(gate.get("N_AXES", ""))
except ValueError:
    declared_n = -1
if (len(axes) < 3 or len(axes) > 7 or len(set(axes)) != len(axes) or declared_n != len(axes)
        or any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", axis) for axis in axes)):
    stop(2, ["gate.conf의 AXES/N_AXES 계약이 3~7개 유일 축과 일치하지 않는다."])
try:
    text = rubric_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as exc:
    stop(2, [f"rubric.md 읽기 실패: {exc}"])
lines = text.splitlines()
anchors = {}
integrity = []
try:
    for number, raw in enumerate(anchor_path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip():
            continue
        item = json.loads(raw)
        aid = item.get("aid")
        if not isinstance(aid, str) or not aid:
            integrity.append(f"anchors.jsonl {number}행 aid 누락")
        elif aid in anchors:
            integrity.append(f"anchors.jsonl aid 중복: {aid}")
        else:
            anchors[aid] = item
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    stop(2, [f"anchors.jsonl 파싱 실패: {exc}"])
heading = re.compile(r"^\s{0,3}#{1,6}[ \t]+(?:축[ \t]+)?([A-Za-z][A-Za-z0-9_-]*)(?=[ \t]|[.:—–-]|$)")
heads = []
for index, line in enumerate(lines):
    match = heading.match(line)
    if not match:
        continue
    candidate = match.group(1)
    if candidate in axes:
        heads.append((candidate, index))
    elif re.search(r"[0-9_-]", candidate):
        heads.append((candidate, index))

sections = {}
design = []
for pos, (axis, start) in enumerate(heads):
    end = heads[pos + 1][1] if pos + 1 < len(heads) else len(lines)
    if axis in sections:
        design.append(f"루브릭 축 헤더 중복: {axis}")
    else:
        sections[axis] = "\n".join(lines[start + 1:end])
if set(sections) != set(axes):
    missing = sorted(set(axes) - set(sections))
    extra = sorted(set(sections) - set(axes))
    if missing:
        integrity.append("gate.conf에 있으나 rubric.md에 없는 축: " + ", ".join(missing))
    if extra:
        integrity.append("rubric.md의 봉인 외 축: " + ", ".join(extra))

aid_re = re.compile(r"\b(R-[A-Z]+#[0-9]+)\b")
level_re = re.compile(r"^\s*([034])\s*(?:점)?\s*[—–\-:.]\s*(.+)$")
auto_re = re.compile(r"^\s*(?:자동\s*검증|자동검증|measure)\s*:\s*(.*?)\s*$", re.M | re.I)
measure_re = re.compile(r"^\s*measure\s*:\s*(.*?)\s*$", re.M | re.I)
qualitative = {"정성", "없음", "none", "n/a", "na", "해당 없음", "-"}
axis_aids = {}

def measure_output(command):
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    for token in tokens:
        name = Path(token).name
        stem = name[:-3] if name.endswith(".sh") else name
        if re.fullmatch(r"measure-[A-Za-z][A-Za-z0-9_-]*", stem):
            return stem
    return None

for axis in axes:
    body = sections.get(axis)
    if body is None:
        continue
    level_aids = {}
    for line in body.splitlines():
        match = level_re.match(line)
        if match:
            level_aids[match.group(1)] = aid_re.findall(match.group(2))
    for level in ("0", "3", "4"):
        if not level_aids.get(level):
            integrity.append(f"{axis}의 {level}점 레벨에 aid 앵커가 없다")
    referenced = set(aid_re.findall(body))
    axis_aids[axis] = referenced
    for aid in sorted(referenced):
        item = anchors.get(aid)
        if item is None:
            integrity.append(f"{axis}가 존재하지 않는 aid를 참조: {aid}")
        elif item.get("active") is not True or item.get("verdict") != "CONFIRMED":
            integrity.append(f"{axis}의 aid가 active:true·CONFIRMED가 아님: {aid}")
    zero = level_aids.get("0", [])
    four = level_aids.get("4", [])
    if zero and four:
        zero_sids = {anchors.get(aid, {}).get("sid") for aid in zero} - {None, ""}
        four_sids = {anchors.get(aid, {}).get("sid") for aid in four} - {None, ""}
        shared = sorted(zero_sids & four_sids)
        if shared:
            design.append(f"{axis}의 0점과 4점 앵커가 같은 sid다: {', '.join(shared)}")
    auto_values = [value.strip() for value in auto_re.findall(body)]
    measures = [value.strip() for value in measure_re.findall(body)]
    automatic = any(value.casefold() not in qualitative for value in auto_values)
    if automatic:
        outputs = [measure_output(command) for command in measures]
        if not measures or any(not output for output in outputs):
            design.append(f"{axis} 자동검증은 measure: 명령명을 가져야 한다")
        elif any(not (run / "metrics" / (output + ".tsv")).is_file()
                 or not (run / "metrics" / (output + ".tsv")).stat().st_size for output in outputs):
            design.append(f"{axis} measure: 명령명과 metrics/<명령명>.tsv 출력이 대응하지 않는다")

for index, left in enumerate(axes):
    for right in axes[index + 1:]:
        if axis_aids.get(left) and axis_aids.get(left) == axis_aids.get(right):
            integrity.append(f"두 축의 aid 집합이 완전히 같다: {left}, {right}")

def cells(row):
    return [cell.strip() for cell in row.strip().strip("|").split("|")]

reverse_tables = 0
for index, line in enumerate(lines):
    if "|" not in line:
        continue
    header = cells(line)
    places = {axis: header.index(axis) for axis in axes if axis in header}
    if len(places) != len(axes):
        continue
    reverse_tables += 1
    values = {axis: [] for axis in axes}
    for row in lines[index + 1:]:
        if "|" not in row:
            break
        row_cells = cells(row)
        if row_cells and re.fullmatch(r":?-{3,}:?", row_cells[0] or "-"):
            continue
        for axis, place in places.items():
            if place < len(row_cells) and re.fullmatch(r"[0-4]", row_cells[place]):
                values[axis].append(int(row_cells[place]))
    for axis, scores in values.items():
        if len(scores) >= 2 and len(set(scores)) == 1:
            design.append(f"{axis}는 전 레퍼런스가 {scores[0]}점으로 동일하다 — 전제 후보다")

if not reverse_tables:
    integrity.append("rubric.md에 레퍼런스 역방향 채점 표가 없다")

if integrity:
    stop(2, integrity)
if design:
    stop(1, design)
print(f"루브릭 검사 통과: 축 {len(axes)}개, CONFIRMED aid 참조와 계측 근거를 확인했다.")
PY
