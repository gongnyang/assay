#!/usr/bin/env bash
# reach-gate.sh — Reach 수집물을 축2가 소비해도 되는지 한 번에 판정한다.
# 원문에 없는 요약·재현 불가 스냅샷을 여기서 막아야 루브릭이 근거를 가장하지 않는다.
#
# usage: reach-gate.sh <run-dir>
#   예:   reach-gate.sh .assay/20260730-api
#
# 종료코드: 0=계약 통과, 1=수집 부족, 2=스키마·증거 계약 위반, 3=python3 환경 미비
set -euo pipefail
. "$(dirname "$0")/_common.sh"
need_python3
[ $# -eq 1 ] || usage_die "usage: $0 <run-dir>"
RUN=$1
seal_verify "$RUN/reach.conf"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# JSONL·해시·유니코드 리터럴 대조를 bash 문자열 처리에 맡기지 않는다.
python3 - "$RUN" "$SCRIPT_DIR/../contracts/channels.yml" <<'PY'
import csv, datetime as dt, hashlib, json, os, re, sys, unicodedata
from decimal import Decimal, InvalidOperation
from pathlib import Path

class Bad(Exception): pass
def bad(s): raise Bad(s)
def string(x, n, empty=False):
    if not isinstance(x, str) or (not empty and not x.strip()): bad(f"{n}: 비어 있지 않은 문자열이어야 함")
    return x
def fields(o, ks, n):
    m=[k for k in ks if k not in o]
    if m: bad(f"{n}: 필수 필드 없음: {', '.join(m)}")
def jsonl(p, n):
    if not p.is_file(): bad(f"{n} 없음: {p}")
    try:
        out=[]
        for i,line in enumerate(p.read_text(encoding='utf-8').splitlines(),1):
            if line.strip():
                try: row=json.loads(line)
                except json.JSONDecodeError as e: bad(f"{n}:{i}: JSON 파싱 실패: {e.msg}")
                if not isinstance(row,dict): bad(f"{n}:{i}: JSON 객체 한 건이어야 함")
                out.append((i,row))
    except UnicodeDecodeError: bad(f"{n}: UTF-8 파일이어야 함")
    if not out: bad(f"{n}: 비어 있음")
    return out
def config(p):
    if not p.is_file(): bad("reach.conf 없음 — reach-init.sh 먼저 실행하라")
    d={}
    try: lines=p.read_text(encoding='utf-8').splitlines()
    except UnicodeDecodeError: bad("reach.conf: UTF-8 파일이어야 함")
    for i,line in enumerate(lines,1):
        line=line.strip()
        if line and not line.startswith('#'):
            if '=' not in line: bad(f"reach.conf:{i}: KEY=VALUE 형식이 아님")
            k,v=line.split('=',1)
            if not re.fullmatch(r'[A-Z][A-Z0-9_]*',k) or k in d: bad(f"reach.conf:{i}: 키가 잘못되었거나 중복됨")
            d[k]=v
    ks=('MIN_SOURCES','MIN_PRIMARY','POC_MAX_PCT','MANUAL_MAX_PCT')
    if 'QUESTION_SHA256' not in d or not re.fullmatch(r'[0-9a-f]{64}',d['QUESTION_SHA256']) or any(k not in d for k in ks) or any(not re.fullmatch(r'[1-9][0-9]*',d[k]) for k in ks[:2]) or any(not re.fullmatch(r'(?:0|[1-9][0-9]*)(?:\.[0-9]+)?',d[k]) for k in ks[2:]): bad("reach.conf: 질문 해시·최소 수집·비율 봉인값이 필요")
    try: d.update({k:Decimal(d[k]) for k in ks[2:]})
    except InvalidOperation: bad("reach.conf: 비율 상한은 숫자여야 함")
    d.update({k:int(d[k]) for k in ks[:2]})
    if any(d[k]<0 or d[k]>100 for k in ks[2:]): bad("reach.conf: 비율 상한은 0~100이어야 함")
    return d
def axes(p):
    if not p.is_file(): bad("axes.tsv 없음 — reach-fanout.sh 먼저 실행하라")
    try: a={unicodedata.normalize('NFC',x.split('\t',1)[0].strip()) for x in p.read_text(encoding='utf-8').splitlines() if x.strip() and not x.lstrip().startswith('#')}
    except UnicodeDecodeError: bad("axes.tsv: UTF-8 파일이어야 함")
    a.discard('')
    if not a: bad("axes.tsv: 축이 하나도 없음")
    return a
def channels(p):
    if not p.is_file(): bad(f"channels.yml 없음: {p}")
    try: lines=p.read_text(encoding='utf-8').splitlines()
    except UnicodeDecodeError: bad("channels.yml: UTF-8 파일이어야 함")
    out={}; now=None; block=False
    for raw in lines:
        line=raw.split('#',1)[0].rstrip(); m=re.match(r'^\s*-\s*name\s*:\s*(.+?)\s*$',line)
        if m:
            now=m.group(1).strip().strip("'\""); block=False
            if not now or now in out: bad("channels.yml: channel name 중복/공란")
            out[now]=set(); continue
        if now is None: continue
        m=re.match(r'^\s*backends\s*:\s*\[(.*?)\]\s*$',line)
        if m: out[now].update(v.strip().strip("'\"") for v in m.group(1).split(',') if v.strip()); block=False; continue
        if re.match(r'^\s*backends\s*:\s*$',line): block=True; continue
        m=re.match(r'^\s*-\s*(.+?)\s*$',line)
        if block and m: out[now].add(m.group(1).strip().strip("'\"")); continue
        if line.strip() and not line.startswith((' ','\t')): block=False
    if not out: bad("channels.yml: '- name:' 채널 선언이 없음")
    return out
def snapshot(run, value, n):
    q=Path(string(value,n+'.snapshot'))
    if q.is_absolute() or '..' in q.parts: bad(f"{n}.snapshot: 런 밖 경로 금지")
    p=(run/q).resolve()
    try: p.relative_to(run.resolve())
    except ValueError: bad(f"{n}.snapshot: 런 밖 경로 금지")
    if not p.is_file(): bad(f"{n}.snapshot: 스냅샷 없음")
    return p
def require_literal(haystack, excerpt, n, where):
    if excerpt in haystack: return
    if unicodedata.normalize('NFC',excerpt) in unicodedata.normalize('NFC',haystack):
        print(f"!! 경고: {n}: excerpt가 {where}에는 NFC 정규화로만 일치한다.",file=sys.stderr)
        bad(f"{n}: excerpt는 {where}에 리터럴 부분문자열이어야 함")
    bad(f"{n}: excerpt가 {where}에 없음")
def metric_cells(run):
    d=run/'metrics'; out=set()
    if not d.is_dir(): return out
    for p in sorted(d.glob('*.tsv')):
        proof=p.with_name(p.name+'.prov')
        try:
            record=json.loads(proof.read_text(encoding='utf-8'))
            if not isinstance(record,dict) or record.get('tsv_sha256')!=hashlib.sha256(p.read_bytes()).hexdigest(): continue
        except (OSError,UnicodeDecodeError,json.JSONDecodeError):
            continue
        try:
            with p.open(encoding='utf-8',newline='') as f:
                for row in csv.reader(f,delimiter='\t'): out.update(unicodedata.normalize('NFC',v) for v in row)
        except (OSError,UnicodeDecodeError,csv.Error) as e: bad(f"metrics/{p.name}: TSV 읽기 실패: {e}")
    return out
def question_hash(run, conf):
    p=run/'question.md'
    if not p.is_file(): bad("question.md 없음 — reach-init.sh 먼저 실행하라")
    actual=hashlib.sha256(p.read_bytes()).hexdigest()
    if actual!=conf['QUESTION_SHA256']: bad("question.md sha256이 reach.conf의 QUESTION_SHA256과 다름")
    return actual
def write_receipt(run, question, conf, usable, primary, confirmed):
    receipt=run/'reach-gate.receipt'; temporary=receipt.with_name('.'+receipt.name+'.tmp')
    data={'ts':dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z'),'question_sha256':question,'reach_conf_sha256':hashlib.sha256((run/'reach.conf').read_bytes()).hexdigest(),'sources_sha256':hashlib.sha256((run/'sources.jsonl').read_bytes()).hexdigest(),'anchors_sha256':hashlib.sha256((run/'anchors.jsonl').read_bytes()).hexdigest(),'usable':usable,'primary':primary,'confirmed_anchors':confirmed}
    try:
        with temporary.open('w',encoding='utf-8',newline='\n') as f: json.dump(data,f,ensure_ascii=False,separators=(',',':')); f.write('\n')
        os.replace(temporary,receipt)
    except OSError:
        try: temporary.unlink()
        except OSError: pass
        raise

def main():
    run=Path(sys.argv[1])
    if not run.is_dir(): bad(f"런 디렉터리 없음: {run}")
    conf, ax, ch=config(run/'reach.conf'), axes(run/'axes.tsv'), channels(Path(sys.argv[2]))
    question=question_hash(run,conf)
    src={}; good=[]; ranks={'high':3,'med':2,'poc':1}; ladders={f'L{i}' for i in range(5)}
    for no,s in jsonl(run/'sources.jsonl','sources.jsonl'):
        n=f'sources.jsonl:{no}'; fields(s,('sid','worker_id','axis','url','title','channel','ladder','backend','fetched_at','observed_at','valid_at','status','attempts','ladder_stopped_at','untried_ladder','kind','confidence','access_note'),n)
        if set(s)-{'sid','worker_id','axis','url','title','channel','ladder','backend','fetched_at','observed_at','valid_at','status','attempts','ladder_stopped_at','untried_ladder','kind','confidence','snapshot','sha256','access_note'}: bad(f"{n}: 선언되지 않은 필드")
        sid=string(s['sid'],n+'.sid')
        if not re.fullmatch(r'R-[A-Z]+',sid) or sid in src: bad(f"{n}.sid: 유일한 R- 대문자 ID 필요")
        string(s['worker_id'],n+'.worker_id')
        if unicodedata.normalize('NFC',string(s['axis'],n+'.axis')) not in ax: bad(f"{n}.axis: axes.tsv에 없음")
        channel,backend=string(s['channel'],n+'.channel'),string(s['backend'],n+'.backend')
        if channel not in ch or backend not in ch[channel]: bad(f"{n}: channels.yml에 없는 channel/backend 조합")
        if s['ladder'] not in ladders or s['status'] not in {'ok','manual','blocked','auth_required','not_found','timeout'}: bad(f"{n}: ladder/status 어휘 위반")
        if type(s['attempts']) is not int or s['attempts']<1 or type(s['ladder_stopped_at']) is not int or not 0<=s['ladder_stopped_at']<=4: bad(f"{n}: attempts/ladder_stopped_at 범위 위반")
        if not isinstance(s['untried_ladder'],list) or any(x not in ladders for x in s['untried_ladder']): bad(f"{n}.untried_ladder: L0~L4 배열 필요")
        if s['status'] not in {'ok','manual'} and s['untried_ladder']: bad(f"{n}: untried_ladder가 남은 실패 확정")
        if s['kind'] not in {'primary','secondary','marketing'} or s['confidence'] not in ranks: bad(f"{n}: kind/confidence 어휘 위반")
        if s['status']=='manual' and s['confidence']=='high': bad(f"{n}: manual confidence 상한은 med")
        for k in ('url','title','fetched_at','observed_at','valid_at'): string(s[k],n+'.'+k)
        if not isinstance(s['access_note'],str): bad(f"{n}.access_note: 문자열이어야 함")
        src[sid]=s
        if s['status'] in {'ok','manual'}:
            fields(s,('snapshot','sha256'),n); p=snapshot(run,s['snapshot'],n); h=hashlib.sha256(p.read_bytes()).hexdigest()
            if not isinstance(s['sha256'],str) or not re.fullmatch(r'[0-9a-f]{64}',s['sha256']) or h!=s['sha256']: bad(f"{n}: 스냅샷 sha256 불일치")
            s['_snapshot']=p; s['_snapshot_name']=Path(s['snapshot']).name; good.append(s)
    aids=set(); active=[]; cells=None
    for no,a in jsonl(run/'anchors.jsonl','anchors.jsonl'):
        n=f'anchors.jsonl:{no}'; fields(a,('aid','sid','kind','axis_hint','active','excerpt','locator','measured','measure','claim_type','confidence','verdict','refuted_by','captured_at'),n)
        if set(a)-{'aid','sid','kind','axis_hint','active','excerpt','locator','measured','measure','claim_type','confidence','verdict','refuted_by','captured_at'}: bad(f"{n}: 선언되지 않은 필드")
        aid,sid=string(a['aid'],n+'.aid'),string(a['sid'],n+'.sid')
        if not re.fullmatch(r'R-[A-Z]+#[0-9]{2}',aid) or not aid.startswith(sid+'#') or aid in aids: bad(f"{n}.aid: 유일한 <sid>#<nn> 필요")
        aids.add(aid)
        if sid not in src or src[sid]['status'] not in {'ok','manual'}: bad(f"{n}: 앵커 원천 소스가 없거나 접근 실패")
        s=src[sid]
        if a['kind'] not in {'quote','metric','snippet','crop','dimension'} or a['claim_type'] not in {'verified','vendor-claim','executable'} or a['confidence'] not in ranks: bad(f"{n}: kind/claim_type/confidence 어휘 위반")
        if ranks[a['confidence']]>ranks[s['confidence']]: bad(f"{n}: 소스보다 높은 confidence 금지")
        if type(a['active']) is not bool or type(a['measured']) is not bool or a['verdict'] not in {'CONFIRMED','UNVERIFIED','REFUTED'}: bad(f"{n}: active/measured/verdict 계약 위반")
        if a['verdict']!='CONFIRMED' and a['active']: bad(f"{n}: UNVERIFIED/REFUTED는 active:false여야 함")
        excerpt=string(a['excerpt'],n+'.excerpt'); string(a['axis_hint'],n+'.axis_hint'); string(a['locator'],n+'.locator')
        if not isinstance(a['measure'],str) or not isinstance(a['refuted_by'],str): bad(f"{n}.measure/refuted_by: 문자열이어야 함")
        string(a['captured_at'],n+'.captured_at')
        try: body=s['_snapshot'].read_text(encoding='utf-8')
        except UnicodeDecodeError: bad(f"{n}: excerpt 대조 가능한 UTF-8 스냅샷 필요")
        require_literal(body,excerpt,n,'스냅샷 원문')
        locator_match=re.fullmatch(r'(.+):(.+)',a['locator'])
        if locator_match:
            locator_path,locator_detail=locator_match.groups()
            snapshot_names={s['_snapshot'].name,s['_snapshot_name']}
            if locator_path not in snapshot_names and Path(locator_path).name not in snapshot_names:
                bad(f"{n}: locator 경로가 해당 스냅샷 파일과 일치하지 않음")
            if re.fullmatch(r'[1-9][0-9]*',locator_detail):
                line_no=int(locator_detail); lines=body.splitlines()
                if line_no>len(lines): bad(f"{n}: locator 줄 {line_no}이 스냅샷 범위를 벗어남")
                require_literal(lines[line_no-1],excerpt,n,f"locator 줄 {line_no}")
        if s['kind']=='marketing' and (a['claim_type']!='vendor-claim' or a['measured']): bad(f"{n}: marketing은 vendor-claim 비자동검증만 가능")
        if a['measured'] or a['claim_type']=='executable':
            if not a['measure'].strip(): bad(f"{n}: measured/executable 앵커에는 measure 명령 필요")
            if cells is None: cells=metric_cells(run)
            if a['measured'] and unicodedata.normalize('NFC',excerpt) not in cells: bad(f"{n}: provenance가 검증된 metrics/*.tsv 실제 셀과 값이 불일치")
            if a['claim_type']=='executable' and not cells: bad(f"{n}: provenance가 검증된 executable 실행 증거(metrics/) 없음")
        if a['active'] and a['verdict']=='CONFIRMED': active.append(a)
    manual=sum(s['status']=='manual' for s in good); primary=sum(s['kind']=='primary' for s in good); poc=sum(a['confidence']=='poc' for a in active); fail=[]
    if len(good)<conf['MIN_SOURCES']: fail.append(f"usable {len(good)} < {conf['MIN_SOURCES']}")
    if primary<conf['MIN_PRIMARY']: fail.append(f"primary {primary} < {conf['MIN_PRIMARY']}")
    if good and Decimal(manual)*100>conf['MANUAL_MAX_PCT']*len(good): fail.append(f"manual {manual}/{len(good)} > {conf['MANUAL_MAX_PCT']}%")
    if active and Decimal(poc)*100>conf['POC_MAX_PCT']*len(active): fail.append(f"poc {poc}/{len(active)} > {conf['POC_MAX_PCT']}%")
    confirmed_sids={a['sid'] for a in active}
    if len(confirmed_sids)<conf['MIN_SOURCES']: fail.append(f"confirmed active sid {len(confirmed_sids)} < {conf['MIN_SOURCES']}")
    if fail: print('!! 수집 하한 미달: '+'; '.join(fail),file=sys.stderr); return 1
    write_receipt(run,question,conf,len(good),primary,len(active))
    print(f"Reach 게이트 통과: usable={len(good)}, primary={primary}, active-confirmed-anchor={len(active)}")
    return 0
try: sys.exit(main())
except (Bad,OSError) as e: print(f"!! Reach 계약 위반: {e}",file=sys.stderr); sys.exit(2)
PY
