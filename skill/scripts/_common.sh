#!/usr/bin/env bash
# 공통 계약 유틸. 이 파일은 source 전용이며 bash 3.2와 python3만 요구한다.

need_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' 'python3가 필요하다. reach-doctor.sh로 환경을 확인하라.' >&2
    exit 3
  fi
}

need_tool() {
  if [ "$#" -ne 2 ]; then
    die 64 'need_tool 사용법: need_tool <name> <exit>'
  fi
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "$1 도구가 없다. reach-doctor.sh로 환경을 확인하라." >&2
    exit "$2"
  fi
}

die() {
  if [ "$#" -ne 2 ]; then
    printf '%s\n' 'die 사용법: die <code> <msg>' >&2
    exit 64
  fi
  printf '%s\n' "$2" >&2
  exit "$1"
}

usage_die() {
  if [ "$#" -ne 1 ]; then
    die 64 'usage_die 사용법: usage_die <msg>'
  fi
  printf '%s\n' "$1" >&2
  exit 64
}

sha256_of() {
  if [ "$#" -ne 1 ]; then
    die 64 'sha256_of 사용법: sha256_of <file>'
  fi
  python3 - "$1" <<'PY'
import hashlib
import sys

try:
    with open(sys.argv[1], 'rb') as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
except (IndexError, OSError) as exc:
    print('sha256 계산 실패: ' + str(exc), file=sys.stderr)
    raise SystemExit(2)
print(digest)
PY
}

seal_write() {
  if [ "$#" -ne 1 ]; then
    die 64 'seal_write 사용법: seal_write <file>'
  fi
  local seal_path hash_value base_name
  seal_path="$1.seal"
  base_name=${1##*/}
  hash_value=$(sha256_of "$1") || exit $?
  if ! printf '%s  %s\n' "$hash_value" "$base_name" >"$seal_path"; then
    die 2 "봉인 기록을 쓸 수 없다: $seal_path"
  fi
}

seal_verify() {
  if [ "$#" -ne 1 ]; then
    die 64 'seal_verify 사용법: seal_verify <file>'
  fi
  local seal_path expected actual hash_value base_name line count
  seal_path="$1.seal"
  base_name=${1##*/}
  if [ ! -f "$seal_path" ]; then
    die 2 "봉인이 없다: $seal_path"
  fi
  count=0
  while IFS= read -r line || [ -n "$line" ]; do
    count=$((count + 1))
    expected=$line
  done <"$seal_path"
  [ "$count" -eq 1 ] || die 2 "봉인 형식이 잘못되었다: $seal_path"
  hash_value=$(sha256_of "$1") || exit $?
  actual="$hash_value  $base_name"
  if [ "$expected" != "$actual" ]; then
    die 2 "봉인 해시가 일치하지 않는다: $1"
  fi
}

need_python3
