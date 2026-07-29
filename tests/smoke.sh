#!/usr/bin/env bash
# CI smoke test: run the local contract; SMOKE_LIVE=1 enables external cases.
set -uo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SKILL_DIR="$REPO_ROOT/skill"
SCRIPTS="$SKILL_DIR/scripts"
REACH_INIT="$SCRIPTS/reach-init.sh"
REACH_FANOUT="$SCRIPTS/reach-fanout.sh"
REACH_FETCH="$SCRIPTS/reach-fetch.sh"
REACH_GATE="$SCRIPTS/reach-gate.sh"
BENCH_INIT="$SCRIPTS/bench-init.sh"
RUBRIC_LINT="$SCRIPTS/rubric-lint.sh"
BENCH_LOG="$SCRIPTS/bench-log.sh"
G2_SPAWN="$SCRIPTS/g2-spawn.sh"
VERDICT_GATE="$SCRIPTS/verdict-gate.sh"
INSTALL_GATE="$SCRIPTS/install-gate.sh"
BASH_BIN=$(command -v bash)
DIRNAME_BIN=$(command -v dirname)
SMOKE_LIVE=${SMOKE_LIVE:-0}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/assay-smoke.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/output"

passed=0
failed=0
skipped=0
case_no=0

run_case() {
  local name=$1 expected=$2 actual out err
  shift 2
  case_no=$((case_no + 1))
  out="$TMP/output/$case_no.out"
  err="$TMP/output/$case_no.err"
  set +e
  ( set -e; "$@" ) >"$out" 2>"$err"
  actual=$?
  set -e
  if [ "$actual" -eq "$expected" ]; then
    printf '[PASS] %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"
    passed=$((passed + 1))
  else
    printf '[FAIL] %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"
    [ ! -s "$out" ] || sed -n '1,40p' "$out"
    [ ! -s "$err" ] || sed -n '1,40p' "$err" >&2
    failed=$((failed + 1))
  fi
  return 0
}

skip_case() {
  local name=$1 reason=$2
  printf '[SKIP] %s: %s\n' "$name" "$reason"
  skipped=$((skipped + 1))
}

prepare_reach() {
  local base=$1 run_name=$2 question axes
  REACH_RUN="$base/대상 프로젝트/.assay/$run_name"
  question="$base/질문 파일.txt"
  axes="$base/축 입력.tsv"
  mkdir -p "$(dirname "$REACH_RUN")"
  printf '%s\n' '질문: 이 로컬 smoke 검증은 유효한가?' '소비처: CI 계약 검증' >"$question"
  printf '%s\n' \
    $'axis_id\tquestion\ttarget_sources' \
    $'AX-1\t알파 근거는 무엇인가?\t1' \
    $'AX-2\t베타 경계는 무엇인가?\t1' \
    $'AX-3\t감마 판정은 무엇인가?\t1' >"$axes"
  "$REACH_INIT" "$REACH_RUN" "$question" 3 30
  "$REACH_FANOUT" "$REACH_RUN" "$axes"
  write_reach_evidence "$REACH_RUN"
}

write_reach_evidence() {
  python3 - "$1" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

run = Path(sys.argv[1])
source_specs = [
    ("R-A", "AX-1", "worker-a", "primary", ["알파 영점 근거", "베타 사점 근거", "감마 삼점 근거"]),
    ("R-B", "AX-2", "worker-b", "primary", ["알파 삼점 근거", "베타 영점 근거", "감마 사점 근거"]),
    ("R-C", "AX-3", "worker-c", "secondary", ["알파 사점 근거", "베타 삼점 근거", "감마 영점 근거"]),
]
timestamp = "2026-07-30T00:00:00Z"
(run / "sources").mkdir(parents=True, exist_ok=True)
sources = []
for sid, axis, worker, kind, lines in source_specs:
    snapshot = run / "sources" / f"{sid}.md"
    snapshot.write_text("\n".join(lines) + "\n", encoding="utf-8")
    sources.append({
        "sid": sid, "worker_id": worker, "axis": axis,
        "url": f"https://github.com/example/{sid}", "title": f"{sid} local source",
        "channel": "github", "ladder": "L0", "backend": "gh-api",
        "fetched_at": timestamp, "observed_at": timestamp, "valid_at": "2026-07-30",
        "status": "ok", "attempts": 1, "ladder_stopped_at": 0, "untried_ladder": [],
        "kind": kind, "confidence": "high", "snapshot": f"sources/{sid}.md",
        "sha256": hashlib.sha256(snapshot.read_bytes()).hexdigest(), "access_note": "",
    })
(run / "sources.jsonl").write_text(
    "".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in sources),
    encoding="utf-8",
)
anchor_specs = [
    ("R-A#01", "R-A", "A1", "알파 영점 근거", 1),
    ("R-A#02", "R-A", "A2", "베타 사점 근거", 2),
    ("R-A#03", "R-A", "A3", "감마 삼점 근거", 3),
    ("R-B#01", "R-B", "A1", "알파 삼점 근거", 1),
    ("R-B#02", "R-B", "A2", "베타 영점 근거", 2),
    ("R-B#03", "R-B", "A3", "감마 사점 근거", 3),
    ("R-C#01", "R-C", "A1", "알파 사점 근거", 1),
    ("R-C#02", "R-C", "A2", "베타 삼점 근거", 2),
    ("R-C#03", "R-C", "A3", "감마 영점 근거", 3),
]
anchors = []
for aid, sid, axis, excerpt, line in anchor_specs:
    anchors.append({
        "aid": aid, "sid": sid, "kind": "quote", "axis_hint": axis,
        "active": True, "excerpt": excerpt, "locator": f"{sid}.md:{line}",
        "measured": False, "measure": "", "claim_type": "verified", "confidence": "high",
        "verdict": "CONFIRMED", "refuted_by": "", "captured_at": timestamp,
    })
(run / "anchors.jsonl").write_text(
    "".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in anchors),
    encoding="utf-8",
)
PY
}

write_rubric() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path

run = Path(sys.argv[1])
(run / "rubric.md").write_text("""# Smoke rubric

### A1. 알파
자동검증: 정성
0: 낮음 [aid: R-A#01]
3: 충족 [aid: R-B#01]
4: 높음 [aid: R-C#01]

### A2. 베타
자동검증: 정성
0: 낮음 [aid: R-B#02]
3: 충족 [aid: R-C#02]
4: 높음 [aid: R-A#02]

### A3. 감마
자동검증: 정성
0: 낮음 [aid: R-C#03]
3: 충족 [aid: R-A#03]
4: 높음 [aid: R-B#03]

## 역방향 검사 기록

| reference sid | A1 | A2 | A3 |
| --- | --- | --- | --- |
| R-A | 0 | 4 | 3 |
| R-B | 3 | 0 | 4 |
| R-C | 4 | 3 | 0 |
""", encoding="utf-8")
PY
}

write_round_anchor() {
  local run=$1 round=$2
  mkdir -p "$run/anchors"
  printf '%s\n' 'A1: R-A#01' 'A2: R-B#02' 'A3: R-C#03' >"$run/anchors/$round.md"
}

prepare_bench() {
  local run=$1
  "$BENCH_INIT" "$run" A1,A2,A3 3 9 NONE
  write_rubric "$run"
}

complete_happy_path() {
  local base=$1 run_name=$2
  prepare_reach "$base" "$run_name"
  "$REACH_GATE" "$REACH_RUN"
  prepare_bench "$REACH_RUN"
  "$RUBRIC_LINT" "$REACH_RUN"
  write_round_anchor "$REACH_RUN" R0
  "$BENCH_LOG" "$REACH_RUN" R0 - 3,3,3 baseline
}

case_reach_reseal() {
  local base="$TMP/reach-reseal" question run
  run="$base/target/.assay/run"
  question="$base/question.txt"
  mkdir -p "$(dirname "$run")"
  printf '%s\n' '질문: 봉인을 다시 실행해도 되는가?' '소비처: CI' >"$question"
  "$REACH_INIT" "$run" "$question" 3 30
  "$REACH_INIT" "$run" "$question" 3 30
}

case_gate_reseal() {
  prepare_reach "$TMP/gate-reseal" run
  "$REACH_GATE" "$REACH_RUN"
  "$BENCH_INIT" "$REACH_RUN" A1,A2,A3 3 9 NONE
  "$BENCH_INIT" "$REACH_RUN" A1,A2,A3 3 9 NONE
}

case_gate_conf_tamper() {
  prepare_reach "$TMP/gate-conf-tamper" run
  "$REACH_GATE" "$REACH_RUN"
  prepare_bench "$REACH_RUN"
  write_round_anchor "$REACH_RUN" R0
  printf '%s\n' '# smoke tamper' >>"$REACH_RUN/gate.conf"
  "$BENCH_LOG" "$REACH_RUN" R0 - 3,3,3 tamper
}

case_chain_tamper() {
  complete_happy_path "$TMP/chain-tamper" run
  python3 - "$REACH_RUN/rounds.jsonl" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
changed = text.replace('"sum":9', '"sum":8', 1)
if changed == text:
    raise SystemExit("round score mutation fixture failed")
path.write_text(changed, encoding="utf-8")
PY
  write_round_anchor "$REACH_RUN" R1
  "$BENCH_LOG" "$REACH_RUN" R1 A1 3,3,3 chain-tamper
}

case_scores_tamper() {
  complete_happy_path "$TMP/scores-tamper" run
  python3 - "$REACH_RUN/scores.tsv" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
fields = lines[1].split("\t")
fields[2] = "2"
lines[1] = "\t".join(fields)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  write_round_anchor "$REACH_RUN" R1
  "$BENCH_LOG" "$REACH_RUN" R1 A1 3,3,3 scores-tamper
}

case_anchor_forgery() {
  local kind=$1 base="$TMP/anchor-$1"
  prepare_reach "$base" run
  python3 - "$REACH_RUN/anchors.jsonl" "$kind" <<'PY'
import json
import sys
from pathlib import Path

path, kind = Path(sys.argv[1]), sys.argv[2]
rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
if kind == "summary":
    rows[0]["excerpt"] = "스냅샷에 없는 요약 문장"
elif kind == "empty":
    rows[0]["excerpt"] = ""
elif kind == "missing-sid":
    rows[0]["sid"] = "R-Z"
elif kind == "locator-path":
    rows[0]["locator"] = "날조된 파일.md:§2"
else:
    raise SystemExit("unknown forgery fixture")
path.write_text("".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in rows), encoding="utf-8")
PY
  "$REACH_GATE" "$REACH_RUN"
}

case_nonnumeric_locator_unicode_path() {
  prepare_reach "$TMP/locator-unicode" run
  python3 - "$REACH_RUN" <<'PY'
import hashlib
import json
import sys
import unicodedata
from pathlib import Path

run = Path(sys.argv[1])
sources_path, anchors_path = run / "sources.jsonl", run / "anchors.jsonl"
sources = [json.loads(line) for line in sources_path.read_text(encoding="utf-8").splitlines()]
anchors = [json.loads(line) for line in anchors_path.read_text(encoding="utf-8").splitlines()]
source = next(row for row in sources if row["sid"] == "R-A")
old = run / source["snapshot"]
name = unicodedata.normalize("NFD", "한글 공백 소스.md")
new = old.with_name(name)
old.rename(new)
source["snapshot"] = "sources/" + name
source["sha256"] = hashlib.sha256(new.read_bytes()).hexdigest()
for anchor in anchors:
    if anchor["sid"] == "R-A":
        anchor["locator"] = name + ":§2"
sources_path.write_text("".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in sources), encoding="utf-8")
anchors_path.write_text("".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in anchors), encoding="utf-8")
PY
  "$REACH_GATE" "$REACH_RUN"
}

case_bench_init_creates_anchors() {
  prepare_reach "$TMP/bench-init-anchors" run
  "$REACH_GATE" "$REACH_RUN"
  "$BENCH_INIT" "$REACH_RUN" A1,A2,A3 3 9 NONE
  [ -d "$REACH_RUN/anchors" ]
}

prepare_live_reach() {
  local base=$1 question="$base/question.txt" axes="$base/axes.tsv" run="$base/target/.assay/live"
  mkdir -p "$(dirname "$run")"
  printf '%s\n' '질문: GitHub 공개 API가 Reach 사다리에서 수집되는가?' '소비처: 라이브 smoke 검증' >"$question"
  printf '%s\n' \
    $'axis_id\tquestion\ttarget_sources' \
    $'AX-1\tGitHub 공개 API 응답은 수집되는가?\t1' \
    $'AX-2\tGitHub API 스냅샷은 재현 가능한가?\t1' \
    $'AX-3\tGitHub API 접근 이력은 계약을 만족하는가?\t1' >"$axes"
  printf '%s\n' '# Live smoke target' 'GitHub public API collection is an integration check.' >"$base/target/release-artifact.md"
  "$REACH_INIT" "$run" "$question" 3 30
  "$REACH_FANOUT" "$run" "$axes"
}

promote_live_sources_and_write_anchors() {
  python3 - "$1" <<'PY'
import json
import sys
from pathlib import Path

run = Path(sys.argv[1])
sources_path = run / "sources.jsonl"
sources = [json.loads(line) for line in sources_path.read_text(encoding="utf-8").splitlines() if line.strip()]
if len(sources) != 3 or any(source.get("status") != "ok" for source in sources):
    raise SystemExit("live reach-fetch가 세 건의 ok 소스를 남기지 않았습니다")
anchors = []
for index, source in enumerate(sources):
    source["kind"] = "primary" if index < 2 else "secondary"
    snapshot = run / source["snapshot"]
    lines = snapshot.read_text(encoding="utf-8").splitlines()
    line = next((value for value in lines if value), "")
    if not line:
        raise SystemExit(f"{snapshot}에 앵커로 쓸 비어 있지 않은 줄이 없습니다")
    sid = source["sid"]
    anchors.append({
        "aid": f"{sid}#01", "sid": sid, "kind": "quote", "axis_hint": source["axis"],
        "active": True, "excerpt": line[0], "locator": f"{snapshot.name}:§live",
        "measured": False, "measure": "", "claim_type": "verified", "confidence": source["confidence"],
        "verdict": "CONFIRMED", "refuted_by": "", "captured_at": source["fetched_at"],
    })
sources_path.write_text("".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in sources), encoding="utf-8")
(run / "anchors.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in anchors), encoding="utf-8")
PY
}

case_live_reach_fetch() {
  local base="$TMP/live-reach" run="$TMP/live-reach/target/.assay/live"
  prepare_live_reach "$base"
  "$REACH_FETCH" "$run" 'https://api.github.com/zen' AX-1
  "$REACH_FETCH" "$run" 'https://api.github.com/?assay_smoke=2' AX-2
  "$REACH_FETCH" "$run" 'https://api.github.com/meta?assay_smoke=3' AX-3
  promote_live_sources_and_write_anchors "$run"
  "$REACH_GATE" "$run"
}

case_live_g2_verdict() {
  local base="$TMP/live-g2" run status
  mkdir -p "$base/대상 프로젝트"
  printf '%s\n' '# Live G2 target' 'This fixture exists only to execute the independent scorer.' >"$base/대상 프로젝트/release-artifact.md"
  complete_happy_path "$base" run
  run=$REACH_RUN
  printf '%s\n' 'AX-1: 0' 'AX-2: 0' 'AX-3: 0' >"$run/counterexample.md"
  "$G2_SPAWN" "$run" --workers 1
  set +e
  "$VERDICT_GATE" "$run"
  status=$?
  set -e
  if [ "$status" -eq 0 ] || [ "$status" -eq 1 ]; then
    printf '[LIVE] verdict-gate executed (exit=%s)\n' "$status"
    return 0
  fi
  return "$status"
}

case_pareto_revert() {
  complete_happy_path "$TMP/pareto-revert" run
  write_round_anchor "$REACH_RUN" R1
  "$BENCH_LOG" "$REACH_RUN" R1 A1 2,3,3 regression
}

case_python_missing() {
  local bin="$TMP/no-python-bin"
  mkdir -p "$bin"
  ln -s "$BASH_BIN" "$bin/bash"
  ln -s "$DIRNAME_BIN" "$bin/dirname"
  PATH="$bin" "$BASH_BIN" "$REACH_INIT"
}

copy_skill_fixture() {
  local name=$1
  FIXTURE_SKILL="$TMP/install-$name/skill"
  mkdir -p "$(dirname "$FIXTURE_SKILL")"
  cp -R "$SKILL_DIR" "$FIXTURE_SKILL"
}

case_install_line_limit() {
  copy_skill_fixture line-limit
  printf '%s\n' '# smoke fixture line' >>"$FIXTURE_SKILL/SKILL.md"
  "$FIXTURE_SKILL/scripts/install-gate.sh" "$FIXTURE_SKILL"
}

case_install_ghost_reference() {
  copy_skill_fixture ghost-reference
  python3 - "$FIXTURE_SKILL/SKILL.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
changed = text.replace("name: assay", "name: reference" + "-research", 1)
if changed == text:
    raise SystemExit("ghost reference fixture failed")
path.write_text(changed, encoding="utf-8")
PY
  "$FIXTURE_SKILL/scripts/install-gate.sh" "$FIXTURE_SKILL"
}

case_install_ds_store() {
  copy_skill_fixture ds-store
  : >"$FIXTURE_SKILL/.DS_Store"
  "$FIXTURE_SKILL/scripts/install-gate.sh" "$FIXTURE_SKILL"
}

run_case 'happy-path end-to-end' 0 complete_happy_path "$TMP/happy" run
run_case '한글·공백·NFD 경로 happy-path' 0 complete_happy_path "$(python3 - "$TMP" <<'PY'
import sys
import unicodedata
print(unicodedata.normalize("NFD", sys.argv[1] + "/한글 공백"))
PY
)" '실행 공간'
run_case 'reach.conf 재봉인 거부' 1 case_reach_reseal
run_case 'gate.conf 재봉인 거부' 1 case_gate_reseal
run_case 'gate.conf 변조 거부' 2 case_gate_conf_tamper
run_case '해시체인 절단 거부' 2 case_chain_tamper
run_case 'scores.tsv 변조 거부' 2 case_scores_tamper
run_case '앵커 위조 요약 거부' 2 case_anchor_forgery summary
run_case '앵커 위조 빈 excerpt 거부' 2 case_anchor_forgery empty
run_case '앵커 위조 없는 sid 거부' 2 case_anchor_forgery missing-sid
run_case '앵커 비숫자 locator 경로 위조 거부' 2 case_anchor_forgery locator-path
run_case '비숫자 locator 한글·공백·NFD 파일명 통과' 0 case_nonnumeric_locator_unicode_path
run_case '파레토 하락 REVERT' 1 case_pareto_revert
run_case 'bench-init anchors 디렉터리 생성' 0 case_bench_init_creates_anchors
run_case 'usage 오류' 64 "$REACH_INIT"
run_case 'python3 부재' 3 case_python_missing
run_case 'install-gate 131행 위생 거부' 2 case_install_line_limit
run_case 'install-gate 유령 인용 거부' 2 case_install_ghost_reference
run_case 'install-gate .DS_Store 거부' 2 case_install_ds_store
run_case '원본 install-gate 통과' 0 "$INSTALL_GATE" "$SKILL_DIR"

if [ "$SMOKE_LIVE" = 1 ]; then
  run_case 'live reach-fetch → reach-gate' 0 case_live_reach_fetch
  if command -v codex >/dev/null 2>&1; then
    run_case 'live g2-spawn → verdict-gate' 0 case_live_g2_verdict
  else
    skip_case 'live g2-spawn → verdict-gate' 'Codex 워커가 필요한 단계'
  fi
else
  skip_case 'live reach-fetch → reach-gate' 'SMOKE_LIVE=1에서만 네트워크 접근을 실행'
  skip_case 'live g2-spawn → verdict-gate' 'SMOKE_LIVE=1 및 Codex 워커가 필요한 단계'
fi

printf '[SUMMARY] pass=%s fail=%s SKIPPED=%s\n' "$passed" "$failed" "$skipped"
if [ "$skipped" -gt 0 ]; then
  printf '%s\n' '이 실행은 라이브 케이스를 보증하지 않는다.'
fi
[ "$failed" -eq 0 ] || exit 1
