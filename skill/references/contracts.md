# 계약 파일 — sources · anchors · scores · rounds · 종료코드

축1과 축2의 파일 인터페이스 정본이다. 스크립트를 고치거나 런 파일을 작성·검토할 때 로드한다. 예시는 형식 설명일 뿐, 값을 요약·추정해서 채우는 허가가 아니다.

## 목차

1. [공통 규칙](#1-공통-규칙)
2. [sources.jsonl](#2-sourcesjsonl)
3. [anchors.jsonl](#3-anchorsjsonl)
4. [gate와 루브릭](#4-gate와-루브릭)
5. [scores와 rounds](#5-scores와-rounds)
6. [보조 산출물](#6-보조-산출물)
7. [exit-code 계약](#7-exit-code-계약)
8. [발행 전 수동 릴리스 체크](#8-발행-전-수동-릴리스-체크)
9. [위협 모델](#9-위협-모델)

## 1. 공통 규칙

- JSONL은 한 줄에 객체 하나다. 줄을 합치거나 주석을 넣지 않는다.
- 시간은 UTC ISO-8601, 해시는 파일 바이트의 SHA-256이다. `observed_at`은 수집한 시각, `valid_at`은 내용이 기준으로 삼는 시점이다.
- 문자열은 UTF-8이며 한글·직접 인용·유니코드를 그대로 보존한다. 비교는 정규화·번역 없이 Python 문자열 리터럴 부분문자열으로 한다.
- 축1은 `sources.jsonl`과 `anchors.jsonl`만 생산한다. 축2는 이 둘 밖의 앵커를 인정하지 않는다.
- `REFUTED` 행과 실패 소스 행은 감사 이력이므로 삭제하지 않는다. 소비 단계에서 제외한다.

## 2. sources.jsonl

한 행은 소스 한 건이며, 접근 이력이다.

```json
{"sid":"R-A","worker_id":"collector-1","axis":"AX-1","url":"https://example.test/source","title":"원문 제목","channel":"github","ladder":"L0","backend":"gh-api","fetched_at":"2026-07-30T04:02:11Z","observed_at":"2026-07-30T04:02:11Z","valid_at":"2026-07-30","status":"ok","attempts":1,"ladder_stopped_at":0,"untried_ladder":[],"kind":"primary","confidence":"high","snapshot":"sources/R-A.md","sha256":"<64 hex>","access_note":""}
```

| 필드 | 규칙 |
|---|---|
| `sid` | `R-` 뒤 대문자 하나 이상. 런에서 유일하다. |
| `worker_id` | 이 접근 이력을 남긴 담당 수집 워커 ID다. 비어 있을 수 없다. |
| `axis` | `axes.tsv`에 실재하는 축 ID다. |
| `url`, `title` | 원문 URL과 사람이 확인 가능한 제목이다. |
| `channel`, `ladder`, `backend` | `channels.yml`의 채널·백엔드와 L0~L4 중 실제 경로다. |
| `fetched_at`, `observed_at`, `valid_at` | 수집·관측·내용 유효 시점을 혼동하지 않는다. |
| `status` | `ok`, `manual`, `blocked`, `auth_required`, `not_found`, `timeout` 중 하나다. `ok`·`manual` 외에는 앵커 원천이 아니다. |
| `attempts`, `ladder_stopped_at`, `untried_ladder` | 시도 횟수·종료 단·미시도 배열이다. 실패 상태의 미시도 배열은 비어야 한다. |
| `kind` | `primary`, `secondary`, `marketing` 중 하나다. |
| `confidence` | `high`, `med`, `poc` 중 하나다. manual은 `med`를 넘지 못한다. |
| `snapshot`, `sha256` | `ok`·`manual`이면 필수. 런 기준 상대 경로와 재계산 가능한 해시다. |
| `access_note` | 접근 예외·manual 출처를 짧게 설명하되 자격증명을 넣지 않는다. |

`reach-gate.sh`는 최소 소스·primary 하한, 스냅샷 존재, SHA-256, poc/manual 비율을 검사한다. 스냅샷이 없거나 해시가 다른 소스는 없는 소스다.

## 3. anchors.jsonl

한 행은 루브릭이 지목할 수 있는 실물 한 조각이다.

```json
{"aid":"R-A#03","sid":"R-A","kind":"quote","axis_hint":"A2","active":true,"excerpt":"원문 스냅샷에 실제로 있는 문자열","locator":"R-A.md:§2","measured":false,"measure":"","claim_type":"verified","confidence":"high","verdict":"CONFIRMED","refuted_by":"","captured_at":"2026-07-30T04:03:40Z"}
```

| 필드 | 규칙 |
|---|---|
| `aid` | `<sid>#<nn>`. `rubric.md`의 0·3·4 레벨이 이 ID를 참조한다. |
| `sid` | 실재하는 sources 행을 가리킨다. |
| `kind` | `quote`, `metric`, `snippet`, `crop`, `dimension`만 허용한다. |
| `axis_hint` | 수집 때의 후보 축이다. 루브릭의 최종 축 배정을 대신하지 않는다. |
| `active` | REFUTED면 `false`; 행은 남긴다. |
| `excerpt` | 해당 스냅샷에 있는 리터럴 부분문자열이다. 말줄임·번역·정규화·요약은 금지다. |
| `locator` | 파일:줄, §번호, bbox, 타임코드 중 하나다. 빈 값은 불가다. `<경로>:<나머지>` 형식이면 나머지 종류와 무관하게 경로부는 해당 스냅샷의 basename 또는 실제 파일명과 일치해야 한다. 나머지가 양의 줄 번호일 때만 그 줄의 리터럴 인용도 대조한다. |
| `measured`, `measure` | `true`면 재현 명령과 `metrics/*.tsv` 실제 셀이 모두 필수다. |
| `claim_type` | `verified`, `vendor-claim`, `executable` 중 하나다. executable은 실행 증거가 필요하다. |
| `confidence` | 소스 신뢰도보다 높일 수 없다. |
| `verdict`, `refuted_by` | `CONFIRMED`, `UNVERIFIED`, `REFUTED` 중 하나와 반증 출처다. 뒤 둘은 루브릭 참조 불가다. |
| `captured_at` | 앵커를 기록한 UTC 시각이다. |

marketing 소스의 앵커는 `vendor-claim`이어야 하고 자동검증 축에는 쓸 수 없다. `measured:true`는 같은 값이 TSV 셀에 없으면 exit 2다.

## 4. gate와 루브릭

`gate.conf`는 S0와 R5의 봉인물이다. 최소한 `AXES`, `N_AXES`, `MIN_REQ`, `SUM_REQ`, `MAX_SCORE=4`, `STALL_LIMIT=3`, readonly 범위와 승격 임계값을 가진다. 기존 파일은 수정·재선언하지 않는다.

`rubric.md`는 `gate.conf` 축 ID와 완전히 일치해야 한다. 축마다 질문, `자동검증:` 또는 `measure:`, 0~4 서술, 0·3·4의 aid 참조를 넣는다. 상세 형식·lint 규칙은 [rubric-design.md](rubric-design.md)를 따른다.

## 5. scores와 rounds

`scores.tsv`는 라운드당 한 행의 사람이 읽는 기록이다.

```text
round  axis  <축...>  min  sum  gate  verdict  note
R0     -     2 3 1   1    6    FAIL  BASE     베이스라인
```

축 수·순서는 `gate.conf`가 정한다. `gate`는 판정식 결과, `verdict`는 `BASE`, `KEEP`, `SIMPLIFY`, `REVERT`, `STALL` 중 기록 상태다. PASS가 있다고 루프 verdict가 KEEP으로 바뀌지 않는다.

`rounds.jsonl`은 같은 라운드의 기계 기록이다.

```json
{"round":"R1","ts":"2026-07-30T04:10:00Z","axis":"A3","axes":"A1,A2,A3","scores":[2,3,3],"min":2,"sum":8,"max":12,"gate":"FAIL","verdict":"KEEP","delta":"sum 6->8","note":"aid 보강","prev_hash":"<직전 행의 self_hash>","self_hash":"<이 행의 sha256>","state":{"kind":"git","root":"<readonly 루트>","commit":"<커밋>","tree_hash":"<트리 해시>"}}
```

REVERT도 반드시 두 파일에 남긴 뒤 exit 1을 낸다. 복원 증거는 그 뒤 `bench-revert.sh`가 같은 이력에 추가한다. 다음 라운드는 이 증거 없이 기록할 수 없다.

## 6. 보조 산출물

| 경로 | 생산자 | 소비자 | 역할 |
|---|---|---|---|
| `reach.conf`, `question.md`, `axes.tsv` | R0·R1 | Reach 전 단계 | 질문·축 봉인 |
| `sources/<sid>.md`, `fetch-log.jsonl` | R2 | R3·R4 | 본문 스냅샷과 전수 시도 이력 |
| `refute.jsonl` | R4 | reach-gate·rubric-lint | 재검증 판정 |
| `anchors/R*.md` | S3·S4 | bench-log | 라운드별 점수 근거 |
| `metrics/*.tsv` | G1 계측기 | reach-gate·rubric-lint | 실측값과 임계 판정 |
| `g2/worker-*.csv` | G2 | verdict-gate | 독립 축별 점수·인용 |
| `counterexample.md` | G3 입력 | verdict-gate | 루브릭 사각 공격 |

## 7. exit-code 계약

모든 스크립트는 아래 공통 의미를 쓴다. 사용법 오류의 실제 값이 64인 점을 예외로 만들지 않는다.

| exit | 의미 | 다음 행동 |
|---|---|---|
| 0 | 통과 | 다음 단계로 진행 |
| 1 | 판정 실패 | 산출물·앵커·축을 고치고 재실행 |
| 2 | 계약 위반 | 입력·기록·참조를 고친 뒤 처음부터 해당 게이트 재실행 |
| 3 | 환경 미비 | `reach-doctor.sh`로 도구를 진단. 판정 통과가 아니다. |
| 64 | 사용법 오류 | 인자 수·형식을 수정 |

단계별 특수 의미는 스크립트의 usage와 이 문서의 관련 절을 따른다. 예를 들어 `bench-log.sh`의 REVERT는 exit 1이지만 앵커 누락은 exit 2이며, 두 상태를 같은 실패로 취급하지 않는다.

## 8. 발행 전 수동 릴리스 체크

CI의 라이브 smoke는 네트워크가 필요한 `reach-fetch.sh`와 `reach-gate.sh`까지만 실행한다. Codex가 필요한 G2는 CI에 넣지 않는다. 발행 담당자는 Codex가 있는 환경에서 `SMOKE_LIVE=1 bash tests/smoke.sh`를 실행해 `g2-spawn.sh` 뒤 `verdict-gate.sh`가 실제로 호출되었는지 확인한다. Codex가 없어서 `SKIPPED`가 남은 실행은 이 수동 체크를 대체하지 않는다.

## 9. 위협 모델

seal(`reach.conf.seal`)·receipt(`reach-gate.receipt`)·prov(`metrics/<name>.tsv.prov`)·해시체인(`rounds.jsonl`)은 모두 공개 공식의 무키(unkeyed) SHA-256이다. 이 게이트가 막는 대상은 관대해지려는 에이전트의 무심한 우회와 한 줄 `sed` 수정이다. 해시를 다시 계산해 증거 파일을 의도적으로 날조하는 부정은 막지 못하며, 그러면 봉인 설정 바꿔치기, 축1 통과 영수증 위조, 계측 provenance 손타이핑, 독립 채점 CSV 손타이핑 검사를 통과시킬 수 있다. 후자는 게이트 밖의 외부 CI·독립 리뷰어가 막아야 한다. 이 한계를 숨기면 이 스킬의 정직성 불변식을 위반한다.
