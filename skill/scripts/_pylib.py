# 공용 Python 방어 흡수표 (모든 함수는 예외만 던지며 sys.exit 하지 않는다)
# | 출처 | 흡수한 방어 |
# | --- | --- |
# | bench-init.sh:159-168 | 같은 디렉터리 임시 파일, BaseException 때 임시 파일 정리 |
# | reach-init.sh:81-93 | 부모 디렉터리 생성, 바이너리/UTF-8 텍스트, LF 쓰기, 정리 |
# | reach-fanout.sh:62-74 | 부모 디렉터리 생성, 파일명별 임시 파일, 정리 |
# | measure-skill.sh:122-133 | 바이트 payload, rename 실패 때 임시 파일 정리 |
# | measure-repo.sh:90-107 | 출력 디렉터리 생성, 바이트/JSON 텍스트 원자 교체, 정리 |
# | verdict-gate.sh:172-180 | 완성한 CSV를 한 번에 교체 |
# | g2-spawn.sh:213-219 | 완성한 JSON을 한 번에 교체 |
# | bench-log.sh:13-28 | canonical JSON 해시, GENESIS, 공백 줄 무시, append 뒤 records 갱신 |
# | bench-revert.sh:24-46 | canonical JSON 해시, 행 번호가 있는 JSON/체인 검증, append |
# | bench-init.sh:37-64 | receipt 단일 JSON 행, 8개 필드 형식, anchors/reach.conf 해시 대조 |
# | rubric-lint.sh:28-43 | receipt JSON 객체와 anchors/reach.conf 존재·해시 대조 |
# | verdict-gate.sh:47-50 | receipt를 모든 후속 판정 전에 anchors/reach.conf와 대조 |
#
# 추가 강도: atomic_write는 mkstemp(0600) 권한을 유지하고 기존 일반 파일의
# 권한을 보존하며, 파일과 부모 디렉터리를 fsync한 뒤에만 성공을 반환한다.

import hashlib
import json
import os
import re
import stat
import tempfile
from pathlib import Path


def atomic_write(path, data, binary=False):
    """부모 디렉터리를 만든 뒤 데이터를 같은 파일계의 임시 파일에서 교체한다.

    바이너리 모드에서는 bytes 계열을, 텍스트 모드에서는 UTF-8 문자열을 받아
    기존 파일의 권한(없으면 mkstemp의 0600)을 보존하고 파일·디렉터리 fsync까지
    끝낸 경우에만 반환한다. 실패하면 교체 전 임시 파일을 정리하고 예외를 전파한다.
    """
    destination = Path(path)
    parent = destination.parent
    if binary:
        if not isinstance(data, (bytes, bytearray, memoryview)):
            raise TypeError("binary=True이면 bytes 계열 data가 필요합니다.")
        payload = bytes(data)
    elif not isinstance(data, str):
        raise TypeError("binary=False이면 str data가 필요합니다.")
    else:
        payload = data

    parent.mkdir(parents=True, exist_ok=True)
    previous_mode = None
    try:
        previous_mode = stat.S_IMODE(destination.stat().st_mode)
    except FileNotFoundError:
        pass

    descriptor = None
    temporary = None
    replaced = False
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=parent)
        if previous_mode is not None:
            os.fchmod(descriptor, previous_mode)
        if binary:
            output = os.fdopen(descriptor, "wb")
        else:
            output = os.fdopen(descriptor, "w", encoding="utf-8", newline="\n")
        descriptor = None
        with output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
        replaced = True
        directory_descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except BaseException:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if temporary is not None and not replaced:
            try:
                os.unlink(temporary)
            except OSError:
                pass
        raise


def verify_chain(path):
    """rounds.jsonl의 모든 비공백 행이 끊기지 않은 canonical SHA-256 체인임을 보장한다.

    각 행은 JSON 객체여야 하고 prev_hash는 직전 self_hash(첫 행은 GENESIS)와 같아야
    한다. self_hash는 두 체인 필드를 제외한 객체의 고정 JSON 직렬화 해시와 대조하며,
    통과한 레코드 목록을 반환한다. 누락·파싱 오류·체인 단절은 예외로 알린다.
    """
    source_path = Path(path)
    records = []
    previous = "GENESIS"
    with source_path.open(encoding="utf-8") as source:
        for lineno, raw in enumerate(source, 1):
            if not raw.strip():
                continue
            try:
                record = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{source_path}:{lineno}: JSON 오류: {exc.msg}") from exc
            body = {key: value for key, value in record.items() if key not in {"prev_hash", "self_hash"}} if isinstance(record, dict) else None
            actual = (hashlib.sha256(json.dumps(body, ensure_ascii=False, sort_keys=True,
                                                separators=(",", ":")).encode("utf-8")).hexdigest()
                      if body is not None else None)
            if (not isinstance(record, dict) or record.get("prev_hash") != previous
                    or not isinstance(record.get("self_hash"), str)
                    or record["self_hash"] != actual):
                raise ValueError(f"{source_path}:{lineno}: 해시 체인이 끊겼습니다.")
            previous = record["self_hash"]
            records.append(record)
    return records


def append_record(path, records, record):
    """검증된 레코드 목록의 다음 해시를 계산해 rounds.jsonl에 내구성 있게 한 행 추가한다.

    record의 기존 체인 필드는 현재 목록을 기준으로 다시 계산하고 canonical JSON 한 줄을
    O_APPEND로 기록·fsync한 뒤 records에도 같은 객체를 추가한다. 입력이 체인에 쓸 수
    없는 형태이거나 기록에 실패하면 예외를 던진다.
    """
    if not isinstance(record, dict):
        raise TypeError("record는 JSON 객체(dict)여야 합니다.")
    if not hasattr(records, "append"):
        raise TypeError("records는 append 가능한 목록이어야 합니다.")
    try:
        last = records[-1] if records else None
    except (IndexError, TypeError) as exc:
        raise TypeError("records는 순서가 있는 목록이어야 합니다.") from exc
    if last is not None and (not isinstance(last, dict)
                             or not isinstance(last.get("self_hash"), str)
                             or not re.fullmatch(r"[0-9a-f]{64}", last["self_hash"])):
        raise ValueError("records의 마지막 self_hash가 유효하지 않습니다.")

    record["prev_hash"] = last["self_hash"] if last is not None else "GENESIS"
    body = {key: value for key, value in record.items() if key not in {"prev_hash", "self_hash"}}
    record["self_hash"] = hashlib.sha256(
        json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    serialized = json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"

    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(destination, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        output = os.fdopen(descriptor, "w", encoding="utf-8", newline="\n")
        descriptor = None
        with output:
            output.write(serialized)
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        raise
    records.append(record)


def verify_reach_receipt(run, required_fields):
    """요청된 receipt 필드의 형식과 현재 run 입력물의 SHA-256 일치를 보장한다.

    reach-gate.receipt는 정확히 하나의 비어 있지 않은 JSON 객체 행이어야 한다.
    required_fields에 넣은 ts, 네 SHA-256 필드, 세 정수 필드만 각각 검증하므로 호출부가
    검사 강도를 정한다. 요청한 해시 필드는 대응 원본 파일의 존재와 현재 해시까지 대조한
    뒤 receipt 객체를 반환하며, 모든 계약 위반은 예외로 알린다.
    """
    if isinstance(required_fields, (str, bytes)):
        raise TypeError("required_fields는 필드명의 반복 가능 객체여야 합니다.")
    try:
        fields = tuple(required_fields)
    except TypeError as exc:
        raise TypeError("required_fields는 필드명의 반복 가능 객체여야 합니다.") from exc
    known = {
        "ts", "question_sha256", "reach_conf_sha256", "sources_sha256",
        "anchors_sha256", "usable", "primary", "confirmed_anchors",
    }
    if any(not isinstance(field, str) for field in fields) or set(fields) - known:
        raise ValueError("required_fields에 알 수 없는 receipt 필드가 있습니다.")

    run_path = Path(run)
    receipt_path = run_path / "reach-gate.receipt"
    if not receipt_path.is_file():
        raise FileNotFoundError("축1을 통과하지 않았다. reach-gate.sh를 먼저 실행하라")
    try:
        lines = receipt_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ValueError(f"reach-gate.receipt 읽기 실패: {exc}") from exc
    if len(lines) != 1 or not lines[0].strip():
        raise ValueError("reach-gate.receipt는 JSON 1행이어야 합니다.")
    try:
        receipt = json.loads(lines[0])
    except json.JSONDecodeError as exc:
        raise ValueError(f"reach-gate.receipt JSON 오류: {exc.msg}") from exc
    if not isinstance(receipt, dict):
        raise ValueError("reach-gate.receipt는 JSON 객체여야 합니다.")

    hash_sources = {
        "question_sha256": "question.md",
        "reach_conf_sha256": "reach.conf",
        "sources_sha256": "sources.jsonl",
        "anchors_sha256": "anchors.jsonl",
    }
    for field in fields:
        value = receipt.get(field)
        if field == "ts":
            if not isinstance(value, str) or not value.strip():
                raise ValueError("reach-gate.receipt ts 필드 형식이 잘못되었습니다.")
        elif field in {"usable", "primary", "confirmed_anchors"}:
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError(f"reach-gate.receipt {field} 필드 형식이 잘못되었습니다.")
        else:
            if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
                raise ValueError(f"reach-gate.receipt {field} 필드 형식이 잘못되었습니다.")
            source = run_path / hash_sources[field]
            if not source.is_file():
                raise FileNotFoundError(f"reach-gate.receipt의 {source.name} 원본이 없습니다.")
            digest = hashlib.sha256()
            with source.open("rb") as input_file:
                for block in iter(lambda: input_file.read(1024 * 1024), b""):
                    digest.update(block)
            if digest.hexdigest() != value:
                raise ValueError(f"reach-gate.receipt와 현재 {source.name} 해시가 다릅니다.")
    return receipt
