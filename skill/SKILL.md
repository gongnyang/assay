---
name: assay
description: MUST USE when the user needs to collect multiple web sources, preserve source snapshots, verify literal evidence anchors, and turn those anchors into a sealed rubric and improvement loop; e.g. "레퍼런스 대비 채점", "근거를 모아 평가표로", "벤치마킹해서 합격선까지 개선", "품질 게이트", "assay". Also MUST USE when a result must be improved against independently checkable references, not merely described. NOT for: one-off fact lookup or ordinary web search, writing a report/translation/summary from already supplied material, publishing or login/cookie/API-key work, or a platform that has a more specific installed skill (use that skill first).
---

# assay — 근거 수집을 채점 기준으로 승격하는 2축 루프
한 줄 원칙: **웹에서 원문 근거를 수집·검증하고, 그 앵커가 만든 기준이 통과할 때까지만 개선한다.**
이 스킬은 두 축을 분리해 연결한다. Reach는 접근 이력과 검증된 앵커만 생산한다. Bench는 그 두 계약 파일 밖의 근거를 채점에 쓰지 않는다. 앵커 없는 축, 무측정 숫자, 미검증 축의 PASS는 금지다.

## 시작 전 고정

1. 개선 대상 하나, 그 대상이 봉사하는 소비처의 결정, 구동 질문을 정한다. 질문은 물음표로 끝나는 한 문장이고 소비처는 비어 있지 않아야 한다.
2. 대상 프로젝트 안에 런 디렉터리 `.assay/<run>/`를 잡는다. 에이전트 작업공간에는 런 산출물을 쓰지 않는다.
3. 합격선·축·readonly 범위·승격 계측 임계값은 개선 전에 봉인한다. 실패했을 때 합격선을 낮추지 않는다.
4. 실행기는 이 스킬의 `scripts/`를 사용한다. 예: `S=<skill-dir>/scripts`.

상세 규율은 필요한 경우에만 연다.

| 상황 | 먼저 읽을 파일 |
|---|---|
| 질문·축·수집·재검증 | `references/reach-protocol.md` |
| 차단·인증·사다리·환경 진단 | `references/access-ladder.md` |
| 축 유도·0~4 앵커·판정식 | `references/rubric-design.md` |
| 라운드·파레토·되돌림·정체 | `references/loop-protocol.md` |
| JSONL·TSV·exit code | `references/contracts.md` |
| 스킬·레포 계측기 | `references/instruments.md` |

## Reach — R0~R5

### R0. 질문을 봉인한다

`$S/reach-init.sh .assay/<run> <질문파일> <최소소스수> <poc상한%>`를 한 번 실행한다. 재실행으로 질문을 바꾸지 않는다. `reach.conf`가 이미 있으면 고친 뒤 새 런을 시작한다.

`질문파일` 예: `질문: 무엇을 검증할까?` / `소비처: 출시 승인`.

### R1. 축을 팬아웃한다

질문을 서로 다른 하위 질문 3~7개로 나누고, 축마다 수집 워커 하나를 둔다. 워커는 수집·스냅샷만 하며 신뢰도와 판정은 하지 않는다. 실행: `$S/reach-fanout.sh .assay/<run> <axes.tsv>`.

`axes.tsv` 예: `AX-1<TAB>하위 질문<TAB>3` (탭으로 구분한 3열).

각 워커의 반환물은 자기 축 ID, `sources.jsonl` 반환 경로, `contracts/sources.schema.json`에 맞는 행이다.

### R2. 고정 사다리로 접근한다

`$S/reach-fetch.sh .assay/<run> <url> <axis-id> [--channel <name>]`는 L0 공식 API → L1 위임 검색 → L2 공개 웹 → L3 리더 프록시 → L4 수동 제공 순서만 쓴다. 인증·페이월은 로그인으로 우회하지 않고 L4로 내린다. 모든 시도와 실패를 기록하며, 성공 본문은 `sources/<sid>.md` 스냅샷과 SHA-256 없이는 소스가 아니다.

### R3. 접합 계약을 통과시킨다

R2 수집 뒤 사람이 `anchors.jsonl`을 직접 작성한다. 형식은 `contracts/anchors.schema.json`이다.
예: `{"aid":"R-A#03","sid":"R-A","kind":"quote","axis_hint":"A2","active":true,"excerpt":"원문 스냅샷에 실제로 있는 문자열","locator":"R-A.md:§2","measured":false,"measure":"","claim_type":"verified","confidence":"high","verdict":"CONFIRMED","refuted_by":"","captured_at":"2026-07-30T04:03:40Z"}`.

실행: `$S/reach-gate.sh .assay/<run>`. 이것이 Bench 진입의 유일한 관문이며 `reach-gate.sh`가 스키마와 excerpt의 리터럴성을 검사한다. 실패한 접근 기록은 앵커로 바꾸지 않는다.

### R4. 다른 맥락에서 반박한다

`$S/reach-refute.sh .assay/<run>`로 수집자와 다른 워커가 원 URL을 다시 확인하게 한다. `CONFIRMED`만 근거이며 `UNVERIFIED`와 `REFUTED`는 루브릭에서 참조하지 않는다.

### R5. 측정값을 전제로 승격한다

`kind: metric`, `measured: true`, 재현 `measure` 명령을 가진 CONFIRMED 앵커는 점수 축이 아니라 봉인된 통과 전제다. `bench-init.sh`가 이를 `gate.conf`에 넣으며 루프 중 변경할 수 없다.

## Bench — S0~S4

### S0. 합격선을 먼저 봉인한다

`$S/bench-init.sh .assay/<run> A1,A2,A3,A4,A5 3 17 <readonly>`로 실행한다. `PASS ⟺ min(axis) ≥ M AND sum(axis) ≥ S`에서 최저 축 조건은 필수다.

### S2. 앵커가 있는 루브릭만 만든다

`contracts/rubric.template.md`를 `rubric.md`의 형식으로 쓴다. 각 축의 0·3·4는 `aid`를 명시하고 자동검증 축은 `measure:` 명령과 `metrics/` 출력이 필요하다. 세부 aid/sid 규칙은 `references/rubric-design.md`를 따른다. 검사: `$S/rubric-lint.sh .assay/<run>`.

전부 같은 점수를 받는 항목은 축이 아니라 전제 후보다. 레퍼런스 복제를 4점으로 정의하지 않는다.

### S3. 고치기 전에 베이스라인을 잰다

기록: `$S/bench-log.sh .assay/<run> R0 - 2,3,3,3,3 "베이스라인"`.

각 점수에는 `anchors/R0.md`의 실물 인용이 필요하다. 예: `B-DOC: <설명> (R-A#01)`. 점수·min·sum·게이트·판정은 사람이 계산하지 않는다.

### S4. 한 축씩 개선하고 되돌린다

가장 낮은 축 하나만 고친 뒤 다시 측정·인용한다. 하나라도 하락하면 REVERT이며 실제로 `$S/bench-revert.sh .assay/<run> <round>`를 실행해야 다음 기록을 할 수 있다. 동점은 복잡도 계측값이 감소한 `--simplify`일 때만 채택한다. REVERT가 3회 연속이면 결과물 대신 루브릭·축·전제를 진단하고 루프를 닫는다.

## 검증 게이트 — G1~G3

1. G1: `$S/measure-skill.sh <skill-dir> .assay/<run>` 또는 `$S/measure-repo.sh <repo-dir> .assay/<run>`가 봉인 임계값을 exit code로 판정하게 한다.
2. G2: `$S/g2-spawn.sh .assay/<run>`은 `contracts/g2-prompt.md`, `rubric.md`, 대상 스냅샷만 독립 채점자에게 준다. 개선 이력·자기점수·라운드 앵커를 주지 않는다.
3. G3: 반례 파일, 역방향 레퍼런스 채점, 독립점수 차이, 축별 증거를 `$S/verdict-gate.sh .assay/<run>`으로 다시 공격한다. PASS 문자열은 이 명령만 발급한다.

## 규모 분기

- 단건(축 3~4): R0~R3, S0~S4, G1을 실행한다. 앵커가 5개 이하일 때만 R4 자기 재검증을 허용하며, `reach-gate.sh`와 인용 의무는 생략하지 않는다.
- `reach-gate.sh`는 `refute.jsonl` 존재를 검사하지 않으므로 R4 생략은 감사자 책임이다.
- 본격(축 5개 이상): R0~R5와 G1~G3 전부를 실행한다.
- 루브릭 재사용: 새 대상의 소스를 R0~R4로 다시 모으고 기존 앵커의 CONFIRMED 상태를 확인한 뒤 S3부터 시작한다.
- 정성 축이 과반이면 규모와 무관하게 G2를 생략하지 않는다.

## 종료·실패 규약

모든 스크립트에서 0은 통과, 1은 산출물·앵커·축을 고친 뒤 재실행할 판정 실패, 2는 계약 위반, 3은 환경 미비, 64는 사용법 오류다. exit 1·2에 우회 경로는 없다. 접근 실패는 Bench가 판정하지 않으며, `reach-fetch.sh`의 전수 시도 기록만이 접근 불가의 근거다.

## 산출물

- `sources.jsonl` — 접근 이력·스냅샷·해시.
- `anchors.jsonl` — 확인된 인용·수치·스니펫만 담는 채점 재료.
- `gate.conf`, `rubric.md`, `scores.tsv`, `rounds.jsonl` — 봉인·루브릭·전 라운드 감사 이력.
- `metrics/`, `g2/`, `counterexample.md` — 계측·독립 채점·반례 증거.

이 스킬은 채널별 스크레이퍼, 자격증명 취득·저장, 모델 API 래퍼, 보고서 산문 합성을 제공하지 않는다. 결과는 근거가 붙은 판정과 재현 가능한 계약 파일이다.
