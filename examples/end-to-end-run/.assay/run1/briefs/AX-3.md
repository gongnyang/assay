# 수집 워커 브리프 — AX-3 축의 원문 스냅샷만 수집한다.
# 워커가 판정까지 맡으면 수집과 신뢰도 태깅의 경계가 사라지므로 반환 형식을 고정한다.

담당 축 ID: AX-3
하위 질문: 리더 프록시 단의 결과는 얼마나 다른가
목표 소스 수: 1
동시성: 기본 5, 상한 15. 하위 질문 1개에는 이 워커 1개만 배정한다.

## 구동 질문과 소비처
질문: 접근 사다리 각 단은 실제로 무엇을 돌려주는가?
소비처: 수집 백엔드 우선순위 결정

## 반환 형식 (고정)
1. 담당 축 ID: AX-3
2. 반환 파일 경로: /tmp/claude-1000/-home-seunghyeong/45f64c22-020f-456f-a562-fb448632c2af/scratchpad/redteam/p1/.assay/run1/sources.jsonl (한 줄에 JSON 객체 하나씩 append)
3. 반환 스키마: sources.jsonl §5.1 그대로
```json
{"sid":"R-<대문자 ID>","worker_id":"<담당 수집 워커 ID>","axis":"<담당 축 ID>","url":"<원 URL>","title":"<제목>","channel":"<channels.yml 채널>","ladder":"L0~L4","backend":"<실제 백엔드>","fetched_at":"<UTC ISO-8601>","observed_at":"<UTC ISO-8601>","valid_at":"<내용 기준 시점>","status":"ok|manual|blocked|auth_required|not_found|timeout","attempts":1,"ladder_stopped_at":0,"untried_ladder":[],"kind":"","confidence":"","snapshot":"sources/R-<ID>.md","sha256":"<sha256>","access_note":""}
```

원문 본문은 sources/<sid>.md에 저장하고 sha256을 기록한다. 앵커·루브릭·최종 판정은 만들지 않는다.
신뢰도 태깅은 R3의 단일 지점에서 확정한다. 수집 워커는 접근 사실과 스냅샷만 남긴다.
