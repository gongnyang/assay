# assay

[![CI](https://github.com/gongnyang/assay/actions/workflows/ci.yml/badge.svg)](https://github.com/gongnyang/assay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[The English edition — README.en.md](README.en.md)

**채점하는 쪽과 채점받는 쪽이 같으면, 그건 점수가 아니다.**

assay는 그 문제 하나를 붙잡고 만든 Claude Code 스킬이다. 웹에서 원문을 직접 끌어와 저장하고, 저장된 원문에 한 글자도 다르지 않게 남아 있는 인용만 채점 기준으로 올리고, 그 기준이 통과시킬 때까지만 결과물을 고친다. 통과를 선언할 수 있는 것은 에이전트가 아니라 스크립트다.

이 문서에서 계속 쓰는 말 셋. **Reach**는 웹에서 원문을 끌어와 스냅샷으로 저장하는 축이다. **Bench**는 그 원문 인용만으로 합격선을 만들어 채점하는 축이다. **앵커**는 스냅샷에 한 글자도 다르지 않게 남아 있는 인용 한 건이다.

## 게이트가 거부하는 장면

<!-- DEMO -->
![assay — 게이트가 작업을 거부한다](assets/assay-demo.gif)

<sub>55초 쇼케이스 중 앞 11초. 전체 영상은 [`assets/assay-showcase.mp4`](assets/assay-showcase.mp4) — 화면에 나오는 모든 문자열은 이 레포에서 그대로 가져온 것이고 연출한 출력은 없다.</sub>

설명보다 거부당하는 장면이 빠르다. 아래 네 블록은 소스 3건짜리 런에서 `skill/scripts/`가 실제로 뱉은 출력이다.

```console
$ reach-gate.sh .assay/run1
Reach 게이트 통과: usable=3, primary=2, active-confirmed-anchor=3
→ exit 0 — 사용 가능 소스 3건, 그중 1차 출처 2건, 확정 앵커 3건
→ 앵커 하나의 excerpt를 요약투로 고치고 같은 명령을 다시 실행한다.
  "Write terminal GIFs as code for integration testing and demoing your CLI tools."
  → "Write terminal GIFs as code — for testing and demos."

$ reach-gate.sh .assay/run1
!! Reach 계약 위반: anchors.jsonl:1: excerpt가 스냅샷 원문에 없음
→ exit 2 — 스냅샷에 없는 문자열이다. 요약은 앵커가 아니다.

$ bench-log.sh .assay/run1 R1 A1 4,2,3 "A1만 겨냥"
[R1] min=2 sum=9/12 gate=FAIL verdict=REVERT (하락: A2 — 파레토 위반)
→ exit 1 — 총점은 9로 유지됐으나(A1 3→4, A3 불변) A2가 3에서 2로 내려갔다. 파레토 위반이다.

$ bench-log.sh .assay/run1 R2 A2 4,3,3 "다음 라운드"
!! 되돌리지 않은 R1 REVERT 뒤에는 bench-revert.sh를 먼저 실행해야 합니다.
→ exit 2 — R1을 실제로 되돌리지 않았다. 다음 라운드는 기록되지 않는다.
```

두 번째 블록에서 한 일은 인용 한 건을 요약투로 다듬은 것뿐인데 게이트는 그걸 앵커로 인정하지 않았다. 세 번째는 총점이 그대로인데 축 하나가 내려간 라운드이고, 네 번째는 그 되돌림을 건너뛴 채 다음 라운드를 기록하려 한 시도다. 넷 다 사람이 판단한 게 아니다. 스크립트가 종료코드로 거부했고, 그걸 통과로 바꾸는 플래그나 환경변수는 이 트리 어디에도 없다.

## 언제 쓰고, 언제 쓰지 않는가

**레퍼런스를 감상하지 말고 채점 기준으로 승격시켜라. 그리고 그 기준이 통과시킬 때까지만 고쳐라.**

켜는 상황. 웹 소스 여러 건을 모아야 하고 나중에 그 원문을 다시 열어 확인할 수 있어야 할 때. 결과물을 "설명"이 아니라 남이 검증할 수 있는 레퍼런스 대비로 개선해야 할 때. 합격선이 필요한데 실패한 뒤에 그 선을 낮추지 않을 자신이 스스로도 없을 때. 트리거 예시는 "레퍼런스 대비 채점", "근거를 모아 평가표로", "벤치마킹해서 합격선까지 개선", "품질 게이트"다.

켜면 안 되는 상황은 이렇다.

- 사실 하나 확인하면 끝나는 질문. `WebSearch` 한 번이 답이면 그걸 쓴다.
- 이미 받은 자료로 보고서·번역·요약을 쓰는 일. 요약은 이 스킬이 근거로 인정하지 않는 형식이다.
- 발행, 로그인, 쿠키, API 키가 걸린 작업. 하지 않는다.
- 그 플랫폼 전용 스킬이 이미 깔려 있는 경우. 그 스킬을 먼저 쓴다.

## 빠른 시작

명령 넷, 벽시계로 10초 남짓이고 가입할 서비스는 없다.

**필요 사항:** bash 3.2 이상, coreutils, python3 3.8 이상(표준 라이브러리만 쓰며 `jq`·`yq`를 요구하지 않는다), git. 선택은 `gh`, `codex` CLI, `insane-search` 스킬이고, 없으면 접근 사다리의 그 단만 건너뛴다.

```bash
git clone https://github.com/gongnyang/assay.git
cp -r assay/skill ~/.claude/skills/assay
bash ~/.claude/skills/assay/scripts/install-gate.sh ~/.claude/skills/assay
```

```console
설치 게이트 통과: /home/you/.claude/skills/assay (회귀 18케이스)
```

세 번째 줄이 배포 위생 게이트다. macOS 압축 잔재, 실행 권한·shebang 결여, `SKILL.md`가 선언했는데 실물이 없는 파일, 130행 상한 초과, 그리고 종료코드와 README 구조 일치를 함께 검사하는 회귀 18케이스를 본다. exit 2가 나온 트리는 설치하지 않는다.

```bash
bash ~/.claude/skills/assay/scripts/reach-doctor.sh
```

```console
[ok] github: gh-api — probe 성공
  L0 gh-api: ok — probe 성공
  L1 insane-search: missing — insane-search 없음
  L2 webfetch: ok — probe 성공
  L3 jina-reader: ok — 읽기 probe 성공
  L4 manual: warn — 사람 수동 입력 전용
```

`contracts/channels.yml`에 선언된 채널마다 한 블록씩 나온다. 읽기 전용 probe이며 진단 경로는 아무것도 쓰지 않는다. `missing`은 실패가 아니라 그 단을 건너뛰고 다음 단을 쓴다는 뜻이다.

```bash
cd /개선할/프로젝트/경로
cat > q.md <<'EOF'
질문: 이 레포는 웰메이드 GitHub 레포 루브릭을 통과하는가?
소비처: 공개 발행 여부 결정
EOF
bash ~/.claude/skills/assay/scripts/reach-init.sh .assay/run1 q.md 3 30
```

```console
R0 봉인 완료: .assay/run1
  질문 해시와 수집 하한을 .assay/run1/reach.conf에 기록했다.
다음: reach-fanout.sh .assay/run1 <axes.tsv>
```

런 디렉터리는 에이전트 작업공간이 아니라 개선 대상 프로젝트 안에 생긴다. 같은 명령을 다시 실행하면 exit 1로 거부된다. 수집이 시작된 뒤에 질문을 다시 쓸 수 없게 만드는 것이 이 스크립트의 유일한 존재 이유다.

여기부터는 에이전트가 몬다. 단계별 행위 주체와 전체 트레이스는 [docs/how-it-works.md](docs/how-it-works.md)에 있다.

## 런이 남기는 것

[`examples/`](examples/)에 실제 런 하나가 손대지 않은 채로 들어 있다. 2026-07-29, 살아 있는 네트워크와 살아 있는 Codex 워커로 돌린 것이다.

| 단계 | 스크립트 | `.assay/run1/`에 남은 것 |
|---|---|---|
| R0 | `reach-init.sh` | `reach.conf` + `reach.conf.seal` — 봉인된 수집 하한 |
| R1 | `reach-fanout.sh` | `axes.tsv`, `briefs/AX-{1,2,3}.md` — 축당 수집 브리프 하나 |
| R2 | `reach-fetch.sh` ×3 | `sources/R-{A,B,C}.md` 스냅샷, `sources.jsonl`, `fetch-log.jsonl` |
| R3 | `reach-gate.sh` | `anchors.jsonl`, **`reach-gate.receipt`** — Bench로 들어가는 유일한 문 |
| S0 | `bench-init.sh` | `gate.conf` + `gate.conf.seal` — 채점이 시작되기 전에 봉인된 합격선 |
| S2 | `rubric-lint.sh` | 검증을 통과한 `rubric.md` |
| G2 | `g2-spawn.sh` | `g2/worker-1.csv`, `g2/receipt.json` — 출처가 붙은 독립 채점 |
| S3 | `bench-log.sh` | `scores.tsv`, 해시 체인이 걸린 `rounds.jsonl`, `rounds/R0/` 스냅샷 |
| G | `verdict-gate.sh` | 최종 판정 |

`sources.jsonl`은 어디에 언제 어떻게 접근했고 무엇을 저장했는지의 전량 기록이다. 성공한 본문은 `sources/<sid>.md` 스냅샷과 SHA-256 없이는 소스로 인정되지 않는다. `anchors.jsonl`은 그중 스냅샷 대조를 통과한 인용만 담는다. Bench는 이 두 파일 밖의 것을 채점 재료로 쓰지 않는다.

그 런의 결과는 이렇게 남았다.

```
round  axis  A1  A2  A3  min  sum  gate  verdict     note
R0     -      4   1   1    1    6  PASS  BASE        베이스라인
G2     G2     3   0   0    0    3  PASS  G2-ADOPTED  독립 채점의 낮은 점수 채택
```

두 번째 줄이 이 설계의 전부다. 자기채점은 `4,1,1`이었다. 독립 Codex 워커는 `3,0,0`을 돌려줬다. 낮은 쪽이 이의 없이 채택됐고, 불일치는 저자에게 유리하게 해소되지 않고 그대로 기록됐다. 단계별 해설은 [examples/README.md](examples/README.md)에 있다.

## 어디까지 믿을 수 있는가

**기계가 강제하는 것**

- 앵커의 excerpt는 저장된 스냅샷의 리터럴 부분문자열이어야 한다. `reach-gate.sh`가 스냅샷을 다시 읽어 대조하고, 유니코드 정규화로만 일치하는 excerpt는 경고를 찍은 뒤 그대로 실패한다. 정규화는 패러프레이즈의 첫 단계다.
- 봉인된 `gate.conf`는 `.seal` 사이드카의 해시와 어긋나는 순간 모든 소비자가 exit 2로 거부한다. 실패한 뒤 합격선을 내리는 경로가 없다.
- 축 하나라도 내려간 라운드는 REVERT이고, `bench-revert.sh`가 파일을 실제로 복원하고 복원된 트리의 해시를 남기기 전까지 다음 라운드는 기록되지 않는다. "다음 라운드에서 고려하겠다"는 되돌림이 아니다.

**기계가 강제하지 못하는 것**

- seal·receipt·해시 체인은 전부 무키 SHA-256이다. 변조를 드러내지 막지는 못한다 — `gate.conf`와 `gate.conf.seal`을 함께 고치는 상대는 통과한다.
- G2 독립성은 편향 축소이지 완전 독립이 아니다. 채점자는 개선 이력이 제외된 프롬프트를 받아 별도 `codex` 프로세스로 돌지만, 오케스트레이터는 같다.
- 계측이 돌았음을 재는 것은 그 계측이 실패로 뒤집힐지를 재는 것이 아니다. `tests/smoke.sh`의 마지막 실행은 `pass=20 fail=0 SKIPPED=4 skipped_ratio=0.166667`이며, 건너뛴 4건은 네트워크와 Codex 워커를 요구하는 라이브 케이스다.

| 코드 | 뜻 | 무엇을 고치나 |
|---|---|---|
| `0` | 계약이 지켜졌다 | 계속한다 |
| `1` | 판정 실패 — 결과물·앵커·축이 아직 부족하다 | *산출물*을 고치고 다시 돌린다. 합격선은 내리지 않는다 |
| `2` | 계약 위반 — 기록이나 증거 자체가 무효이고 아무것도 채택되지 않았다 | *입력*을 고치고 게이트를 처음부터 다시 돌린다 |
| `3` | 환경 미비 — 필요한 도구가 없다 | `reach-doctor.sh`로 진단한다. 통과가 아니다 |
| `64` | 사용법 오류 | 명령줄을 고친다 |

15개 진입점 전부 같은 값을 쓰고, 어느 값에도 지역적 의미를 덧씌우지 않는다. `1`과 `2`의 차이가 이 설계의 대부분이다. 하나는 "네 결과가 아직 거기까지 안 왔다"이고, 다른 하나는 "방금 준 것은 기록으로 신뢰할 수 없다"다. 스크립트별 전체 표는 [docs/gates.md](docs/gates.md#global-exit-codes)에 있다.

## 나머지 지도

### 레포 문서

| 문서 | 언제 여는가 |
|---|---|
| [examples/README.md](examples/README.md) | 읽기보다 돌아가는 걸 보고 싶을 때. 기록된 런의 단계별 해설 |
| [docs/how-it-works.md](docs/how-it-works.md) | 중요한 대상에 이 스킬을 걸기 전에. 1런 전체 트레이스와 행위 주체 구분 (영어) |
| [docs/gates.md](docs/gates.md) | 거부당했을 때. 스크립트 15본이 각각 무엇을 물리적으로 거부하는지의 표 (영어) |
| [docs/design-decisions.md](docs/design-decisions.md) | 집행 기전을 손대기 전에. 봉인·영수증·해시 체인을 강제한 적대감사 결함 (영어) |
| [docs/genealogy.md](docs/genealogy.md) | 이 레포가 어떤 주장을 스스로 근거로 쓰지 않는지 볼 때 (영어) |

루프 규율은 [karpathy/autoresearch](https://github.com/karpathy/autoresearch)에서 상속했다. 측정하고, 나빠지면 되돌리고, 전량 로깅하고, 동점이면 단순한 쪽이 이긴다. 두 번째 부모로 지목되던 스킬은 검증을 통과하지 못해 인용을 전량 삭제했고, `install-gate.sh`가 그 문자열의 재유입을 exit 2로 막는다.

### 레포 구조

```
assay/
├── skill/                  설치되는 스킬 본체
│   ├── SKILL.md            선언층. 트리거 때마다 상주 로드(130행 상한)
│   ├── references/         온디맨드 문서 6본(한국어 운용 매뉴얼)
│   ├── scripts/            집행층 15본 + _common.sh
│   └── contracts/          channels.yml, JSON 스키마 2본, 형판 2본
├── docs/                   이 레포 자체의 문서(영문)
├── examples/               기록된 런 하나
├── tests/                  smoke.sh — 종료코드 회귀 스위트
└── README.md  README.en.md
```

런은 스킬 디렉터리에도 에이전트 작업공간에도 쓰지 않는다. 개선 대상 프로젝트 안의 `.assay/<run>/`에 봉인 파일, `sources/` 스냅샷, 계약 JSONL 2종, `rubric.md`, `scores.tsv`, `rounds.jsonl`, `metrics/`, `g2/`, `counterexample.md`를 남긴다.

### 스킬 안쪽

상주 로드되는 것은 [`skill/SKILL.md`](skill/SKILL.md) 하나(110행)뿐이고, 무거운 서술은 전부 온디맨드다.

- [`reach-protocol.md`](skill/references/reach-protocol.md) — 질문 고정·축 분할·수집·재검증
- [`access-ladder.md`](skill/references/access-ladder.md) — 접근이 막혔거나 인증이 요구되거나 환경을 진단할 때
- [`rubric-design.md`](skill/references/rubric-design.md) — 축 유도·0~4 앵커 작성·판정식 결정
- [`loop-protocol.md`](skill/references/loop-protocol.md) — 라운드 운영·파레토 비교·되돌림·정체 진단
- [`contracts.md`](skill/references/contracts.md) — JSONL·TSV 작성과 검토, exit code 계약 확인
- [`instruments.md`](skill/references/instruments.md) — 새 대상 유형의 계측기를 새로 쓸 때

계약 데이터 중 둘은 파싱 대상이면서 사람이 직접 읽는 문서다. [`rubric.template.md`](skill/contracts/rubric.template.md)는 `rubric-lint.sh`가 대조하는 루브릭 형판이고, [`g2-prompt.md`](skill/contracts/g2-prompt.md)는 독립 채점자가 받는 프롬프트 정본이다. `skill/` 아래는 전부 한국어다. 스킬이 한국어로 운용되고 그것이 다루는 excerpt는 번역되어서는 안 되므로, 이중언어 유지비는 이 레포의 공개 문서 한 계층에서만 지불한다.

### 하지 않는 일

- **CLI 애플리케이션이 아니다.** 에이전트가 모는 Claude Code 스킬이고 구성은 bash 스크립트·문서·계약 데이터다. 데몬도 바이너리도 패키지 배포도 없다.
- **채널별 스크레이퍼를 동봉하지 않는다.** `channels.yml`은 라우팅 선언 데이터일 뿐 실행 코드가 아니며, 사이트 상수가 `scripts/`로 새면 `install-gate.sh`가 트리를 거부한다. 실제로 뚫는 일은 위임한다.
- **자격증명을 취득하거나 저장하지 않는다.** `auth_required`와 `not_found`는 재시도 대상이 아니라 terminal 상태이며, L4로 내려가 사람이 원문을 붙여넣고 출처를 명기한다.
- **보고서를 대신 쓰지 않는다.** 산출물은 근거가 붙은 판정과 재현 가능한 계약 파일이다. 스킬 문서의 이중언어화도 명시적 비목표다.
- **루브릭은 산출물을 재지 착상을 재지 않는다.** 전 축 4점을 받고도 아무도 쓰지 않을 소프트웨어일 수 있다. 유용성은 루프가 아니라 루프 이전에 결정된다.

### 나머지를 넘길 곳

| 필요한 것 | 갈 곳 |
|---|---|
| 트위터·레딧·유튜브·빌리빌리·샤오홍슈 등 차단된 플랫폼에서 실제로 본문을 가져오기 | [Panniantong/Agent-Reach](https://github.com/Panniantong/Agent-Reach) — API 비용 없이 채널 접근을 담당하는 CLI |
| 완강한 URL 한 건에 대한 WAF 우회·TLS 임퍼소네이션·실제 크롬 폴백 | [fivetaku/gptaku_plugins](https://github.com/fivetaku/gptaku_plugins)의 `insane-search` 스킬 — assay가 L1 단에서 위임하는 대상 |
| `~/.claude/skills/`와 `SKILL.md` front matter의 공식 규격 | [Claude Code skills 문서](https://docs.claude.com/en/docs/claude-code/skills) |

### 기여 · 라이선스

버그 보고와 재현 절차는 환영한다. 기능 추가는 좁게 받는다. 이 레포의 상품은 게이트이므로 우회 플래그·환경변수 뒷문·검증 생략 모드를 추가하는 PR은 그것이 아무리 편리해도 닫는다. 집행을 바꾸는 변경에는 변경 전에 실패하고 변경 후에 통과하는 회귀 픽스처가 함께 와야 한다. 전문은 [CONTRIBUTING.md](CONTRIBUTING.md), 우회 경로를 발견했을 때 이슈 대신 취할 절차는 [SECURITY.md](SECURITY.md), 릴리스 이력은 [CHANGELOG.md](CHANGELOG.md)에 있다.

MIT — [LICENSE](LICENSE).
