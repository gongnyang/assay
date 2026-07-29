# Genealogy

Where assay's rules came from, and which of the claimed origins survived verification.

This document keeps the failures in. A skill whose central rule is "a quotation you cannot re-read in the original is not evidence" cannot present its own lineage as a tidy list of influences. The predecessor skill made 30 lineage claims; an adversarial re-verification session, working from the excerpts alone, re-opened the sources and ruled on each one. Eight of the thirty did not survive. They are printed below with the same weight as the ones that did.

## Verdict vocabulary

| Verdict | Meaning |
|---|---|
| **CONFIRMED** | The re-verifier re-opened the original and the quoted text matched. |
| **UNVERIFIED** | The original could not be reached, or the claim carried no quotation to compare against. Not usable as evidence. |
| **REFUTED** | The quoted text does not match what the named source actually says. Not usable as evidence, and not usable as a "structurally similar" precedent either. |

Tally: 30 claims — 22 CONFIRMED, 6 UNVERIFIED, 2 REFUTED.

| Track | Claims | CONFIRMED | UNVERIFIED | REFUTED |
|---|---|---|---|---|
| 1. `karpathy/autoresearch` | 8 | 8 | 0 | 0 |
| 2. `reference-research` (the claimed second parent) | 14 | 11 | 2 | 1 |
| 3. Academic origins | 8 | 3 | 4 | 1 |

## Track 1 — karpathy/autoresearch

The loop discipline. All eight claims confirmed against `README.md` and `program.md` in [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

| assay rule | Original text | Verdict |
|---|---|---|
| Declare a read-only scope before improving anything | README: *"Single file to modify. The agent only touches `train.py`. This keeps the scope manageable and diffs reviewable."* · program.md: *"**What you CAN do:** Modify `train.py` — this is the only file you edit. … **What you CANNOT do:** Modify `prepare.py`. It is read-only."* | CONFIRMED |
| Revert on regression | *"8. If val_bpb improved (lower), you \"advance\" the branch, keeping the git commit / 9. If val_bpb is equal or worse, you git reset back to where you started"* | CONFIRMED |
| Log every round, including the discarded ones | *"When an experiment is done, log it to `results.tsv` … The TSV has a header row and 5 columns: commit / val_bpb / memory_gb / status / description"* · *"4. status: `keep`, `discard`, or `crash`"* | CONFIRMED |
| A simplification at equal score is a win | *"Simplicity criterion: All else being equal, simpler is better. A small improvement that adds ugly complexity is not worth it. Conversely, removing something and getting equal or better results is a great outcome — that's a simplification win. … An improvement of ~0 but much simpler code? Keep."* | CONFIRMED |
| Stall handling (inverted — see below) | *"**NEVER STOP**: Once the experiment loop has begun (after the initial setup), do NOT pause to ask the human if you should continue. … You are autonomous. … The loop runs until the human interrupts you, period."* | CONFIRMED |
| The metric is fixed and the agent may not edit the harness | README: *"The metric is **val_bpb** (validation bits per byte) — lower is better, and vocab-size-independent so architectural changes are fairly compared."* · program.md: *"**The goal is simple: get the lowest val_bpb.**"* and *"Modify the evaluation harness. The `evaluate_bpb` function in `prepare.py` is the ground truth metric."* | CONFIRMED |
| Repository metadata | `gh api repos/karpathy/autoresearch`, queried 2026-07-29 | CONFIRMED |
| File layout | README "Project structure" against the actual root listing | CONFIRMED |

**One inaccuracy found in our own predecessor.** It quoted autoresearch as `worse → git reset --hard`. The original contains no `--hard` flag; it says *"you git reset back to where you started"*. The spirit was right and the command quotation was wrong, which is precisely the failure mode `reach-gate.sh` now rejects by exit code. The citation has been corrected.

### Where assay inverts its origin

| # | Original | assay |
|---|---|---|
| A1 | *"The loop runs until the human interrupts you, period."* | The loop always closes: PASS at the sealed mark, or STOP after three consecutive REVERTs, or STOP because the work needed lies outside the sealed scope. Running forever is a diagnostic failure, not diligence. |
| A2 | A single scalar, `val_bpb`, and an evaluation harness the agent may not touch | A multi-axis rubric with 0–4 anchors and `PASS ⟺ min(axis) ≥ M AND sum(axis) ≥ S`. Further, G3 attacks the rubric itself with a counterexample — the one thing the original froze, assay deliberately leaves attackable. |
| B1 | Revert when the single metric regresses | Revert when *any* axis regresses — the scalar comparison generalized to a Pareto rule. |
| B2 | Only `train.py` may be edited | Generalized to a declared read-only scope, so the loop applies to documents, decks and copy as well as code. |
| C1 | The simplicity criterion weighs complexity against improvement in *every* round | assay narrows it to a tie-breaker that fires only at an equal total, and requires measured evidence (line count, file count, dependency count) before accepting it. A round that buys a tiny gain with a large complexity increase is therefore *not* caught by the Pareto rule — this is a known narrowing, recorded rather than hidden. |

## Track 2 — the parent that was not there

The predecessor skill cited a skill named `reference-research` as the origin of its research discipline, in eight places, complete with section numbers (`§1`, `§3.4`, `§4`) and verbatim principles such as *"손으로 적어 넣은 숫자는 0"* ("a number typed in by hand is zero") and *"LLM이 쓴 걸 LLM이 채점하면 서로 후한 점수를 준다"* ("when an LLM grades what an LLM wrote, they are generous to each other").

Eleven of the fourteen claims in this track are CONFIRMED in a narrow sense: the citing text really does exist in the predecessor's files. What could not be confirmed is the thing being cited.

- The skill is not installed on the machine that claimed to inherit from it (32 installed skills, none of them this one).
- Two public repositories contain a skill by that exact name. Both were fetched and read in full. Neither has the section structure, the confidence tagging, or any of the quoted principles — one is a generic reference-lookup workflow, the other a Korean competitor-benchmarking skill that delegates to a sub-agent.
- Code search across GitHub (152 hits, 18 examined closely) plus three web searches found none of the four quoted principles anywhere.
- One structurally similar public skill was found — a deep-research skill with `sources.jsonl` / `evidence.jsonl` / `claims.jsonl` and a mandatory claim-support verification step. Its quotation checks out, but its names and section numbering differ, so it is recorded as a contemporary parallel, not an ancestor.

The final claim — that the parent was simply invented — is marked **UNVERIFIED**, because "this does not exist anywhere" is not something a citation can establish. The sub-facts (local absence, two same-named repositories with different content) are independently confirmed.

**What assay did about it.** Every citation was deleted. The principles that were worth keeping were re-declared as assay's own clauses in `references/reach-protocol.md`, standing on their own merit rather than on a borrowed authority. `install-gate.sh` fails any tree in which the string reappears, so the ghost cannot come back through a copy-paste.

One REFUTED row also sits in this track. Stanford's STORM was proposed as a structural precedent, but the quotation joined two non-adjacent README paragraphs into what looked like a continuous quote. The second half is not what the README says. The precedent was dropped entirely rather than repaired.

## Track 3 — academic origins

The weakest track: 3 confirmed, 4 unverified, 1 refuted. These were never cited by the skill itself; a researcher reconstructed them afterwards, which is exactly the direction in which citations rot.

| Claim | Origin | Verdict |
|---|---|---|
| 0–4 levels anchored by concrete behavioural examples | Smith & Kendall (1963), the BARS paper — *"A procedure was tested for the construction of evaluative rating scales anchored by examples of expected behavior"*, *"scale reliabilities ranged above .97"* | CONFIRMED (abstract only; the full text is paywalled). The predecessor's version of this quote silently dropped "was tested" |
| Self-scoring bias justifies an independent scorer | Zheng et al. (2023), MT-Bench — *"We adopt the term 'self-enhancement bias'… GPT-4 favors itself with a 10% higher win rate; Claude-v1 favors itself with a 25% higher win rate."* together with the authors' own caveat *"Due to limited data and small differences, our study cannot determine whether the models exhibit a self-enhancement bias"* | CONFIRMED — including the caveat, which is why assay treats G2 as bias reduction rather than proof |
| One axis per round | Coordinate descent / one-factor-at-a-time | CONFIRMED, but the source is encyclopaedic rather than a specific paper, and the claim says so |
| No post-hoc adjustment of the pass mark | Goodhart (1975) | **UNVERIFIED** — secondary sources only |
| No post-hoc adjustment of the pass mark | Campbell (1976/1979) | **UNVERIFIED** — secondary sources only |
| Pareto rule | Pareto (1906) | **UNVERIFIED** — the 1906 original was never obtained |
| Held-out floor checks | Hastie/Tibshirani/Friedman *ESL* Ch.7 + Dwork et al. (2015) | **UNVERIFIED** — the Dwork abstract checks out, the ESL quotation came from a third-hand paraphrase, so the pair is failed together |
| MECE axis fan-out | Minto, *The Pyramid Principle* | **REFUTED** — the sentence attributed to the cited page does not appear there verbatim. Whether MECE is Minto's idea is a separate question; this quotation cannot be used |

The consequence is stated plainly: **assay's sealed pass mark, its Pareto rule and its floor checks carry no academic justification in this repository.** They are engineering decisions defended by the audit findings in [design-decisions.md](design-decisions.md), not by Goodhart, Campbell, Pareto or ESL. Removing an unverified citation is cheaper than defending a rule you cannot source.

## What this means for assay's own claims

Three habits follow from the above, and all three are enforced rather than promised.

1. **A quotation lives or dies by re-reading.** `reach-gate.sh` compares each excerpt against the stored snapshot; `reach-refute.sh` makes a different worker re-open the original URL and prove it with a fresh hash.
2. **A failed claim is demoted, not deleted.** `REFUTED` and `UNVERIFIED` rows stay in `anchors.jsonl` with `active:false`. The rubric cannot reference them, and the audit trail keeps them visible.
3. **An unverified axis blocks the whole verdict.** `verdict-gate.sh` refuses to print `PASS` while any axis is missing anchors, measurement or an independent score. There is no partial credit for a claim nobody checked.
