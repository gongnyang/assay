#!/usr/bin/env bash
# bench-log.sh — 앵커·파레토·해시 체인이 확인된 라운드 하나를 기록한다.
# usage: bench-log.sh <run-dir> <round> <axis-targeted> <scores-csv> [note] [--simplify]
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3
[ "$#" -ge 4 ] || usage_die "usage: $0 <run-dir> <round> <axis-targeted> <scores-csv> [note] [--simplify]"
seal_verify "$1/gate.conf"
PYTHONPATH="$(dirname "$0")${PYTHONPATH:+:$PYTHONPATH}" exec python3 - "$@" <<'PY'
import csv, datetime as dt, glob, hashlib, json, os, re, shutil, subprocess, sys, unicodedata; from pathlib import Path; from _pylib import append_record, atomic_write, verify_chain
A={"BASE","KEEP","SIMPLIFY"}
def die(m,c=2): print("!! "+m,file=sys.stderr); raise SystemExit(c)
def checked(f,*a):
 try: return f(*a)
 except (OSError,TypeError,ValueError) as e: die(str(e).replace(roundfile,"rounds.jsonl"))
def write_scores(p,text): checked(lambda: atomic_write(p,Path(p).read_text(encoding="utf-8")+text))
def conf(p):
 try: src=open(p,encoding="utf-8")
 except OSError: die("gate.conf 없음 — bench-init.sh 먼저.")
 d={}
 for no,raw in enumerate(src,1):
  line=raw.rstrip("\n")
  if not line or line.startswith("#"): continue
  if "=" not in line: die(f"gate.conf:{no}: key=value 형식이 아닙니다.")
  k,v=line.split("=",1)
  if k in d or not k or any(c in k+v for c in "\t\r\n"): die(f"gate.conf:{no}: 봉인 파일이 손상되었습니다.")
  d[k]=v
 req={"AXES","N_AXES","MIN_REQ","SUM_REQ","MAX_SCORE","STALL_LIMIT","TARGET_DIR","READONLY"}
 if req-d.keys(): die("gate.conf의 필수 봉인 필드가 없습니다.")
 try: nums=[int(d[k]) for k in ("N_AXES","MIN_REQ","SUM_REQ","MAX_SCORE","STALL_LIMIT")]
 except ValueError: die("gate.conf 수치 필드가 정수가 아닙니다.")
 axes=d["AXES"].split(","); ok=len(axes)==nums[0] and 3<=len(axes)<=7 and len(set(axes))==len(axes) and nums[3]==4
 if not ok or any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*",x) for x in axes): die("gate.conf 축 봉인이 손상되었습니다.")
 return axes,*nums,d["TARGET_DIR"]
def scored(rs): return [r for r in rs if "event" not in r and isinstance(r.get("round"),str) and isinstance(r.get("verdict"),str)]
def row(r,axes):
 s=r.get("scores"); req=("round","axis","min","sum","gate","verdict","note")
 if not isinstance(s,list) or len(s)!=len(axes) or any(type(x)is not int for x in s) or any(not isinstance(r.get(k),str if k in {"round","axis","gate","verdict","note"} else int) for k in req): die("rounds.jsonl 점수 행이 손상되었습니다.")
 return [r["round"],r["axis"],*map(str,s),str(r["min"]),str(r["sum"]),r["gate"],r["verdict"],r["note"]]
def stall_row(r,axes):
 req=("round","axis","min","sum","gate","reason")
 if (r.get("event")!="STALL" or r.get("verdict")!="STALL" or type(r.get("count")) is not int or r["count"]<1
     or not isinstance(r.get("scores"),list) or len(r["scores"])!=len(axes) or any(type(x)is not int for x in r["scores"])
     or any(not isinstance(r.get(k),str if k in {"round","axis","gate","reason"} else int) for k in req)):
  die("rounds.jsonl STALL 행이 손상되었습니다.")
 return [r["round"],r["axis"],*map(str,r["scores"]),str(r["min"]),str(r["sum"]),r["gate"],"STALL",r["reason"]]
def scores_ok(p,rs,axes,rid):
 try: table=list(csv.reader(open(p,encoding="utf-8"),delimiter="\t"))
 except (OSError,csv.Error) as e: die(f"scores.tsv를 읽을 수 없습니다: {e}")
 head=["round","axis",*axes,"min","sum","gate","verdict","note"]
 if not table or table[0]!=head: die("scores.tsv 헤더가 gate.conf와 일치하지 않습니다.")
 shown=[]
 for no,x in enumerate(table[1:],2):
  if len(x)!=len(head) or not x[0]: die(f"scores.tsv:{no}: 행 형식이 잘못되었습니다.")
  if x[0]==rid: die(f"round {rid}은 이미 기록되었습니다.")
  if x[-2]!="G2-ADOPTED": shown.append(x)
 expected=[]
 for r in rs:
  if r.get("event")=="STALL": expected.append(stall_row(r,axes))
  elif "event" not in r and isinstance(r.get("round"),str) and isinstance(r.get("verdict"),str): expected.append(row(r,axes))
 if shown!=expected: die("scores.tsv와 체인 검증된 rounds.jsonl 점수 행이 일치하지 않습니다.")
def now(): return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")
def state(target,run,rid):
 target,run=os.path.realpath(target),os.path.realpath(run); os.path.isdir(target) or die("TARGET_DIR이 존재하지 않습니다.")
 try: git=subprocess.run(["git","-C",target,"rev-parse","--show-toplevel"],text=True,capture_output=True)
 except FileNotFoundError:
  if os.path.exists(os.path.join(target,".git")): die("git이 없어 워킹트리 복원 증거를 기록할 수 없습니다.",3)
  git=None
 if git is not None and git.returncode==0:
  root=os.path.realpath(git.stdout.strip())
  if os.path.commonpath([target,root])==target:
   try:
    commit=subprocess.run(["git","-C",root,"rev-parse","HEAD"],text=True,capture_output=True,check=True).stdout.strip(); tree=subprocess.run(["git","-C",root,"rev-parse","HEAD^{tree}"],text=True,capture_output=True,check=True).stdout.strip()
   except subprocess.CalledProcessError: die("git HEAD/tree 상태를 읽을 수 없습니다.")
   return {"kind":"git","root":root,"commit":commit,"tree_hash":tree}
 snap=os.path.join(run,"rounds",rid)
 if os.path.exists(snap): die("동일 라운드의 스냅샷이 이미 있습니다.")
 rel=os.path.relpath(run,target); inside=rel!=".." and not rel.startswith(".."+os.sep); parts=rel.split(os.sep)
 def ignore(base,names):
  if not inside:return []
  here=os.path.relpath(base,target); here=[] if here=="." else here.split(os.sep)
  return [parts[len(here)]] if here==parts[:len(here)] and len(here)<len(parts) and parts[len(here)] in names else []
 try: os.makedirs(os.path.dirname(snap),exist_ok=True); shutil.copytree(target,snap,symlinks=True,ignore=ignore)
 except (OSError,shutil.Error) as e: die(f"TARGET_DIR 전체 스냅샷 생성 실패: {e}")
 return {"kind":"snapshot","root":target,"snapshot":os.path.join("rounds",rid)}
def proven(p):
 try:
  lines=open(p+".prov",encoding="utf-8").read().splitlines(); x=json.loads(lines[0]) if len(lines)==1 and lines[0].strip() else None
  return isinstance(x,dict) and isinstance(x.get("instrument"),str) and isinstance(x.get("argv"),list) and isinstance(x.get("ts"),str) and isinstance(x.get("rows"),int) and isinstance(x.get("tsv_sha256"),str) and x["tsv_sha256"]==hashlib.sha256(open(p,"rb").read()).hexdigest()
 except (OSError,UnicodeError,json.JSONDecodeError): return False
args=sys.argv[1:]; runarg,rid,axis,rawscores=args[:4]; note=""; simplify=False
for x in args[4:]:
 if x=="--simplify":
  if simplify: die("--simplify를 두 번 쓸 수 없습니다.",64)
  simplify=True
 elif note: die("note는 하나만 지정할 수 있습니다.",64)
 else: note=x
if any(any(c in x for c in "\t\r\n") for x in (rid,axis,note)) or not (run:=os.path.abspath(runarg)): die("round·axis·note에 탭/개행을 사용할 수 없습니다.")
gatefile,scoresfile,roundfile=(os.path.join(run,x) for x in ("gate.conf","scores.tsv","rounds.jsonl"))
if not os.path.isfile(scoresfile) or not os.path.isfile(roundfile): die("scores.tsv·rounds.jsonl이 필요합니다 — bench-init.sh 먼저.")
axes,naxes,minreq,sumreq,maxscore,stalllimit,target=conf(gatefile)
if axis!="-" and axis not in axes: die("axis-targeted가 봉인된 축에 없습니다.")
try: scores=[int(x) for x in rawscores.split(",")]
except ValueError: die("점수는 0~4 정수여야 합니다.")
if len(scores)!=naxes or any(x<0 or x>maxscore for x in scores): die("축 개수 또는 점수 범위가 잘못되었습니다.")
if not os.path.isfile(anchor:=os.path.join(run,"anchors",rid+".md")): die("앵커 파일 없음: "+anchor)
sid=re.compile(r"(?<![\w-])R-[A-Z]+(?![A-Z0-9-])"); fl=re.compile(r"(?:^|(?<![\w/]))(?:[^\s:]+/)*[^\s:]+\.(?:md|py|sh|mjs|js):[0-9]+"); quote=re.compile(r'"[^"\n]+"|“[^”\n]+”|「[^」\n]+」')
lines=open(anchor,encoding="utf-8").read().splitlines(); missing=[]
for a in axes:
 line=next((x for x in lines if unicodedata.normalize("NFC",x).startswith(unicodedata.normalize("NFC",a+":"))),None)
 if line is None: missing.append(a)
 elif not(sid.search(line) or "[실측]" in line or fl.search(line) or quote.search(line)): missing.append(a+"(무인용)")
if missing: die("앵커 미비: "+" ".join(missing)+" — 인정 인용: R-A · [실측] · 유니코드파일.md:줄 · 직접 인용")
records=checked(verify_chain,roundfile); scores_ok(scoresfile,records,axes,rid); normal=scored(records)
if normal and normal[-1].get("verdict")=="REVERT":
 reject=normal[-1]; at=records.index(reject); restored=any(r.get("event")=="revert" and r.get("round")==reject["round"] and r.get("restored") is True and r.get("tree_hash") for r in records[at+1:])
 if not restored: die("되돌리지 않은 "+reject["round"]+" REVERT 뒤에는 bench-revert.sh를 먼저 실행해야 합니다.")
previous=next((r for r in reversed(normal) if r.get("verdict") in A),None); minimum,total=min(scores),sum(scores); verdict,delta,complexity="BASE","baseline",None
if previous is None:
 if axis!="-" or simplify: die("첫 라운드는 axis-targeted '-'인 BASE여야 하며 --simplify를 쓸 수 없습니다.")
else:
 oldround,old,oldsum=previous.get("round"),previous.get("scores"),previous.get("sum")
 if not isinstance(old,list) or not isinstance(oldsum,int): die("직전 채택 라운드가 손상되었습니다.")
 dropped=[a for a,n,o in zip(axes,scores,old) if n<o]
 if simplify and (dropped or total!=oldsum): die("--simplify는 전 축 유지와 총점 동일일 때만 쓸 수 있습니다.")
 if dropped: verdict,delta="REVERT","하락: "+" ".join(dropped)+" — 파레토 위반"
 elif total>oldsum: verdict,delta="KEEP",f"sum {oldsum}->{total}"
 elif not simplify: verdict,delta="REVERT",f"sum 동일({oldsum}) — 단순화 증거가 아니면 기각"
 else:
  names={"lines":{"lines","line_count","loc","source_lines","md_lines"},"files":{"files","file_count"},"dependencies":{"dependencies","dependency_count","deps"}}; evidence=[]; up=False
  for p in sorted(glob.glob(os.path.join(run,"metrics","*.tsv"))):
   if not proven(p): continue
   try: rows=list(csv.DictReader(open(p,encoding="utf-8"),delimiter="\t"))
   except (OSError,csv.Error): continue
   before=next((x for x in rows if x.get("round")==oldround),None); after=next((x for x in rows if x.get("round")==rid),None)
   if before is None or after is None: continue
   change={}
   for name,aliases in names.items():
    field=next((x for x in before if x and x.strip().lower() in aliases),None)
    try: change[name]=[int(before[field]),int(after[field])] if field else None
    except (TypeError,ValueError): change[name]=None
   change={k:v for k,v in change.items() if v is not None}; up|=any(b>a for a,b in change.values())
   if change: evidence.append({"file":os.path.basename(p),"changes":change})
  if not evidence or up or not any(b<a for x in evidence for a,b in x["changes"].values()): die("--simplify에는 .tsv.prov 해시가 검증된 metrics TSV의 행수·파일수·의존성 수 감소 증거가 필요합니다.")
  verdict,delta,complexity="SIMPLIFY",f"sum 동일({oldsum}) + 복잡도 감소",{"before":oldround,"after":rid,"evidence":evidence}
word="PASS" if minimum>=minreq and total>=sumreq else "FAIL"; record={"round":rid,"ts":now(),"axis":axis,"axes":",".join(axes),"scores":scores,"min":minimum,"sum":total,"max":naxes*maxscore,"gate":word,"verdict":verdict,"delta":delta,"note":note,**({"complexity":complexity} if complexity else {})}
if verdict in A: record["state"]=state(target,run,rid)
write_scores(scoresfile,"\t".join(row(record,axes))+"\n")
checked(append_record,roundfile,records,record); stall=0
for r in scored(records): stall=stall+1 if r.get("verdict")=="REVERT" else 0 if r.get("verdict") in A else stall
if stall>=stalllimit:
 stop={"event":"STALL","round":rid,"axis":axis,"scores":scores,"min":minimum,"sum":total,"gate":word,"verdict":"STALL","count":stall,"reason":"REVERT 연속으로 루프를 멈춘다","ts":now()}
 write_scores(scoresfile,"\t".join(stall_row(stop,axes))+"\n")
 checked(append_record,roundfile,records,stop)
print(f"[{rid}] min={minimum} sum={total}/{naxes*maxscore} gate={word} verdict={verdict} ({delta})")
stall>=stalllimit and print(f"!! STALL 기록: REVERT {stall}연속 — 루프를 멈추고 결과물이 아니라 루브릭을 의심하라.")
raise SystemExit(1 if verdict=="REVERT" else 0)
PY
