#!/usr/bin/env bash
# bench-revert.sh — 마지막 REVERT를 직전 채택 상태로 실제 복원한다.
# usage: bench-revert.sh <run-dir> <round>
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3

[ "$#" -eq 2 ] || usage_die "usage: $0 <run-dir> <round>"
seal_verify "$1/gate.conf"

exec python3 - "$@" <<'PY'
import hashlib
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone

def die(message, code=2):
    print("!! " + message, file=sys.stderr)
    raise SystemExit(code)

def record_hash(record):
    body = {key: value for key, value in record.items() if key not in {"prev_hash", "self_hash"}}
    return hashlib.sha256(json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()

def chain(path):
    records, previous = [], "GENESIS"
    try: source = open(path, encoding="utf-8")
    except OSError: die("rounds.jsonl이 필요합니다.")
    for lineno, raw in enumerate(source, 1):
        if not raw.strip(): continue
        try: record = json.loads(raw)
        except json.JSONDecodeError as exc: die(f"rounds.jsonl:{lineno}: JSON 오류: {exc.msg}")
        if (not isinstance(record, dict) or record.get("prev_hash") != previous
                or not isinstance(record.get("self_hash"), str) or record["self_hash"] != record_hash(record)):
            die(f"rounds.jsonl:{lineno}: 해시 체인이 끊겼습니다.")
        previous = record["self_hash"]; records.append(record)
    return records

def append(path, records, record):
    record["prev_hash"] = records[-1]["self_hash"] if records else "GENESIS"
    record["self_hash"] = record_hash(record)
    with open(path, "a", encoding="utf-8") as out:
        out.write(json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")

def target_from(conf):
    target = None
    try: lines = open(conf, encoding="utf-8")
    except OSError: die("gate.conf이 필요합니다.")
    for lineno, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        if not line or line.startswith("#"): continue
        if "=" not in line: die(f"gate.conf:{lineno}: key=value 형식이 아닙니다.")
        key, value = line.split("=", 1)
        if key == "TARGET_DIR":
            if target is not None or not value or any(c in value for c in "\t\r\n"):
                die("TARGET_DIR 봉인이 손상되었습니다.")
            target = value
    if target is None: die("TARGET_DIR 봉인이 없습니다.")
    return target

def score_rows(records):
    return [(index, row) for index, row in enumerate(records)
            if "event" not in row and isinstance(row.get("round"), str) and isinstance(row.get("verdict"), str)]

def safely_inside(root, target):
    try:
        return os.path.commonpath([os.path.realpath(root), os.path.realpath(target)]) == os.path.realpath(target)
    except ValueError:
        return False

def manifest(root, exclude=None):
    found = {}
    for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
        relbase = os.path.relpath(base, root); relbase = "" if relbase == "." else relbase
        kept = []
        for name in dirs:
            rel = os.path.join(relbase, name)
            if exclude and exclude(rel): continue
            path = os.path.join(base, name)
            if os.path.islink(path):
                die("스냅샷 복원은 디렉터리 심볼릭 링크를 허용하지 않습니다.")
            kept.append(name)
        dirs[:] = kept
        for name in files:
            rel = os.path.join(relbase, name)
            if exclude and exclude(rel): continue
            path = os.path.join(base, name)
            if os.path.islink(path):
                found[rel] = ("link", hashlib.sha256(os.readlink(path).encode("utf-8", "surrogateescape")).hexdigest())
            else:
                h = hashlib.sha256()
                with open(path, "rb") as src:
                    for block in iter(lambda: src.read(1024 * 1024), b""): h.update(block)
                found[rel] = ("file", h.hexdigest())
    return found

def tree_hash(entries):
    h = hashlib.sha256()
    for rel, (kind, digest) in sorted(entries.items()):
        h.update(rel.encode("utf-8", "surrogateescape") + b"\0" + kind.encode("ascii") + b"\0" + digest.encode("ascii") + b"\n")
    return h.hexdigest()

def snapshot_restore(target, run, previous, state):
    target, run = os.path.realpath(target), os.path.realpath(run)
    snapshot = os.path.join(run, "rounds", previous["round"])
    if not os.path.isdir(snapshot) or not os.path.isdir(target):
        die("스냅샷 또는 TARGET_DIR이 없어 되돌릴 대상이 없습니다.")
    relrun = os.path.relpath(run, target)
    inside_run = relrun != ".." and not relrun.startswith(".." + os.sep)
    def excluded(rel):
        return inside_run and (rel == relrun or rel.startswith(relrun + os.sep))
    want, have = manifest(snapshot), manifest(target, excluded)
    delete = sorted(set(have) - set(want))
    for rel in delete: print("삭제 예정: " + rel)
    if have and len(delete) * 2 > len(have):
        die("삭제 대상이 TARGET_DIR 파일의 50%를 초과해 복원을 거부합니다.")
    for rel in delete:
        path = os.path.join(target, rel)
        if os.path.lexists(path): os.unlink(path)
    for rel, wanted in want.items():
        src, dst = os.path.join(snapshot, rel), os.path.join(target, rel)
        parent = os.path.realpath(os.path.dirname(dst))
        if not safely_inside(parent, target): die("스냅샷 복원 경로가 TARGET_DIR 밖을 가리킵니다.")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.lexists(dst) and manifest(target, excluded).get(rel) != wanted:
            os.unlink(dst)
        if not os.path.lexists(dst):
            if wanted[0] == "link": os.symlink(os.readlink(src), dst)
            else: shutil.copy2(src, dst, follow_symlinks=False)
    actual = manifest(target, excluded)
    if actual != want: die("스냅샷 복원 뒤 파일별 sha256이 직전 채택본과 일치하지 않습니다.", 1)
    return {"method": "snapshot", "tree_hash": tree_hash(actual), "snapshot": snapshot}

run, requested = os.path.abspath(sys.argv[1]), sys.argv[2]
conf, rounds = os.path.join(run, "gate.conf"), os.path.join(run, "rounds.jsonl")
target = target_from(conf)
records = chain(rounds)
normal = score_rows(records)
if not normal or normal[-1][1].get("round") != requested or normal[-1][1].get("verdict") != "REVERT":
    die("지정 라운드는 아직 복원되지 않은 마지막 REVERT여야 합니다.")
rejected_index, rejected = normal[-1]
if any(row.get("event") == "revert" and row.get("round") == requested for row in records[rejected_index + 1:]):
    die("지정 REVERT는 이미 복원되었습니다.")
previous = next((row for _, row in reversed(normal[:-1]) if row.get("verdict") in {"BASE", "KEEP", "SIMPLIFY"}), None)
if previous is None: die("직전 KEEP/BASE/SIMPLIFY 라운드가 없어 되돌릴 대상이 없습니다.")
state = previous.get("state")
if not isinstance(state, dict) or state.get("kind") not in {"git", "snapshot"} or not isinstance(state.get("root"), str):
    die("직전 채택본의 복원 상태가 없습니다.")
if not os.path.isdir(target) or not safely_inside(state["root"], target):
    die("state.root가 봉인된 TARGET_DIR 하위가 아니어서 복원을 거부합니다.")
if state["kind"] == "git":
    root, commit, expected = state["root"], state.get("commit"), state.get("tree_hash")
    if not all(isinstance(value, str) and value for value in (commit, expected)):
        die("봉인된 git 복원 상태가 손상되었습니다.")
    try:
        exists = subprocess.run(["git", "-C", root, "cat-file", "-e", commit + "^{commit}"], capture_output=True)
        stored = subprocess.run(["git", "-C", root, "rev-parse", commit + "^{tree}"], text=True, capture_output=True, check=True).stdout.strip()
    except FileNotFoundError: die("git 실행 도구가 없습니다.", 3)
    except subprocess.CalledProcessError: die("commit 또는 봉인된 git 상태가 없어 되돌릴 대상이 없습니다.")
    if exists.returncode or stored != expected: die("commit 또는 봉인된 git 상태가 없어 되돌릴 대상이 없습니다.")
    reset = subprocess.run(["git", "-C", root, "reset", "--hard", commit], text=True, capture_output=True)
    if reset.returncode: die("git reset --hard 복원에 실패했습니다: " + reset.stderr.strip(), 1)
    actual = subprocess.run(["git", "-C", root, "rev-parse", "HEAD^{tree}"], text=True, capture_output=True, check=True).stdout.strip()
    if actual != expected: die("git 복원 뒤 tree_hash가 직전 채택본과 다릅니다.", 1)
    proof = {"method": "git", "tree_hash": actual, "expected_tree_hash": expected, "root": root}
else:
    proof = snapshot_restore(target, run, previous, state)
record = {"event": "revert", "round": requested, "restored_to": previous["round"], "restored": True,
          "method": proof["method"], "tree_hash": proof["tree_hash"],
          "ts": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")}
if "expected_tree_hash" in proof: record["expected_tree_hash"] = proof["expected_tree_hash"]
append(rounds, records, record)
print(f"[{requested}] 복원 완료: 직전 채택본으로 되돌렸고 tree_hash 증거를 rounds.jsonl에 기록했습니다.")
PY
