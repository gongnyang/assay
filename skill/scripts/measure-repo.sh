#!/usr/bin/env bash
# measure-repo.sh — GitHub 레포의 전제 M1~M7과 채점 입력 M8~M18을 TSV로 계측한다.
# 전제 위반을 점수로 희석하지 않는 것이 이 스크립트의 존재 이유다 — 위반이면 채점 자체를 멈춘다.
#
# usage: measure-repo.sh <repo-dir> <run-dir>
# 종료코드: 0=전제 통과, 1=전제 위반, 2=계약 위반, 3=환경 미비, 64=사용법 오류
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3
[ $# -eq 2 ] || { echo "usage: $0 <repo-dir> <run-dir>" >&2; exit 64; }
[ -d "$1" ] || { echo "레포 디렉터리 없음: $1" >&2; exit 2; }
exec python3 - "$1" "$2" <<'PY'
import hashlib, json, os, re, shutil, subprocess, sys, tempfile, urllib.error, urllib.request
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.parse import unquote, urlparse
root, run = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
readme = root/"README.md"
rows, pre_fail, env_error = [], False, False
def die(message, code=2): print(message, file=sys.stderr); raise SystemExit(code)
def clean(value): return str(value).replace("\t", " ").replace("\n", " ").replace("\r", " ")
def row(metric, status, value, detail=""): rows.append((str(root), metric, status, clean(value), clean(detail)))
def read(path):
    try: return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError): return ""
def headings(markdown): return [(len(m.group(1)), n, m.group(2).rstrip(" #\t")) for n,line in enumerate(markdown.splitlines(),1) if (m:=re.match(r"^(#{1,6})[ \t]+(.+?)\s*$",line))]
def slug(value):
    return re.sub(r"[\s-]+","-",re.sub(r"[^\w\s-]","",value.strip().casefold(),flags=re.UNICODE)).strip("-")
def target_inside(path):
    try: path.resolve().relative_to(root); return True
    except ValueError: return False
def markdown_urls(markdown):
    urls=[]
    for a,b in re.findall(r"!?\[[^\]]*\]\(([^)]+)\)|<((?:https?://)[^>]+)>",markdown):
        value=(a or b).strip()
        if value.startswith("<") and value.endswith("> "): value = value[1:-1]
        urls.append(re.split(r"\s+[\"']",value,1)[0].strip("<>"))
    return urls
def gh_api(endpoint):
    if not shutil.which("gh"): raise RuntimeError("gh 없음")
    proc = subprocess.run(["gh", "api", endpoint], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode: raise RuntimeError(proc.stderr.strip() or f"gh api 실패: {endpoint}")
    return json.loads(proc.stdout)
def parse_gates():
    gate=run/"gate.conf"
    if not gate.exists(): return []
    if not gate.is_file(): die("gate.conf가 일반 파일이 아닙니다.")
    try:
        source=gate.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        die(f"gate.conf 읽기 실패: {exc}")
    gates=[]
    for lineno, raw in enumerate(source.splitlines(), 1):
        line=raw.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        key,value=(part.strip() for part in line.split("=",1))
        if key!="METRIC_GATE": continue
        fields=[part.strip() for part in value.split("|")]
        if len(fields)!=5 or any(not part for part in fields): die(f"gate.conf:{lineno}: METRIC_GATE 형식 오류")
        _,instrument,metric,op,expected=fields
        if instrument!="measure-repo": continue
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", metric) or op not in {">=", "<=", "==", ">", "<"}:
            die(f"gate.conf:{lineno}: 알 수 없는 레포 계측 임계값")
        try:
            number=Decimal(expected)
        except InvalidOperation:
            die(f"gate.conf:{lineno}: 수치 임계값이 아님")
        if not number.is_finite():
            die(f"gate.conf:{lineno}: 수치 임계값이 유한하지 않음")
        gates.append((metric, op, number))
    return gates
def metric_values():
    values,bare={},{}
    numeric=re.compile(r"(?:^|[;,\s])([A-Za-z][A-Za-z0-9_-]*)=(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?)")
    for _, metric, status, value, _ in rows:
        values[metric]=Decimal(1 if status=="PASS" else 0)
        for name, number in numeric.findall(value):
            parsed=Decimal(number); values[f"{metric}_{name}"]=parsed
            bare[name]=parsed if name not in bare else (parsed if bare[name]==parsed else None)
    values.update({name: number for name, number in bare.items() if number is not None})
    return values
def gate_failures():
    values,failed=metric_values(),[]
    for metric, op, expected in gates:
        if metric not in values: die(f"gate.conf: measure-repo 계측값이 없습니다: {metric}")
        actual=values[metric]; ok={">=":actual>=expected,"<=":actual<=expected,"==":actual==expected,">":actual>expected,"<":actual<expected}[op]
        if not ok: failed.append(f"{metric}={actual} {op} {expected}")
    return failed
def write_metrics(exit_code):
    output_dir=run/"metrics"; tsv_path=output_dir/"measure-repo.tsv"
    try:
        output_dir.mkdir(parents=True, exist_ok=True)
        payload=("repo\tmetric\tstatus\tvalue\tdetail\n"+"".join("\t".join(item)+"\n" for item in rows)).encode("utf-8")
        fd,temporary=tempfile.mkstemp(prefix=".measure-repo.",dir=output_dir)
        with os.fdopen(fd, "wb") as output: output.write(payload)
        os.replace(temporary,tsv_path)
        proof={"instrument":"measure-repo.sh","argv":sys.argv[1:],"ts":datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z"),"tsv_sha256":hashlib.sha256(payload).hexdigest(),"rows":len(rows)}
        fd,temporary=tempfile.mkstemp(prefix=".measure-repo.prov.",dir=output_dir)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as output:
            json.dump(proof, output, ensure_ascii=False, separators=(",", ":")); output.write("\n")
        os.replace(temporary,output_dir/"measure-repo.tsv.prov")
    except OSError as exc:
        try: os.unlink(temporary)
        except (OSError, UnboundLocalError): pass
        print(f"metrics 기록 실패: {exc}", file=sys.stderr)
        raise SystemExit(2)
    failed=gate_failures()
    if failed: print("봉인 임계 미달: "+", ".join(failed),file=sys.stderr)
    raise SystemExit(1 if exit_code == 1 or failed else exit_code)
gates=parse_gates(); md=read(readme)
if not md:
    row("M1", "FAIL", "README.md 없음 또는 읽기 실패", "P1")
    for num in range(2, 19): row(f"M{num}", "NA", "README 없음")
    write_metrics(1)
hs = headings(md); h1 = [h for h in hs if h[0] == 1]
if len(h1) == 1: row("M1", "PASS", f"h1_count={len(h1)}", "P1")
else: row("M1", "FAIL", f"h1_count={len(h1)}", "P1"); pre_fail = True
first_h1 = re.search(r"^#[ \t]+.*$", md, re.M)
start = first_h1.end() if first_h1 else 0
sample = " ".join(md[start:].split()[:300])
m2 = bool(re.search(r"[^.]{4,}\.", sample))
row("M2", "PASS" if m2 else "FAIL", f"sentence_period={int(m2)}", "P2; 수동 확인 병행")
pre_fail |= not m2
blocks = re.findall(r"^```[^\n]*\n(.*?)^```", md, re.M | re.S)
command = re.compile(r"(^|\n)\s*(?:[$#]\s*)?(?:curl|brew|apt(?:-get)?|npm|npx|pip(?:3)?|python3?|uv|cargo|go|git\s+clone|make|\.\/)[\s\S]*", re.I)
m3 = any(command.search(block) for block in blocks)
row("M3", "PASS" if m3 else "FAIL", f"install_or_run_fence={int(m3)}", "P3")
pre_fail |= not m3
root_text = "\n".join(read(p) for p in root.iterdir() if p.is_file())
m4 = bool(re.search(r"\b(license|copyright|apache|mit|unlicense|gpl|bsd|mpl|isc)\b", root_text, re.I))
row("M4", "PASS" if m4 else "FAIL", f"license_notice={int(m4)}", "P4")
pre_fail |= not m4
license_files = [p for p in root.iterdir() if p.is_file() and p.name.upper().startswith("LICENSE")]
slug_name = None
try:
    remote = subprocess.run(["git", "-C", str(root), "remote", "get-url", "origin"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    match = re.search(r"(?:[/:])([^/:]+)/([^/\s]+?)(?:\.git)?$", remote.stdout.strip())
    slug_name = f"{match.group(1)}/{match.group(2)}" if match else None
except FileNotFoundError:
    env_error = True
if not license_files or not slug_name:
    row("M5","FAIL",f"license_files={len(license_files)}; github_remote={int(bool(slug_name))}","P5"); pre_fail=True
elif not shutil.which("gh"):
    env_error = True; row("M5", "ERROR", "gh 없음", "P5")
else:
    try:
        spdx=(gh_api(f"repos/{slug_name}").get("license") or {}).get("spdx_id"); good=spdx is not None
        row("M5","PASS" if good else "FAIL",f"license_files={len(license_files)}; spdx_id={spdx}","P5"); pre_fail|=not good
    except RuntimeError as exc:
        env_error = True; row("M5", "ERROR", "github_api_unavailable", str(exc))
docs=[p for p in (root/"docs").rglob("*.md")] if (root/"docs").is_dir() else []; doc_texts=[(readme,md),*((p,read(p)) for p in docs)]; external,anchors_bad,external_bad,external_error=set(),[],[],[]
for source, content in doc_texts:
    for url in markdown_urls(content):
        if url.startswith(("http://", "https://")): external.add(url)
        elif url.startswith("#"):
            if slug(url[1:]) not in {slug(h[2]) for h in headings(content)}: anchors_bad.append(f"{source.relative_to(root)}{url}")
        elif url and not url.startswith(("mailto:", "tel:", "/")):
            path_part, _, fragment=unquote(url).partition("#"); dest=(source.parent/path_part).resolve()
            if not target_inside(dest) or not dest.exists(): anchors_bad.append(f"{source.relative_to(root)}->{url}")
            elif fragment and dest.suffix.lower() == ".md" and slug(fragment) not in {slug(h[2]) for h in headings(read(dest))}: anchors_bad.append(f"{source.relative_to(root)}->{url}")
for url in sorted(external):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "assay-measure/1"}), timeout=10) as response:
            if response.status != 200: external_bad.append(f"{url}:{response.status}")
    except urllib.error.HTTPError as exc: external_bad.append(f"{url}:{exc.code}")
    except (urllib.error.URLError, TimeoutError, ValueError) as exc: external_error.append(f"{url}:{exc}")
m6ok = not anchors_bad and not external_bad and not external_error
status6 = "ERROR" if external_error else ("PASS" if m6ok else "FAIL")
row("M6", status6, f"external={len(external)}; bad={len(anchors_bad)+len(external_bad)}; error={len(external_error)}", "; ".join((anchors_bad+external_bad+external_error)[:8]))
pre_fail |= bool(anchors_bad or external_bad); env_error |= bool(external_error)
relative_bad=[]
for url in markdown_urls(md):
    if url and not url.startswith(("#", "http://", "https://", "mailto:", "tel:", "/")):
        path=(readme.parent/unquote(url.split("#",1)[0])).resolve()
        if not target_inside(path) or not path.exists(): relative_bad.append(url)
m7ok = not relative_bad
row("M7", "PASS" if m7ok else "FAIL", f"missing_relative={len(relative_bad)}", "; ".join(relative_bad[:8]))
pre_fail |= not m7ok
media=list(re.finditer(r"!\[[^\]]*\]\([^)]*\)|<img\b[^>]*>",md,re.I)); first_media=media[0].start()-start if media else -1
shields=len(re.findall(r"shields"+r"\."+r"io",md,re.I))
row("M8", "INFO", f"first_media_chars={first_media}; media_count={len(media)}; shields={shields}")
install_block = next((m for m in re.finditer(r"^```[^\n]*\n(.*?)^```", md, re.M | re.S) if command.search(m.group(1))), None)
before = md[:install_block.start()] if install_block else md
row("M9", "INFO", f"first_install_fence_chars={install_block.start()-start if install_block else -1}; headings_before={len(headings(before))}")
context = md[max(0, (install_block.start() if install_block else 0)-200):(install_block.start() if install_block else 0)]
row("M10", "INFO", f"requirements_near_fence={int(bool(re.search(r'Requirements|Prerequisites|Requires|필요', context, re.I)))}")
all_md=[p for p in root.rglob("*.md") if p.resolve()!=readme.resolve() and ".git" not in p.relative_to(root).parts]; docs_items=sum(1 for _ in (root/"docs").iterdir()) if (root/"docs").is_dir() else 0
row("M11", "INFO", f"docs_items={docs_items}; supplemental_md={len(all_md)}")
linked = set()
for url in markdown_urls(md):
    part = unquote(url.split("#", 1)[0])
    if part and not urlparse(part).scheme:
        candidate = (readme.parent / part).resolve()
        if candidate.suffix.lower() == ".md" and candidate.exists(): linked.add(candidate)
unlinked = [str(p.relative_to(root)) for p in all_md if p.resolve() not in linked]
row("M12", "INFO", f"unlinked_md={len(unlinked)}", "; ".join(unlinked))
if slug_name and not env_error:
    try:
        releases, tags = gh_api(f"repos/{slug_name}/releases?per_page=100"), gh_api(f"repos/{slug_name}/tags?per_page=100")
        dates=[]
        for tag in tags[:3]:
            dates.append(((gh_api(f"repos/{slug_name}/commits/{tag['commit']['sha']}").get("commit",{}).get("committer",{}) or {}).get("date","")))
        parsed=[datetime.fromisoformat(d.replace("Z","+00:00")) for d in dates if d]; intervals=[str((parsed[i]-parsed[i+1]).days) for i in range(len(parsed)-1)]
        row("M13", "INFO", f"releases={len(releases)}; tags={len(tags)}", "recent_tag_dates=" + ",".join(dates) + "; interval_days=" + ",".join(intervals))
    except (RuntimeError, KeyError, ValueError) as exc:
        env_error = True; row("M13", "ERROR", "github_api_unavailable", str(exc))
else: row("M13", "INFO", "NA", "GitHub API 전제 미충족")
workflows = list((root / ".github" / "workflows").glob("*.y*ml")) if (root / ".github" / "workflows").is_dir() else []
tests_in_workflows = sum(bool(re.search(r"go test|cargo test|pytest|npm test", read(p), re.I)) for p in workflows)
row("M14", "INFO", f"workflows={len(workflows)}; test_command_files={tests_in_workflows}")
test_files = {p for p in root.rglob("*") if p.is_file() and (re.match(r"(?:.*_test|test_.*)\.[^.]+$", p.name) or "tests" in p.relative_to(root).parts)}
row("M15", "INFO", f"test_files={len(test_files)}")
changes = [p for p in root.iterdir() if p.is_file() and re.match(r"(?:CHANGELOG|RELEASE-NOTES)", p.name, re.I)]
row("M16", "INFO", f"files={len(changes)}; bytes={sum(p.stat().st_size for p in changes)}", "; ".join(p.name for p in changes))
matches17 = [f"{level}:{line}:{title}" for level, line, title in hs if re.search(r"Disclaimer|Limitations|Non-goals|Contributing|Scope|Telemetry|한계|비목표|면책|기여|범위", title, re.I)]
row("M17", "INFO", f"boundary_headings={len(matches17)}", "; ".join(matches17))
row("M18", "INFO", f"headings={len(hs)}", "; ".join(f"{level}:{line}:{title}" for level, line, title in hs))
write_metrics(1 if pre_fail else (3 if env_error else 0))
PY
