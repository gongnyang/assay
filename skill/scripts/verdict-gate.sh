#!/usr/bin/env bash
# verdict-gate.sh — G2, 역방향 채점, 반례를 모두 통과한 경우에만 PASS를 발급한다.
# usage: verdict-gate.sh <run-dir>
# 종료코드: 0=PASS, 1=판정 실패, 2=계약·증거 위반, 3=python3 없음, 64=사용법 오류
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3

[ "$#" -eq 1 ] || usage_die "usage: $0 <run-dir>"
RUN=$1
[ -f "$RUN/gate.conf" ] || die 2 "gate.conf가 없다 — bench-init.sh를 먼저 실행하라."
seal_verify "$RUN/gate.conf"
PYTHONPATH="$(dirname "$0")${PYTHONPATH:+:$PYTHONPATH}" exec python3 - "$RUN" <<'PY'
import csv, hashlib, io, json, re, sys
from pathlib import Path

from _pylib import atomic_write, verify_reach_receipt
run=Path(sys.argv[1])
def die(code,msg): print("!! "+msg,file=sys.stderr); raise SystemExit(code)
def read(path):
    try: return path.read_text(encoding="utf-8")
    except (OSError,UnicodeError) as exc: die(2,f"{path.name} 읽기 실패: {exc}")
def sha(path):
    try: return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as exc: die(2,f"{path.name} 해시 계산 실패: {exc}")
def one_json(path,label):
    try: value=json.loads(read(path))
    except json.JSONDecodeError as exc: die(2,f"{label} JSON 오류: {exc.msg}")
    if not isinstance(value,dict): die(2,f"{label}은 JSON 객체여야 한다")
    return value
def cells(line): return [cell.strip() for cell in line.strip().strip("|").split("|")]
gate_path=run/"gate.conf"; gate_text=read(gate_path); gate={}
raw_axes=[]
for line in gate_text.splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        key,value=line.split("=",1); gate[key.strip()]=value.strip()
        if key=="AXES": raw_axes.append(value)
if len(raw_axes)!=1 or not raw_axes[0]: die(2,"gate.conf의 AXES 봉인이 깨졌다")
axes_raw=raw_axes[0]; axes=axes_raw.split(",")
try: minimum,required_sum,n_axes=(int(gate[k]) for k in ("MIN_REQ","SUM_REQ","N_AXES"))
except (KeyError,ValueError): die(2,"gate.conf의 AXES·N_AXES·MIN_REQ·SUM_REQ 계약이 깨졌다")
if (len(axes)!=n_axes or not 3<=len(axes)<=7 or len(axes)!=len(set(axes))
        or any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*",axis) for axis in axes)):
    die(2,"gate.conf 축 계약이 깨졌다")

# 축1 영수증은 축2의 모든 판정 전에 현재 입력물과 대조한다.
try: verify_reach_receipt(run, ("anchors_sha256", "reach_conf_sha256"))
except (OSError, TypeError, ValueError) as exc: die(2, str(exc))
required=[run/"scores.tsv",run/"rubric.md",run/"counterexample.md"]
if any(not path.is_file() for path in required): die(2,"scores.tsv·rubric.md·counterexample.md가 모두 필요하다")
try: score_rows=list(csv.reader(read(run/"scores.tsv").splitlines(),delimiter="\t"))
except csv.Error as exc: die(2,f"scores.tsv 파싱 실패: {exc}")
header=["round","axis",*axes,"min","sum","gate","verdict","note"]
if not score_rows or score_rows[0]!=header: die(2,"scores.tsv 헤더가 gate.conf 봉인과 일치하지 않는다")
places=[header.index(axis) for axis in axes]; verdict_col=header.index("verdict")
self_scores=None
for no,row in enumerate(score_rows[1:],2):
    if len(row)!=len(header): die(2,f"scores.tsv:{no} 행 형식이 잘못되었다")
    values=[row[pos].strip() for pos in places]
    if all(re.fullmatch(r"[0-4]",value) for value in values) and row[verdict_col] in {"BASE","KEEP","SIMPLIFY"}:
        self_scores=list(map(int,values))
if self_scores is None: die(2,"채택된 자기채점 행이 scores.tsv에 없다")
rubric=read(run/"rubric.md"); lines=rubric.splitlines()
heading=re.compile(r"^\s{0,3}#{1,6}[ \t]+(?:축[ \t]+)?([A-Za-z][A-Za-z0-9_-]*)(?=[ \t]|[.:—–-]|$)")
starts=[(m.group(1),i) for i,line in enumerate(lines) if (m:=heading.match(line)) and m.group(1) in axes]
if len(starts)!=len(axes) or set(axis for axis,_ in starts)!=set(axes): die(2,"rubric.md 축과 gate.conf 축이 일치하지 않는다")
sections={axis:"\n".join(lines[start:(starts[pos+1][1] if pos+1<len(starts) else len(lines))]) for pos,(axis,start) in enumerate(starts)}
qualitative={"정성","없음","none","n/a","na","해당 없음","-"}
qual_count=0; automatic=[]
for axis in axes:
    measures=re.findall(r"(?im)^\s*measure\s*:\s*(.*?)\s*$",sections[axis])
    if not measures or any(value.strip().casefold() in qualitative for value in measures): qual_count+=1
    else: automatic.append(axis)
qualitative_majority=qual_count*2>len(axes)
if automatic and not any(path.is_file() and path.stat().st_size for path in (run/"metrics").glob("*.tsv")):
    die(2,"자동검증 축의 metrics/*.tsv 증거가 없다")
# receipt의 worker 목록과 현존 CSV는 1:1이어야 한다. 목록 밖 CSV도 거부한다.
g2=run/"g2"; receipt=one_json(g2/"receipt.json","g2/receipt.json")
for field in ("ts","model","prompt_sha256","axes","workers"):
    if field not in receipt: die(2,f"g2/receipt.json에 {field} 필드가 없다")
if (not isinstance(receipt["ts"],str) or not receipt["ts"] or not isinstance(receipt["model"],str)
        or not receipt["model"] or not isinstance(receipt["prompt_sha256"],str)
        or not re.fullmatch(r"[0-9a-f]{64}",receipt["prompt_sha256"]) or receipt["axes"]!=axes_raw
        or not isinstance(receipt["workers"],list) or not receipt["workers"]): die(2,"g2/receipt.json 계약이 깨졌다")
records={}
for item in receipt["workers"]:
    if (not isinstance(item,dict) or set(item)!={"id","started","ended","csv_sha256","exit"}
            or not isinstance(item.get("id"),str) or not re.fullmatch(r"worker-[1-9][0-9]*",item["id"])
            or item["id"] in records or not all(isinstance(item.get(k),str) and item[k] for k in ("started","ended"))
            or not isinstance(item.get("csv_sha256"),str) or not re.fullmatch(r"[0-9a-f]{64}",item["csv_sha256"])
            or not isinstance(item.get("exit"),int) or item["exit"]!=0): die(2,"g2/receipt.json worker 계약이 깨졌다")
    records[item["id"]]=item
workers=sorted(g2.glob("worker-*.csv")); current={path.stem:path for path in workers}
if set(current)!=set(records): die(2,"G2 영수증과 worker-*.csv 목록이 일치하지 않는다")
if not workers: die(2,"정성 축 과반에는 G2가 필수다" if qualitative_majority else "독립 채점 CSV가 없다 — G2를 실행해야 한다")
independent=[]
for worker_id,path in sorted(current.items()):
    if sha(path)!=records[worker_id]["csv_sha256"]: die(2,f"{path.name} 해시가 G2 영수증과 다르다")
    try: rows=list(csv.reader(read(path).splitlines()))
    except csv.Error as exc: die(2,f"{path.name} CSV 파싱 실패: {exc}")
    if not rows or rows[0]!=["axis_id","score","citation"]: die(2,f"{path.name} CSV 헤더가 G2 계약과 다르다")
    points={}
    for row in rows[1:]:
        if len(row)!=3 or row[0] not in axes or not re.fullmatch(r"[0-4]",row[1].strip()) or not row[2].strip() or row[0] in points: die(2,f"{path.name} CSV 형식이 G2 계약과 다르다")
        points[row[0]]=int(row[1])
    if set(points)!=set(axes): die(2,f"{path.name}에 축 점수가 비어 있다")
    independent.append(points)
adopted=[]
for index,axis in enumerate(axes):
    theirs=[points[axis] for points in independent]
    if any(abs(self_scores[index]-point)>=2 for point in theirs): die(1,f"{axis}의 자기·독립 채점 차이가 2점 이상이다 — 앵커를 보강해야 한다")
    adopted.append(min([self_scores[index],*theirs]))
score_min,score_sum=min(adopted),sum(adopted)
reverse={axis:[] for axis in axes}; reverse_tables=0
for i,line in enumerate(lines):
    if "|" not in line: continue
    head=cells(line); cols={axis:head.index(axis) for axis in axes if axis in head}
    if len(cols)!=len(axes): continue
    reverse_tables+=1
    for row in lines[i+1:]:
        if "|" not in row: break
        values=cells(row)
        if values and re.fullmatch(r":?-{3,}:?",values[0] or "-"): continue
        for axis,pos in cols.items():
            if pos<len(values) and re.fullmatch(r"[0-4]",values[pos]): reverse[axis].append(int(values[pos]))
if not reverse_tables: die(2,"rubric.md에 레퍼런스 역방향 채점 표가 없다")
for axis,values in reverse.items():
    if not any(value>=3 for value in values): die(1,f"{axis}는 어떤 레퍼런스도 3점에 도달하지 못한다")
if len(set(adopted))==1: die(1,"최종 축 점수 분산이 0이다 — 총평 복사 의심")
counter=read(run/"counterexample.md"); counter_scores={}
for axis in axes:
    if match:=re.search(r"(?m)^\s*"+re.escape(axis)+r"\s*(?:점수)?\s*[:=]\s*([0-4])\b",counter): counter_scores[axis]=int(match.group(1))
if len(counter_scores)!=len(axes):
    match=re.search(r"(?im)^\s*(?:scores|점수)\s*[:=]\s*([0-4](?:\s*,\s*[0-4]){%d})\s*$"%(len(axes)-1),counter)
    if match: counter_scores=dict(zip(axes,map(int,re.findall(r"[0-4]",match.group(1)))))
if len(counter_scores)!=len(axes):
    for i,line in enumerate(counter.splitlines()):
        if "|" not in line: continue
        head=cells(line); cols={axis:head.index(axis) for axis in axes if axis in head}
        if len(cols)!=len(axes): continue
        for row in counter.splitlines()[i+1:]:
            if "|" not in row: break
            values=cells(row)
            if all(pos<len(values) and re.fullmatch(r"[0-4]",values[pos]) for pos in cols.values()): counter_scores={axis:int(values[pos]) for axis,pos in cols.items()}; break
        if len(counter_scores)==len(axes): break
if len(counter_scores)!=len(axes): die(2,"counterexample.md에 축별 0~4 반례 점수가 없다")
if min(counter_scores.values())>=minimum and sum(counter_scores.values())>=required_sum: die(1,"반례가 봉인 판정식을 통과한다 — 루브릭 사각이다")
anchors={}
try:
    for no,raw in enumerate(read(run/"anchors.jsonl").splitlines(),1):
        if raw.strip():
            item=json.loads(raw); aid=item.get("aid")
            if not isinstance(aid,str) or aid in anchors: die(2,f"anchors.jsonl {no}행 aid 계약 위반")
            anchors[aid]=item
except (json.JSONDecodeError,TypeError) as exc: die(2,f"anchors.jsonl 계약 오류: {exc}")
for axis,body in sections.items():
    aids=set(re.findall(r"\b(R-[A-Z]+#[0-9]+)\b",body))
    if not aids: die(2,f"{axis}에 앵커 증거가 없다")
    if any(aid not in anchors or anchors[aid].get("active") is not True or anchors[aid].get("verdict")!="CONFIRMED" for aid in aids): die(2,f"{axis}에 미확정 앵커가 있다")
if score_min<minimum or score_sum<required_sum: die(1,"독립 채점의 보수 점수가 봉인 합격선에 못 미친다")

# G2 행은 모든 검사와 봉인 판정이 성공한 뒤에만, 같은 G2 round를 교체해 기록한다.
g2row=["G2","G2",*map(str,adopted),str(score_min),str(score_sum),"PASS","G2-ADOPTED","독립 채점의 낮은 점수 채택"]
out=io.StringIO(); writer=csv.writer(out,delimiter="\t",lineterminator="\n"); writer.writerow(header)
for row in score_rows[1:]:
    if row[0]!="G2": writer.writerow(row)
writer.writerow(g2row)
try:
    atomic_write(run/"scores.tsv",out.getvalue())
except OSError as exc: die(2,f"G2 점수 기록 실패: {exc}")
print("PASS")
PY
