#!/usr/bin/env bash
# install-gate.sh — 배포 트리와 봉인·영수증·출처 증명 회귀를 설치 전에 거부한다.
# usage: install-gate.sh <skill-dir>
# 종료코드: 0=설치 가능, 2=배포 계약 위반, 3=환경 미비, 64=사용법 오류
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3

[ "$#" -eq 1 ] || usage_die "usage: $0 <skill-dir>"
SKILL_DIR=$1
[ -d "$SKILL_DIR" ] || die 2 "스킬 디렉터리 없음: $SKILL_DIR"
[ -f "$SKILL_DIR/SKILL.md" ] || die 2 "SKILL.md 없음"

python3 - "$SKILL_DIR" <<'PY'
import os, re, sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(); errors = []
needle = b"reference" + b"-research"
fixed = {
    "contracts": ("channels.yml", "sources.schema.json", "anchors.schema.json", "rubric.template.md", "g2-prompt.md"),
    "references": ("reach-protocol.md", "access-ladder.md", "rubric-design.md", "loop-protocol.md", "contracts.md", "instruments.md"),
}
blocked = (
    b"r" + b".jina" + b".ai", b"api" + b".github" + b".com",
    b"raw" + b".githubusercontent" + b".com", b"github" + b".com",
    b"arxiv" + b".org", b"news" + b".ycombinator" + b".com",
    b"hacker-news" + b".firebaseio" + b".com", b"bsky" + b".app",
    b"public" + b".api" + b".bsky" + b".app",
)
site_pattern = re.compile(rb"(?i)(?:https?://)?[a-z0-9-]+(?:[.][a-z0-9-]+)*[.](?:com|org|net|io|ai|app|dev|edu|gov)(?:[:/?#\"']|$)")
for directory, names in fixed.items():
    for name in names:
        if not (root / directory / name).is_file(): errors.append(f"필수 선언 파일 없음: {directory}/{name}")
for base, dirs, files in os.walk(root, followlinks=False):
    here = Path(base)
    if here.name == "__MACOSX": errors.append(f"배포 잔재: {here.relative_to(root)}")
    for name in files:
        path = here / name
        if name == ".DS_Store" or name.startswith("._"): errors.append(f"배포 잔재: {path.relative_to(root)}")
        try: data = path.read_bytes()
        except OSError as exc: errors.append(f"읽기 실패: {path.relative_to(root)}: {exc}"); continue
        if needle in data: errors.append(f"유령 부모 인용: {path.relative_to(root)}")
scripts = root / "scripts"; common = scripts / "_common.sh"
if not common.is_file(): errors.append("공통 유틸 없음: scripts/_common.sh")
for script in sorted(scripts.glob("*.sh")):
    try: content = script.read_text(encoding="utf-8"); data = content.encode("utf-8")
    except (OSError, UnicodeDecodeError) as exc: errors.append(f"스크립트 읽기 실패: {script.relative_to(root)}: {exc}"); continue
    if not os.access(script, os.X_OK): errors.append(f"실행 권한 없음: {script.relative_to(root)}")
    if not content.startswith("#!"): errors.append(f"shebang 없음: {script.relative_to(root)}")
    if script.name == "_common.sh":
        if not re.search(r"^need_python3\(\)", content, re.M) or not re.search(r"^need_python3\s*$", content, re.M): errors.append("_common.sh python3 가드 없음")
    else:
        if '. "$(dirname "$0")/_common.sh"' not in content: errors.append(f"공통 유틸 source 없음: {script.relative_to(root)}")
        if not re.search(r"^need_python3\s*(?:#.*)?$", content, re.M): errors.append(f"python3 가드 없음: {script.relative_to(root)}")
        if any(token in data.lower() for token in blocked) or site_pattern.search(data.lower().replace(b"\\.", b".")):
            errors.append(f"스크립트 사이트 상수: {script.relative_to(root)}")
skill = root / "SKILL.md"
try: lines = skill.read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeDecodeError) as exc: errors.append(f"SKILL.md 읽기 실패: {exc}"); lines = []
if len(lines) > 130: errors.append(f"SKILL.md 행수 초과: {len(lines)} > 130")
if not lines or lines[0] != "---": errors.append("SKILL.md frontmatter 시작 표식 없음")
else:
    try: end = lines.index("---", 1)
    except ValueError: end = -1
    if end < 2: errors.append("SKILL.md frontmatter 종료 표식 없음")
    else:
        keys = set()
        for no, raw in enumerate(lines[1:end], 2):
            if not raw.strip() or raw.lstrip().startswith("#"): continue
            if raw[:1].isspace(): continue
            match = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):(?:\s*(.*))?$", raw)
            if not match: errors.append(f"frontmatter:{no}: YAML 부분집합 파싱 실패"); continue
            keys.add(match.group(1)); value = match.group(2).strip()
            if value[:1] in {"'", '"'} and (len(value) < 2 or value[-1:] != value[:1]): errors.append(f"frontmatter:{no}: 닫히지 않은 인용부호")
        if not {"name", "description"}.issubset(keys): errors.append("frontmatter: name 또는 description 없음")
        if not lines[end + 1:]: errors.append("SKILL.md 본문 없음")
for declared in re.findall(r"(?<![\w.-])((?:references|contracts)/[^\s<>()\[\]`\"']+)", "\n".join(lines)):
    candidate = (root / declared.rstrip(".,:;")).resolve()
    try: candidate.relative_to(root)
    except ValueError: errors.append(f"선언 경로 탈출: {declared}"); continue
    if not candidate.is_file(): errors.append(f"선언 파일 없음: {declared}")
for error in errors: print("!! " + error, file=sys.stderr)
raise SystemExit(2 if errors else 0)
PY

BENCH_INIT="$SKILL_DIR/scripts/bench-init.sh"
BENCH_LOG="$SKILL_DIR/scripts/bench-log.sh"
MEASURE_SKILL="$SKILL_DIR/scripts/measure-skill.sh"
[ -x "$BENCH_INIT" ] && [ -x "$BENCH_LOG" ] && [ -x "$MEASURE_SKILL" ] || die 2 "회귀 픽스처 대상 없음"
TMP=$(mktemp -d) || die 2 "임시 디렉터리 생성 실패"
trap 'rm -rf "$TMP"' EXIT
TARGET="$TMP/target"
mkdir -p "$TARGET"
RUN="$TARGET/.assay/run"
fail=0
expect() {
  local label=$1 expected=$2 actual
  shift 2; set +e; "$@" >"$TMP/$label.out" 2>"$TMP/$label.err"; actual=$?; set -e
  if [ "$actual" -ne "$expected" ]; then echo "!! 회귀 실패 $label: exit $actual (기대 $expected)" >&2; fail=1; fi
}
prepare_run() {
  local run=$1
  mkdir -p "$run"; : > "$run/anchors.jsonl"; printf 'QUESTION_SHA256=test\n' > "$run/reach.conf"
  python3 - "$run" <<'PY'
import hashlib, json, sys
from pathlib import Path
run = Path(sys.argv[1])
h = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
print(json.dumps({"ts":"2000-01-01T00:00:00Z","question_sha256":"0" * 64,"reach_conf_sha256":h(run / "reach.conf"),"sources_sha256":"0" * 64,"anchors_sha256":h(run / "anchors.jsonl"),"usable":0,"primary":0,"confirmed_anchors":0}, separators=(",", ":")), file=open(run / "reach-gate.receipt", "w", encoding="utf-8"))
PY
}
anchors() { mkdir -p "$1/anchors"; printf 'A1: 한글파일.md:1\nA2: 한글파일.md:2\nA3: 한글파일.md:3\n' > "$1/anchors/$2.md"; }

expect usage 64 "$BENCH_INIT"
prepare_run "$RUN"
expect axes 2 "$BENCH_INIT" "$RUN" 'A1,,A3' 3 9 NONE
expect init 0 "$BENCH_INIT" "$RUN" 'A1,A2,A3' 3 9 NONE
expect reinit 1 "$BENCH_INIT" "$RUN" 'A1,A2,A3' 3 9 NONE
anchors "$RUN" R0
expect unicode_anchor 0 "$BENCH_LOG" "$RUN" R0 - '3,3,3' baseline
expect prov_write 0 "$MEASURE_SKILL" "$SKILL_DIR" "$RUN"
expect prov_hash 0 python3 -c 'import hashlib,json,sys; t,p=map(__import__("pathlib").Path,sys.argv[1:]); x=json.loads(p.read_text(encoding="utf-8")); assert x["instrument"]=="measure-skill.sh" and x["tsv_sha256"]==hashlib.sha256(t.read_bytes()).hexdigest() and x["rows"]==len(t.read_text(encoding="utf-8").splitlines())-1' "$RUN/metrics/measure-skill.tsv" "$RUN/metrics/measure-skill.tsv.prov"
anchors "$RUN" R1
expect pareto_revert 1 "$BENCH_LOG" "$RUN" R1 A1 '2,3,3' regression
anchors "$RUN" R2
expect unreverted 2 "$BENCH_LOG" "$RUN" R2 A1 '3,3,3' unreverted

RECEIPT_RUN="$TARGET/.assay/receipt"; prepare_run "$RECEIPT_RUN"; printf x >> "$RECEIPT_RUN/anchors.jsonl"
expect receipt_tamper 2 "$BENCH_INIT" "$RECEIPT_RUN" 'A1,A2,A3' 3 9 NONE
SEAL_RUN="$TARGET/.assay/seal"; prepare_run "$SEAL_RUN"
expect seal_init 0 "$BENCH_INIT" "$SEAL_RUN" 'A1,A2,A3' 3 9 NONE
anchors "$SEAL_RUN" R0; printf '\n# tamper\n' >> "$SEAL_RUN/gate.conf"
expect seal_tamper 2 "$BENCH_LOG" "$SEAL_RUN" R0 - '3,3,3' tamper
CHAIN_RUN="$TARGET/.assay/chain"; prepare_run "$CHAIN_RUN"
expect chain_init 0 "$BENCH_INIT" "$CHAIN_RUN" 'A1,A2,A3' 3 9 NONE
anchors "$CHAIN_RUN" R0; expect chain_base 0 "$BENCH_LOG" "$CHAIN_RUN" R0 - '3,3,3' baseline
expect chain_mutate 0 python3 -c 'from pathlib import Path; import sys; p=Path(sys.argv[1]); p.write_text(p.read_text(encoding="utf-8").replace("\"sum\":9", "\"sum\":8", 1), encoding="utf-8")' "$CHAIN_RUN/rounds.jsonl"
anchors "$CHAIN_RUN" R1
expect chain_tamper 2 "$BENCH_LOG" "$CHAIN_RUN" R1 A1 '3,3,3' tamper

[ "$fail" -eq 0 ] || exit 2
echo "설치 게이트 통과: $SKILL_DIR (회귀 16케이스)"
