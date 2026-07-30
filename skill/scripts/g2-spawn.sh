#!/usr/bin/env bash
# g2-spawn.sh — 격리 Codex 채점자를 실행하고 CSV 출처를 봉인한다.
# usage: g2-spawn.sh <run-dir> [--workers N]
# 종료코드: 0=전원 회수, 1=워커 회수·CSV 형식 실패, 2=프롬프트 계약 위반, 3=codex 환경 미비, 64=사용법 오류
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3
[ "$#" -eq 1 ] || [ "$#" -eq 3 ] || { echo "usage: $0 <run-dir> [--workers N]" >&2; exit 64; }
RUN=$1
WORKERS=3
[ "$#" -ne 3 ] || { [ "$2" = "--workers" ] && [[ "$3" =~ ^[1-9][0-9]*$ ]] && [ "$3" -le 15 ] || usage_die "usage: $0 <run-dir> [--workers N]  (N=1..15)"; WORKERS=$3; }
GATE="$RUN/gate.conf"
[ -f "$GATE" ] || die 2 "gate.conf가 없다 — bench-init.sh를 먼저 실행하라."
seal_verify "$GATE"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); PROMPT_TEMPLATE="$SCRIPT_DIR/../contracts/g2-prompt.md"; CHANNELS="$SCRIPT_DIR/../contracts/channels.yml"; RUBRIC="$RUN/rubric.md"; G2="$RUN/g2"
[ -f "$PROMPT_TEMPLATE" ] && [ -f "$RUBRIC" ] && [ -f "$CHANNELS" ] || die 2 "g2-prompt.md·rubric.md 또는 channels.yml이 없다 — 프롬프트를 조립할 수 없다."
if ! AXES=$(python3 - "$GATE" <<'PY'
import re, sys
try:
    axes=[raw.rstrip("\n")[5:] for raw in open(sys.argv[1],encoding="utf-8") if raw.startswith("AXES=")]
except OSError as exc:
    print(f"!! gate.conf 읽기 실패: {exc}", file=sys.stderr)
    raise SystemExit(2)
if len(axes) != 1 or not axes[0]:
    print("!! gate.conf의 AXES 봉인이 없다.", file=sys.stderr)
    raise SystemExit(2)
parts=axes[0].split(",")
if any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*",part) for part in parts) or len(parts)!=len(set(parts)):
    print("!! gate.conf의 AXES 축 ID 계약이 깨졌다.", file=sys.stderr)
    raise SystemExit(2)
print(axes[0])
PY
); then
  exit 2
fi
candidates=()
for candidate in "$RUN/target-snapshot" "$RUN/snapshot" "$RUN/target"; do [ -e "$candidate" ] && candidates+=("$candidate"); done
if [ "${#candidates[@]}" -eq 0 ] && [ -f "$RUN/gate.conf" ]; then
  if ! sealed_target=$(python3 - "$RUN/gate.conf" <<'PY'
import sys
for raw in open(sys.argv[1], encoding="utf-8"):
    if raw.startswith("TARGET_DIR="):
        value=raw.rstrip("\n").split("=",1)[1]
        if value and not any(c in value for c in "\t\r\n"): print(value); raise SystemExit()
raise SystemExit(1)
PY
); then
    echo "!! gate.conf의 TARGET_DIR 봉인이 없다." >&2; exit 2
  fi
  [ -e "$sealed_target" ] && candidates+=("$sealed_target")
fi
if [ "${#candidates[@]}" -eq 0 ] && [ "$(basename -- "$(dirname -- "$RUN")")" = ".assay" ]; then
  candidates+=("$(dirname -- "$(dirname -- "$RUN")")")
fi
[ "${#candidates[@]}" -eq 1 ] || die 2 "대상 스냅샷은 target-snapshot·snapshot·target 중 정확히 하나여야 한다."
SNAPSHOT=${candidates[0]}
mkdir -p "$G2"
printf '%s\n' '# G2 독립 채점의 한계' '워커는 channels.yml에 선언한 모델(비어 있으면 Codex 기본 모델)로 개선 이력·자기채점·라운드 앵커를 제외해 채점한다.' '같은 오케스트레이터 아래의 실행이므로 완전한 외부 독립 채점은 아니다.' > "$G2/README"
rm -f -- "$G2"/worker-*.csv
need_tool codex 3
if ! MODEL=$(python3 - "$CHANNELS" <<'PY'
import re, sys
try:
    lines=open(sys.argv[1],encoding="utf-8").read().splitlines()
except OSError as exc:
    print("!! channels.yml 읽기 실패: " + str(exc), file=sys.stderr)
    raise SystemExit(2)
channels=0; values=[]
for raw in lines:
    line=raw.split("#",1)[0].strip()
    channels += bool(re.fullmatch(r"-\s*name\s*:\s*[^\s].*",line))
    match=re.fullmatch(r"g2_model\s*:\s*(.*)",line)
    if match:
        value=match.group(1).strip()
        values.append(value[1:-1] if len(value)>1 and value[0]==value[-1] and value[0] in "'\"" else value)
if not channels or len(values)!=channels or len(set(values))!=1:
    print("!! channels.yml: 모든 채널의 g2_model 봉인값은 한 값으로 선언해야 한다.", file=sys.stderr)
    raise SystemExit(2)
model = values[0]
if model and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]*", model):
    print("!! channels.yml: g2_model 형식이 잘못되었다.", file=sys.stderr)
    raise SystemExit(2)
print(model)
PY
); then
  exit 2
fi
if [ -n "$MODEL" ]; then RECEIPT_MODEL="declared:$MODEL"; else RECEIPT_MODEL="default"; fi
PROMPT=$(mktemp /tmp/assay-g2-prompt.XXXXXX)
trap 'rm -f -- "$PROMPT"' EXIT
python3 - "$PROMPT" "$PROMPT_TEMPLATE" "$RUBRIC" "$SNAPSHOT" "$RUN" <<'PY'
import sys
from pathlib import Path
out, template, rubric, snapshot, run = map(Path, sys.argv[1:])
def fail(message): print("!! "+message,file=sys.stderr); sys.exit(2)
try:
    parts=[template.read_text(encoding="utf-8"),"\n## 루브릭\n",rubric.read_text(encoding="utf-8"),"\n## 채점 대상 스냅샷\n"]
except (OSError, UnicodeError) as exc:
    fail(f"프롬프트 입력 읽기 실패: {exc}")
blocked = [run / "rounds.jsonl", run / "scores.tsv"] + list((run / "anchors").glob("R*.md"))
blocked_paths = {path.resolve() for path in blocked if path.is_file()}
def is_blocked(path): return path.resolve() in blocked_paths
def include(path, label):
    try:
        data = path.read_bytes()
    except OSError as exc:
        fail(f"스냅샷 읽기 실패: {exc}")
    if b"\0" in data:
        return f"\n### {label}\n[이진 파일은 채점 프롬프트에서 생략]\n"
    try:
        return f"\n### {label}\n"+data.decode("utf-8")+"\n"
    except UnicodeDecodeError:
        return f"\n### {label}\n[UTF-8이 아닌 파일은 채점 프롬프트에서 생략]\n"
if snapshot.is_file() and not snapshot.is_symlink() and not is_blocked(snapshot):
    parts.append(include(snapshot, snapshot.name))
elif snapshot.is_dir() and not snapshot.is_symlink():
    files=sorted((p.relative_to(snapshot).as_posix(),p) for p in snapshot.rglob("*") if p.is_file() and not p.is_symlink() and not is_blocked(p) and not any(x in {".git",".assay"} for x in p.relative_to(snapshot).parts))
    if not files: fail("대상 스냅샷에 읽을 일반 파일이 없다.")
    parts.extend(include(path,label) for label,path in files)
else:
    fail("대상 스냅샷은 일반 파일 또는 디렉터리여야 한다.")
parts.append("\n## 반환 형식\n설명·표·코드펜스 없이 첫 줄 axis_id,score,citation 헤더와 축별 세 열 CSV만 출력하라. 점수는 0~4 정수이고 인용은 비어 있으면 안 된다.\n")
prompt = "".join(parts)
for path in blocked:
    if path.is_file():
        try:
            forbidden = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            fail(f"차단 파일 읽기 실패: {exc}")
        if forbidden.strip() and forbidden in prompt:
            fail(f"프롬프트 오염: {path.name} 내용이 조립 결과에 섞였다.")
out.write_text(prompt, encoding="utf-8")
PY
PROMPT_SHA256=$(sha256_of "$PROMPT")
pids=(); workdirs=(); worker_ids=(); outputs=(); started=(); ended=(); worker_exit=(); errors=()
cleanup_workers() { local workdir; for workdir in "${workdirs[@]}"; do rm -rf -- "$workdir"; done; workdirs=(); }
run_workers() {
  local selected_model=$1 number=1 output workdir error index status; local -a command
  pids=(); workdirs=(); worker_ids=(); outputs=(); started=(); ended=(); worker_exit=(); errors=(); failed=0
  while [ "$number" -le "$WORKERS" ]; do
    output="$G2/worker-$number.csv"; workdir=$(mktemp -d /tmp/assay-g2-worker.XXXXXX); error="$workdir/codex.err"
    workdirs+=("$workdir"); worker_ids+=("worker-$number"); outputs+=("$output"); errors+=("$error"); started+=("$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    command=(codex exec -C "$workdir" --skip-git-repo-check --sandbox read-only --ephemeral); [ -z "$selected_model" ] || command+=(-m "$selected_model"); command+=(-o "$output" -)
    ( "${command[@]}" < "$PROMPT" ) >/dev/null 2>"$error" & pids+=("$!")
    number=$((number + 1))
  done
  for index in "${!pids[@]}"; do
    if wait "${pids[$index]}"; then status=0; else status=$?; failed=1; fi; worker_exit+=("$status"); ended+=("$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  done
}
failure_matches() {
  python3 - "$1" "${errors[@]}" <<'PY'
import re, sys
pattern,paths=sys.argv[1],sys.argv[2:]; text="\n".join(open(p,encoding="utf-8",errors="replace").read() for p in paths)
raise SystemExit(0 if re.search(pattern,text,re.I) else 1)
PY
}
MODEL_ERROR='(?:\b400\b|not supported when using codex|unsupported(?:\s+model)?|\bmodel\b.*\b(?:not found|unavailable|not available)\b)'
ENV_ERROR="$MODEL_ERROR|authentication|\blog[ -]?in\b|\bsign[ -]?in\b|\brate[ -]?limit\b|network(?:\s+is)?\s+(?:unavailable|disabled)|connection (?:refused|failed)"
run_workers "$MODEL"
if [ "$failed" -ne 0 ] && [ -n "$MODEL" ] && failure_matches "$MODEL_ERROR"; then
  cleanup_workers; rm -f -- "$G2"/worker-*.csv; run_workers ""; [ "$failed" -ne 0 ] || RECEIPT_MODEL="fallback:model_unavailable"
fi
if [ "$failed" -ne 0 ]; then
  if failure_matches "$ENV_ERROR"; then cleanup_workers; die 3 "Codex 모델 또는 실행 환경을 사용할 수 없다."; fi
  cleanup_workers; die 1 "독립 채점 워커 회수에 실패했다."
fi
cleanup_workers
python3 - "$G2" "$AXES" "$WORKERS" <<'PY'
import csv, re, sys
from pathlib import Path
g2=Path(sys.argv[1]); axes=sys.argv[2].split(","); expected_workers=int(sys.argv[3])
def bad(message): print("!! "+message,file=sys.stderr); sys.exit(1)
if not axes or any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*",axis) for axis in axes) or len(axes)!=len(set(axes)):
    bad("gate.conf AXES 축 계약이 깨졌다.")
paths=sorted(g2.glob("worker-*.csv"))
if len(paths) != expected_workers:
    bad("회수된 워커 CSV 개수가 요청 수와 다르다.")
for path in paths:
    try:
        rows=list(csv.reader(path.read_text(encoding="utf-8").splitlines()))
    except (OSError, UnicodeError, csv.Error) as exc:
        bad(f"워커 CSV 읽기 실패: {path.name}: {exc}")
    if not rows or rows[0] != ["axis_id", "score", "citation"]:
        bad(f"워커 CSV 헤더 위반: {path.name}")
    seen = set()
    for row in rows[1:]:
        if len(row)!=3 or row[0] not in axes or not re.fullmatch(r"[0-4]",row[1].strip()) or not row[2].strip() or row[0] in seen:
            bad(f"워커 CSV 형식 위반: {path.name}")
        seen.add(row[0])
    if seen != set(axes):
        bad(f"워커 CSV 축 누락·추가: {path.name}")
print(f"독립 채점 회수 완료: 워커 {len(paths)}개")
PY
hashes=()
for output in "${outputs[@]}"; do hashes+=("$(sha256_of "$output")"); done
receipt_args=("$G2/receipt.json" "$RECEIPT_MODEL" "$PROMPT_SHA256" "$AXES" "$WORKERS")
for index in "${!worker_ids[@]}"; do
  receipt_args+=("${worker_ids[$index]}" "${started[$index]}" "${ended[$index]}" "${hashes[$index]}" "${worker_exit[$index]}")
done
PYTHONPATH="$(dirname "$0")${PYTHONPATH:+:$PYTHONPATH}" python3 - "${receipt_args[@]}" <<'PY'
import _pylib, json, sys
from datetime import datetime, timezone
receipt,model,prompt_sha256,axes,expected=sys.argv[1:6]; expected=int(expected); fields=sys.argv[6:]
if len(fields) != expected * 5: print("!! G2 영수증 워커 필드 수가 맞지 않는다.", file=sys.stderr); raise SystemExit(2)
workers=[{"id":a,"started":b,"ended":c,"csv_sha256":d,"exit":int(e)} for a,b,c,d,e in (fields[n:n+5] for n in range(0,len(fields),5))]
payload={"ts":datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z"),"model":model,"prompt_sha256":prompt_sha256,"axes":axes,"workers":workers}
serialized=json.dumps(payload,ensure_ascii=False,separators=(",",":"))+"\n"
try: _pylib.atomic_write(receipt, serialized)
except Exception as exc:
    print(f"!! G2 영수증 기록 실패: {exc}", file=sys.stderr)
    raise SystemExit(2)
PY
