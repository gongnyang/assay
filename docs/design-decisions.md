# Design decisions

Why the enforcement looks the way it does. Read this before changing a mechanism — most of them exist because a specific attack succeeded, and the attack is recorded next to the fix.

## The audit that shaped the current build

The rebuilt skill was attacked twice before it was documented: a specification-conformance audit that compared every script against the sealed spec, and an execution red team that tried to obtain a `PASS` it had not earned. Together they produced 48 findings — 31 and 17 respectively.

The finding that mattered was not any individual bug. It was the shape of the successful attacks: **every attack that got through was some form of editing a file directly.** Six files carried the entire state of a run — `gate.conf`, `reach.conf`, `scores.tsv`, `rounds.jsonl`, `metrics/*.tsv`, `g2/worker-*.csv` — and not one of them had an integrity mechanism. Worse, Axis 2 never required Axis 1 to have passed. A `PASS` could therefore be issued from six hand-written files without a single web page ever being fetched.

That is the exact failure the skill exists to prevent, occurring inside the skill itself. Everything below follows from it.

## Mechanism 1 — seals on the sealed files

`reach-init.sh` and `bench-init.sh` write a `.seal` sidecar holding the SHA-256 of the file they just sealed. Every downstream consumer verifies it before doing anything else and exits 2 on a mismatch.

What this catches is the realistic attack, which is not an adversary at all. It is the operator three rounds into a failing loop who edits `SUM_REQ=17` down to `15` because the artifact is nearly there. One `sed`, no witnesses, and the verdict becomes meaningless — this is precisely the failure the rule *"a pass mark that can be adjusted afterwards is decoration, not a gate"* names.

What it does not catch is someone who updates `gate.conf` and `gate.conf.seal` together. A seal cannot seal itself without infinite recursion, and adding a second layer only moves the same problem up one level. We chose to stop at one layer and state the limit in the README, in the reference documents and in this file, rather than imply a strength the mechanism does not have. Tamper-evidence, not tamper-proofing.

## Mechanism 2 — the junction receipt

This was the highest-priority repair, because it closed the hole that made the other five files worth attacking.

When `reach-gate.sh` passes, it writes `reach-gate.receipt`: a single JSON line recording the timestamp, the question hash, and the SHA-256 of `reach.conf`, `sources.jsonl` and `anchors.jsonl` at that instant, along with the counts that satisfied the floor. `bench-init.sh`, `rubric-lint.sh` and `verdict-gate.sh` all begin by checking three things — the receipt exists, the current `anchors.jsonl` hash still matches it, and the current `reach.conf` hash still matches it. Any failure is exit 2 with the same message: Axis 1 was not passed, run `reach-gate.sh` first.

Two attacks die here. You can no longer skip collection entirely and hand-build the scoring inputs, because there is no receipt. And you can no longer pass the gate with honest anchors and then edit those anchors afterwards, because the hash moves.

The receipt is also why the two axes are joined by *data dependency* rather than by documentation. The instruction "run the gate first" is a request. A missing receipt is a refusal.

## Mechanism 3 — the round hash chain

Each record in `rounds.jsonl` carries `prev_hash` (the hash of the previous record, or `GENESIS`) and `self_hash` (the hash of its own sorted fields). `bench-log.sh` verifies the entire chain before appending, and exits 2 if it is broken.

Two consequences follow, and the second is the important one.

**The Pareto comparison reads the chain, not `scores.tsv`.** Previously the comparison read the human-readable TSV, which meant a single edited number in a text table could turn a REVERT into a KEEP. `scores.tsv` is now demoted to a display artifact; if its last row disagrees with the chain, that disagreement is itself treated as tampering and exits 2.

**A REVERT cannot be walked past.** `bench-log.sh` refuses to record a new round while the previous REVERT lacks restoration evidence — and the evidence is a tree hash written by `bench-revert.sh`, not a claim. The predecessor announced REVERT with exit 1 and then had no idea whether anything was reverted, so every subsequent measurement was taken on a tree that still contained the rejected change. That single gap invalidated every round after the first failure.

## Mechanism 4 — provenance on measurements

Every `metrics/*.tsv` is written together with a `<name>.tsv.prov` sidecar naming the instrument, its arguments, the timestamp, the file hash and the row count, and the TSV is written atomically through a temporary file and a rename. `reach-gate.sh` (check 7) and `bench-log.sh` (the `--simplify` evidence path) accept a TSV as evidence only when its provenance exists and its hash matches.

The rule being enforced is that a number typed by hand carries no weight. An anchor marked `measured:true` must correspond to an actual cell in a measurement file that some instrument actually produced. Without provenance, "measured" is a claim about a text file.

The same reasoning produces `g2/receipt.json`: the model used, the prompt hash, the sealed axis list and a per-worker CSV hash. `verdict-gate.sh` re-checks those hashes before believing any independent score. It also explains one small ordering rule that looks arbitrary — `g2-spawn.sh` deletes stale `worker-*.csv` files *before* checking whether codex is available. Checking first means that on an environment failure the previous run's CSVs survive and can be recovered as if they were this run's output.

## Decisions that predate the audit

**bash + coreutils + python3 standard library only.** No `jq`, no `yq`. The checks this skill depends on — literal substring comparison, hash recomputation, Unicode-aware matching — are exactly the checks that break on quoting and escaping in a bash-plus-jq pipeline. JSONL parsing, hashing and comparison happen inside python heredocs in each script; even the `channels.yml` parser is embedded, using a restricted YAML subset. One dependency instead of three, and the fragile operations move into a language with real string semantics.

**The ladder order lives in data, not code.** `channels.yml` declares each channel's rungs, backends and probes in list order, and that order is the execution policy. Changing which backend is tried first is a list reordering, not a code change. This also keeps every platform-specific string in one declarative file; `install-gate.sh` fails the tree if brand strings appear in `scripts/`, which is what stops per-site logic from slowly accumulating inside the engine.

**Two files at the junction, not one.** `sources.jsonl` is access history, including failures. `anchors.jsonl` is scoring material. Merging them would mix failed-access records into the evidence pool, and the discipline "record access failure as failure" would quietly stop meaning anything. They also have different lifetimes: access history is written once and never revised, while anchors are demoted as re-verification rules on them.

**Manual sources are allowed, and capped.** Refusing paywalled and authenticated material outright would permanently block whole research topics. Allowing it freely would turn "I read it somewhere" into evidence. So `status:manual` is legal, its confidence is capped at `med`, and manual sources may not exceed a third of the collection. The ceilings are sealed at R0, before anyone knows which sources will be hard to reach.

**The loop must stop.** Inherited discipline says never stop; assay always closes with a verdict. An improvement loop with a pass mark that keeps running past the mark is optimizing for nothing, and a loop that keeps running through repeated failures is not being diligent — it is failing to notice that the rubric is wrong. Three consecutive REVERTs closes the loop and moves the investigation to the rubric.

**The 0-point and 4-point anchors of one axis must come from different sources.** This is a crude rule with a precise target. When both extremes of an axis are drawn from the same reference, the axis is almost always measuring "how much does the work resemble that reference" — which makes copying the reference the definition of full marks. `rubric-lint.sh` rejects it. The same lint flags an axis on which every reference scores identically, because that is a precondition wearing an axis costume, and preconditions have no discriminating power.

**Exit 1 and exit 2 are different classes.** `1` means the artifact is not good enough; `2` means the record cannot be trusted. Collapsing them would let a contract violation be answered by another round of polishing. Keeping them apart is what makes "fix the input" and "fix the work" distinguishable without reading the source.

## Specification revisions forced by the audits

The specification was written before the code and lost several arguments to it. The revisions are recorded rather than retrofitted.

| Item | Original spec | Revised | Reason |
|---|---|---|---|
| `scripts/` total size | 1,000–1,400 lines | ≤ 3,200 lines, ≤ 220 per file | The integrity mechanisms above are all code. The `SKILL.md` ceiling of 130 lines did not move, because that is the file loaded on every trigger |
| Usage errors | `2` in some scripts | `64` everywhere | Two scripts used `2` for a usage error, which is the code that means "the evidence is invalid" |
| Missing python3 | Undefined; surfaced as `127` in eleven scripts | `3`, guarded at the top of every script | An environment failure reported as an unrecognized shell error is easy to mistake for a pass in an automated loop |
| Axis IDs | Unconstrained | `^[A-Za-z][A-Za-z0-9_-]*$`, enforced at sealing time | Non-ASCII axis IDs deadlocked the heading matcher at G3. Rejecting them at the seal is better than failing at the last gate |
| Instrument signatures | Divergent | Both take `<target> <run-dir>` and write atomically into `<run-dir>/metrics/` | `--simplify` needs to compare rounds inside one run directory |
| Ladder order | Hardcoded table | Read from `channels.yml` list order | Otherwise reordering the policy required editing the engine |
| G2 axis list | Parsed from `rubric.md` headings | Read from `gate.conf` `AXES=` | Heading parsing made the scored axis set depend on Markdown formatting |
| Citation regex | `[A-Za-z0-9_.-]+\.(md\|py\|sh\|mjs\|js)` | Unicode filenames accepted | The guidance text advertised Korean filename examples that the implementation rejected, so legitimate anchors were refused as uncited |

## Known limits we chose not to close

Recorded here because a limit you have written down is a different thing from a limit you have hidden.

- **Seal and sidecar can be edited together.** Discussed above. One layer, stated plainly.
- **G2 is bias reduction, not independence.** Separate processes, a pinned model and a prompt with the improvement history physically excluded — but the same orchestrator. `g2-spawn.sh` records this next to its own output rather than describing the result as independent verification. The research this is based on is itself hedged: the MT-Bench authors reported the self-enhancement effect and then wrote that their study *"cannot determine whether the models exhibit a self-enhancement bias"*. We kept the hedge.
- **The simplicity criterion is narrowed.** The origin weighed complexity against improvement in every round. assay fires it only at an equal total, as a tie-breaker with measured evidence. The consequence is that a round buying a tiny gain with a large complexity increase is not caught by the Pareto rule. This is a deliberate narrowing, not an oversight, and it is the one place where the origin's discipline is stronger than ours.
- **The rubric does not measure usefulness.** A repository can score full marks on every axis and still be pointless software. Whether the thing is worth building is decided before the loop starts. Naming that boundary is how the "all fours and still bad" counterexample is answered: it is out of scope, not a blind spot.
