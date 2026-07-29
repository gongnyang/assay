# Examples

## `end-to-end-run/` — a real run, captured verbatim

Every script-produced file in that directory came out of `../skill/scripts/`, against live network
sources and a live Codex worker, on 2026-07-29. One file is not script-produced: `anchors.jsonl` is
curated by the agent after collection, and its four `captured_at` values were written afterwards
(all four read `2026-07-30T00:00:00Z`, not the per-fetch timestamps in `sources.jsonl` and
`fetch-log.jsonl`). The anchors themselves are still checked against the sealed snapshots by
`reach-gate.sh`; only the recording time is retrospective.

It exists because this project claims its gates are enforced by exit codes rather than prose, and a
claim like that is worth exactly as much as the run you can point at.

`end-to-end-run/README.md` is not documentation — it is **the document that got scored**. The run
directory sits beside it at `end-to-end-run/.assay/run1/`.

### What the run did

The driving question, from `.assay/run1/question.md`:

```
질문: 접근 사다리 각 단은 실제로 무엇을 돌려주는가?
소비처: 수집 백엔드 우선순위 결정
```

Axis 1 (Reach) collected three sources over the real access ladder, tagged their confidence, and
verified every anchor excerpt against the stored snapshots. Axis 2 (Bench) derived a rubric, scored a
baseline, and ran an independent Codex re-score before issuing a verdict.

### The sequence, and what each step left behind

| Step | Script | Artifact under `.assay/run1/` |
|---|---|---|
| R0 | `reach-init.sh` | `reach.conf` + `reach.conf.seal` — the collection floor, sealed |
| R1 | `reach-fanout.sh` | `axes.tsv`, `briefs/AX-{1,2,3}.md` — one collection brief per axis |
| R2 | `reach-fetch.sh` ×3 | `sources/R-{A,B,C}.md` snapshots, `sources.jsonl`, `fetch-log.jsonl` |
| R3 | `reach-gate.sh` | `anchors.jsonl`, **`reach-gate.receipt`** — the junction into axis 2 |
| S0 | `bench-init.sh` | `gate.conf` + `gate.conf.seal` — the pass line, sealed before any scoring |
| S2 | `rubric-lint.sh` | validated `rubric.md` |
| G2 | `g2-spawn.sh` | `g2/worker-1.csv`, `g2/receipt.json` — independent scoring, with provenance |
| S3 | `bench-log.sh` | `scores.tsv`, `rounds.jsonl` (hash-chained), `rounds/R0/` snapshot |
| G | `verdict-gate.sh` | final verdict |

### The result

```
round  axis  A1  A2  A3  min  sum  gate  verdict     note
R0     -      4   1   1    1    6  PASS  BASE        베이스라인
G2     G2     3   0   0    0    3  PASS  G2-ADOPTED  독립 채점의 낮은 점수 채택
```

The second row is the point of the whole design. The self-score was `4,1,1`. The independent Codex
worker returned `3,0,0`. The lower score was adopted without argument, and the disagreement was
recorded rather than resolved in the author's favour. See `../docs/gates.md` for the rule.

### The receipts

`reach-gate.receipt` binds axis 2 to axis 1. `bench-init.sh`, `rubric-lint.sh` and `verdict-gate.sh`
all refuse to run without it, and re-check that `anchors.jsonl` still hashes to the value recorded at
the moment the gate passed:

```json
{"ts":"2026-07-29T17:13:10Z","usable":3,"primary":2,"confirmed_anchors":4, ...}
```

`g2/receipt.json` does the same for independent scoring — model, prompt hash, per-worker timing and
CSV hash — so a verdict cannot be issued from CSV files that no Codex run produced.

Both are unkeyed SHA-256. They stop careless bypass, not deliberate forgery. The threat model in
`../skill/references/contracts.md` says so plainly and names the attacks that still get through.

### Reading it yourself

Start with `.assay/run1/question.md`, then `anchors.jsonl` (each anchor cites a snapshot under
`sources/`), then `scores.tsv`. `rounds.jsonl` carries the hash chain that makes the score history
tamper-evident.
