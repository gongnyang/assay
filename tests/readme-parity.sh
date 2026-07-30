#!/usr/bin/env bash
# README.md와 README.ko.md의 두 원본이 같은 구조와 증거를 다루는지 검사한다.
# 산문은 두 언어에서 독립적으로 쓴다. 따라서 펜스 밖 설명·주석 문장은 비교하지
# 않는다. 반대로 펜스 안은 명령과 실제 출력이므로 줄바꿈까지 바이트 동일해야 한다.
# usage: readme-parity.sh [<english-readme> <korean-readme>]
# 종료코드: 0=일치, 2=문서 계약 위반, 3=python3 없음, 64=사용법 오류
set -uo pipefail

case "$#" in
  0)
    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
    ENGLISH_README="$SCRIPT_DIR/../README.md"
    KOREAN_README="$SCRIPT_DIR/../README.ko.md"
    ;;
  2)
    ENGLISH_README=$1
    KOREAN_README=$2
    ;;
  *)
    printf 'usage: %s [<english-readme> <korean-readme>]\n' "$0" >&2
    exit 64
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'python3가 필요하다. README parity 검사를 실행할 수 없다.' >&2
  exit 3
fi

if [ ! -f "$ENGLISH_README" ] || [ ! -f "$KOREAN_README" ]; then
  [ -f "$ENGLISH_README" ] || printf 'README 없음: %s\n' "$ENGLISH_README" >&2
  [ -f "$KOREAN_README" ] || printf 'README 없음: %s\n' "$KOREAN_README" >&2
  exit 2
fi

python3 - "$ENGLISH_README" "$KOREAN_README" <<'PY'
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


FENCE_OPEN = re.compile(rb"^[ \t]{0,3}(`{3,}|~{3,})[^\r\n]*$")
HEADING = re.compile(r"^(#{1,3})[ \t]+.*?\s*$")
INLINE_LINK = re.compile(
    r"!?\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))(?:\s+[^)]*)?\)"
)
NUMBER_CLAIM = re.compile(
    r"(?<!\d)(\d+)\s*(?:개|종|행|케이스)(?!\w)"
    r"|(?<!\d)(\d+)\s*(?:-|\s)+(?:cases?|scripts?|lines?|rows?|types?|items?)(?!\w)",
    re.IGNORECASE,
)
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def display_line(number):
    return f"line {number}" if number is not None else "line — (absent)"


def decoded(raw, path, number):
    try:
        return raw.rstrip(b"\r\n").decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"{path}:{number}: UTF-8 decoding failed: {exc}") from exc


def relative_target(raw_target):
    """Return a comparable local file target, or None for non-file links.

    A fragment is intentionally excluded: translated headings have different slugs,
    while the file named before that fragment is the evidence target. The README
    cross-links are also excluded because they necessarily point at the other language.
    """
    target = raw_target.strip()
    if not target or target.startswith("#") or target.startswith("/") or target.startswith("//"):
        return None
    if SCHEME.match(target):
        return None
    target = target.split("#", 1)[0]
    if not target:
        return None
    while target.startswith("./"):
        target = target[2:]
    if target in {"README.md", "README.ko.md"}:
        return None
    return target


class Document:
    def __init__(self, path):
        self.path = Path(path)
        self.lines = self.path.read_bytes().splitlines(keepends=True)
        self.headings = []
        self.fences = []
        self.links = defaultdict(list)
        self.claims = defaultdict(list)
        self.unclosed_fences = []
        self.parse()

    def parse(self):
        index = 0
        while index < len(self.lines):
            raw = self.lines[index].rstrip(b"\r\n")
            opened = FENCE_OPEN.match(raw)
            if opened:
                marker = opened.group(1)
                marker_char = marker[:1]
                marker_length = len(marker)
                closing = re.compile(
                    rb"^[ \t]{0,3}" + re.escape(marker_char) + rb"{" + str(marker_length).encode("ascii") + rb",}[ \t]*$"
                )
                content_start = index + 1
                cursor = content_start
                while cursor < len(self.lines):
                    if closing.match(self.lines[cursor].rstrip(b"\r\n")):
                        break
                    cursor += 1
                closed = cursor < len(self.lines)
                content_end = cursor if closed else len(self.lines)
                self.fences.append(
                    {
                        "open": index + 1,
                        "close": cursor + 1 if closed else None,
                        "content": b"".join(self.lines[content_start:content_end]),
                        "body_lines": list(range(content_start + 1, content_end + 1)),
                    }
                )
                if not closed:
                    self.unclosed_fences.append(index + 1)
                index = cursor + 1 if closed else len(self.lines)
                continue

            line_number = index + 1
            text = decoded(self.lines[index], self.path, line_number)
            heading = HEADING.match(text)
            if heading:
                self.headings.append((len(heading.group(1)), line_number))
            for match in INLINE_LINK.finditer(text):
                target = relative_target(match.group(1) or match.group(2))
                if target is not None:
                    self.links[target].append(line_number)
            for match in NUMBER_CLAIM.finditer(text):
                value = int(match.group(1) or match.group(2))
                self.claims[value].append((line_number, match.group(0)))
            index += 1


def add_difference(message):
    differences.append(message)


def compare_headings(english, korean):
    maximum = max(len(english.headings), len(korean.headings))
    for index in range(maximum):
        en = english.headings[index] if index < len(english.headings) else None
        ko = korean.headings[index] if index < len(korean.headings) else None
        if en == ko and en is not None:
            continue
        if en is not None and ko is not None and en[0] == ko[0]:
            continue
        en_detail = f"H{en[0]}, {display_line(en[1])}" if en else display_line(None)
        ko_detail = f"H{ko[0]}, {display_line(ko[1])}" if ko else display_line(None)
        add_difference(f"heading #{index + 1}: EN {en_detail}; KO {ko_detail}")


def content_preview(raw):
    if raw is None:
        return "<absent>"
    return repr(raw.rstrip(b"\r\n").decode("utf-8", errors="backslashreplace"))


def first_content_difference(en_fence, ko_fence):
    en_lines = en_fence["content"].splitlines(keepends=True)
    ko_lines = ko_fence["content"].splitlines(keepends=True)
    for index in range(max(len(en_lines), len(ko_lines))):
        en_line = en_lines[index] if index < len(en_lines) else None
        ko_line = ko_lines[index] if index < len(ko_lines) else None
        if en_line != ko_line:
            en_number = en_fence["body_lines"][index] if index < len(en_fence["body_lines"]) else None
            ko_number = ko_fence["body_lines"][index] if index < len(ko_fence["body_lines"]) else None
            return en_number, ko_number, en_line, ko_line
    return en_fence["open"], ko_fence["open"], None, None


def compare_fences(english, korean):
    maximum = max(len(english.fences), len(korean.fences))
    for index in range(maximum):
        en = english.fences[index] if index < len(english.fences) else None
        ko = korean.fences[index] if index < len(korean.fences) else None
        if en is None or ko is None:
            add_difference(
                f"code fence #{index + 1}: EN {display_line(en['open'] if en else None)}; "
                f"KO {display_line(ko['open'] if ko else None)}"
            )
            continue
        if en["content"] != ko["content"]:
            en_line, ko_line, en_text, ko_text = first_content_difference(en, ko)
            add_difference(
                f"code fence #{index + 1} content: EN {display_line(en_line)} "
                f"(fence opens {display_line(en['open'])}); KO {display_line(ko_line)} "
                f"(fence opens {display_line(ko['open'])}); "
                f"EN={content_preview(en_text)}; KO={content_preview(ko_text)}"
            )

    for language, document, counterpart in (("EN", english, korean), ("KO", korean, english)):
        for line in document.unclosed_fences:
            other_line = counterpart.fences[0]["open"] if counterpart.fences else None
            add_difference(
                f"unclosed code fence: {language} {display_line(line)}; "
                f"other README {display_line(other_line)}"
            )


def compare_link_sets(english, korean):
    for target in sorted(set(english.links) - set(korean.links)):
        add_difference(
            f"relative link target only in EN: {target!r}; EN {display_line(english.links[target][0])}; "
            f"KO {display_line(None)}"
        )
    for target in sorted(set(korean.links) - set(english.links)):
        add_difference(
            f"relative link target only in KO: {target!r}; EN {display_line(None)}; "
            f"KO {display_line(korean.links[target][0])}"
        )


def compare_numeric_claims(english, korean):
    en_counts = Counter({value: len(records) for value, records in english.claims.items()})
    ko_counts = Counter({value: len(records) for value, records in korean.claims.items()})
    for value in sorted(set(en_counts) | set(ko_counts)):
        difference = en_counts[value] - ko_counts[value]
        if difference > 0:
            for line, claim in english.claims[value][:difference]:
                add_difference(
                    f"numeric claim {value} only in EN: {claim!r}, EN {display_line(line)}; "
                    f"KO {display_line(None)}"
                )
        elif difference < 0:
            for line, claim in korean.claims[value][:-difference]:
                add_difference(
                    f"numeric claim {value} only in KO: EN {display_line(None)}; "
                    f"KO {display_line(line)}, {claim!r}"
                )


try:
    english = Document(sys.argv[1])
    korean = Document(sys.argv[2])
except (OSError, ValueError) as exc:
    print(f"README parity input error: {exc}", file=sys.stderr)
    raise SystemExit(2)

differences = []
compare_headings(english, korean)
compare_fences(english, korean)
compare_link_sets(english, korean)
compare_numeric_claims(english, korean)

if differences:
    print("README parity failed:", file=sys.stderr)
    for difference in differences:
        print(f"- {difference}", file=sys.stderr)
    raise SystemExit(2)
print("README parity passed")
PY
