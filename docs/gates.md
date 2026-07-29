# Gate reference

All fifteen entry points in `skill/scripts/`, what each one physically refuses, and the exit code it uses to do it. A sixteenth file, `_common.sh`, is sourced by all of them and is not an entry point.

Read this when a script has rejected you. The first question is always which class of failure it is, because that decides what you fix.

## Global exit codes

Identical across every script. Nothing overloads these values with a local meaning.

| Code | Class | What it means | What you do |
|---|---|---|---|
| `0` | Pass | The contract held | Continue |
| `1` | Verdict failure | The work, the anchors or the axes are not good enough yet | Fix the *artifact* and re-run. Never lower the bar |
| `2` | Contract violation | The recording or the evidence itself is invalid; nothing was accepted | Fix the *input* and re-run the gate from the start |
| `3` | Environment missing | A required tool is absent | Diagnose with `reach-doctor.sh`. This is not a pass |
| `64` | Usage error | Wrong argument count or shape | Fix the command line |

The distinction between `1` and `2` carries most of the design. `1` says "your result is not there yet". `2` says "what you just handed me cannot be trusted as a record at all" — a missing anchor file, an excerpt absent from its snapshot, a broken hash chain, a rubric citing an anchor that does not exist. There is no flag, environment variable or configuration key anywhere in the tree that turns either of them into a pass.

## Standing mechanisms

Four mechanisms run underneath the individual scripts.

**Seals.** `reach-init.sh` and `bench-init.sh` write a `.seal` sidecar holding the SHA-256 of the file they sealed. Every consumer verifies it on startup and exits 2 on a mismatch. The limit is stated in the README and repeated here: an actor who edits `gate.conf` and `gate.conf.seal` together is not stopped. A seal cannot seal itself.

**The junction receipt.** `reach-gate.sh` writes `reach-gate.receipt` on success, recording the hashes of `reach.conf`, `sources.jsonl` and `anchors.jsonl` at that moment. `bench-init.sh`, `rubric-lint.sh` and `verdict-gate.sh` exit 2 if the receipt is missing or if any of those files has changed since. Axis 2 cannot be run on hand-made files.

**The round hash chain.** Each record in `rounds.jsonl` carries `prev_hash` and `self_hash`. `bench-log.sh` verifies the whole chain before appending, and exits 2 if it is broken or if the last row of `scores.tsv` disagrees with the last row of the chain. Pareto comparison reads the chain, not the human-readable TSV.

**Measurement provenance.** Every `metrics/*.tsv` is written with a `.tsv.prov` sidecar naming the instrument, its arguments, the timestamp and the file's hash. `reach-gate.sh` and `bench-log.sh` accept a TSV as evidence only when its provenance exists and its hash matches — a hand-edited measurement is not evidence.

## Axis 1 — Reach

### `reach-init.sh <run-dir> <question-file> <min-sources> <poc-max-pct>`

Seals the driving question and the collection floor.

Refuses: a second declaration of an existing run; a question file that is not a single sentence ending in a question mark; an empty consumer field. Seals `QUESTION_SHA256`, `MIN_SOURCES`, `MIN_PRIMARY`, `POC_MAX_PCT`, `MANUAL_MAX_PCT`, `AXES_MIN`/`AXES_MAX`.

| Exit | Condition |
|---|---|
| 0 | Sealed |
| 1 | `reach.conf` already exists — the question may not be redeclared |
| 2 | The question or consumer field breaks the input contract |
| 64 | Wrong argument count |

### `reach-fanout.sh <run-dir> <axes.tsv>`

Splits the question into axes and writes one worker brief each.

Refuses: an axis count outside the sealed range; duplicate axis IDs; a missing target-source count; axis statements whose 3-gram overlap exceeds the threshold. Near-duplicate axes are the cheapest way to fake research breadth, so they are rejected mechanically rather than by review.

| Exit | Condition |
|---|---|
| 0 | Briefs written |
| 1 | Axis overlap too high — merge or re-split |
| 2 | Axis count, ID uniqueness or target-count contract broken |
| 64 | Wrong argument count |

### `reach-fetch.sh <run-dir> <url> <axis-id> [--channel <name>]`

Climbs the ladder declared in `contracts/channels.yml` and logs every attempt.

Refuses: declaring a failure while `untried_ladder` is non-empty — you cannot call a URL inaccessible until every rung has been tried or recorded as unavailable. Also refuses to record a success without writing `sources/<sid>.md` and its SHA-256. Credentials are scrubbed from the body once, immediately before writing. `auth_required` and `not_found` are terminal and drop to L4; `rate_limited` is not terminal and the climb continues.

| Exit | Condition |
|---|---|
| 0 | `ok`, snapshot stored |
| 1 | Every rung tried, all failed — the reason is recorded and the source is barred from anchoring |
| 2 | Failure declared with rungs untried, or the snapshot could not be written |
| 3 | No rung is available at all (a single missing rung only demotes to the next one) |
| 64 | Wrong argument count |

### `reach-gate.sh <run-dir>`

The only door into Axis 2.

Refuses, in order: too few distinct sources or too few primary sources; a missing snapshot or a SHA-256 that no longer matches; **an `excerpt` that is not a literal substring of its snapshot**; an anchor derived from a failed access; low-confidence or manually pasted material above the sealed ceilings; a marketing source backing an automatically verified axis; a `measured:true` anchor whose value is not in a provenance-backed `metrics/*.tsv`; a `question.md` whose hash no longer matches the seal; a `<file>:<line>` locator that does not point at that line of the snapshot.

An excerpt that matches only after Unicode normalization is reported and still fails: normalization is the first step towards paraphrase.

| Exit | Condition |
|---|---|
| 0 | Contract held; `reach-gate.receipt` written |
| 1 | Not enough collected yet — go back and gather more |
| 2 | Schema breach, hash mismatch, or an excerpt that is not in the original |
| 3 | python3 missing |
| 64 | Wrong argument count |

### `reach-refute.sh <run-dir> [--workers N]`

Spawns re-verifiers that see only the excerpt, the locator and the source ID.

Refuses: an anchor with no verdict; a re-verifier whose worker ID equals the collector's; a re-fetch hash identical to the stored snapshot's, which proves the original was never re-opened. `REFUTED` anchors are demoted to `active:false` and can no longer be referenced by the rubric; the rows are never deleted.

| Exit | Condition |
|---|---|
| 0 | Every anchor ruled on, and the confirmed ones still meet the source floor |
| 1 | Too few sources survive — return to collection |
| 2 | Missing verdict, or collector and re-verifier are the same worker |
| 3 | codex or python3 missing |
| 64 | Wrong argument count |

### `reach-doctor.sh [--json]`

Read-only diagnosis of every rung declared in `channels.yml`, reported as `ok` / `warn` / `missing` / `broken` / `timeout`.

Three rules: file existence is not availability, so each candidate is actually executed; probes must be side-effect free; the diagnosis path never writes. Candidates are collected in one pass and chosen in a second, so an unauthenticated earlier candidate cannot mask a working later one.

| Exit | Condition |
|---|---|
| 0 | At least one usable candidate |
| 2 | The channel declaration itself is invalid |
| 3 | No usable candidate anywhere |
| 64 | Wrong argument count |

## Axis 2 — Bench

### `bench-init.sh <run-dir> <axes-csv> <min-req> <sum-req>`

Seals the axes, the pass mark, the read-only scope and any thresholds promoted from measured anchors (R5).

Refuses: redeclaring an existing `gate.conf`; an axis ID that is not `^[A-Za-z][A-Za-z0-9_-]*$`; a malformed axis CSV; a missing or stale junction receipt.

| Exit | Condition |
|---|---|
| 0 | Sealed |
| 1 | `gate.conf` already exists — the pass mark may not be redeclared |
| 2 | Axis syntax error, or the receipt is missing / no longer matches |
| 64 | Wrong argument count |

### `rubric-lint.sh <run-dir>`

Static integrity check on `rubric.md` before any scoring happens.

Refuses: axes that disagree with `gate.conf`; a 0, 3 or 4 level with no `aid` reference; an `aid` that does not exist, is inactive, or is not `CONFIRMED`; **a 0-point anchor and a 4-point anchor drawn from the same source**, which is the mechanical signature of defining "copy the reference" as full marks; an automatically verified axis without a `measure:` command that has actually produced output; a missing reverse-scoring table. Two axes whose anchor sets are identical are rejected as duplicates; an axis on which every reference scores the same is flagged as a precondition masquerading as an axis.

| Exit | Condition |
|---|---|
| 0 | Rubric usable |
| 1 | Design flaw — an axis with no discriminating power, or an unreachable level |
| 2 | Reference integrity broken, or the receipt is missing / stale |
| 64 | Wrong argument count |

### `bench-log.sh <run-dir> <round> <axis-targeted> <scores-csv> [note] [--simplify]`

Records exactly one round. The operator supplies per-axis scores and nothing else; `min`, `sum`, the gate result, the Pareto comparison and the stall count are all computed here.

Refuses: a missing `anchors/<round>.md`; any axis line in it without one of the four accepted citation forms — a source ID (`R-A`), `[실측]`, `<file>.<ext>:<line>` with any Unicode filename, or a direct quotation; a round ID already recorded; a broken `rounds.jsonl` hash chain; a `scores.tsv` last row that disagrees with the chain; **a new round while the previous REVERT has not been restored**; `--simplify` without a measured reduction in line count, file count or dependency count in a provenance-backed TSV.

Verdicts: `BASE`, `KEEP` (all axes held and the total rose), `SIMPLIFY` (equal total with measured complexity reduction), `REVERT` (any axis fell, or an equal total with no simplification evidence), `STALL` (recorded when consecutive REVERTs reach the sealed limit).

| Exit | Condition |
|---|---|
| 0 | `BASE`, `KEEP` or `SIMPLIFY` |
| 1 | `REVERT` — restore before the next round |
| 2 | Anchor, citation, chain, or unrestored-revert contract violated; the round is not recorded |
| 3 | python3 missing |
| 64 | Wrong argument count |

Unicode filenames are accepted deliberately. The predecessor's citation regex was ASCII-only, so a legitimate anchor citing a Korean filename was rejected as uncited — the guidance text and the implementation disagreed. That is now one of the regression fixtures `install-gate.sh` runs.

### `bench-revert.sh <run-dir> <round>`

Performs the restoration and leaves the evidence the next round will be asked for.

Refuses: a restoration target that does not exist; a snapshot root outside the sealed `TARGET_DIR`, which would let a revert destroy files beyond scope; a deletion set larger than half the target's files, which usually means a partial snapshot is being mistaken for a full one. The deletion list is printed before anything is removed. If the restored tree's hash does not match the last `KEEP`/`BASE` round, it exits 1 — the restoration did not actually restore.

| Exit | Condition |
|---|---|
| 0 | Restored, hashes match, evidence appended |
| 1 | Restored tree does not match the last adopted round |
| 2 | Nothing to restore, or the scope / deletion-ratio guard tripped |
| 3 | Environment missing |
| 64 | Wrong argument count |

### `g2-spawn.sh <run-dir> [--workers N]`

Runs independent scorers and recovers their CSVs.

Refuses: a prompt assembled from anything other than `contracts/g2-prompt.md`, `rubric.md` and the target snapshot — if the content of `rounds.jsonl`, `scores.tsv` or `anchors/R*.md` appears in the assembled prompt it exits 2; a worker CSV that fails format validation; a missing recovery. Stale `worker-*.csv` files are deleted before spawning, and before the codex availability check, so a previous run's output can never be recovered as if it were this run's. On success it writes `g2/receipt.json` with the model, the prompt hash, the sealed axis list and per-worker hashes; `verdict-gate.sh` re-checks those hashes.

The axis list comes from `gate.conf`, never from parsing `rubric.md` headings.

| Exit | Condition |
|---|---|
| 0 | All workers recovered |
| 1 | Recovery or CSV format failure |
| 2 | Prompt contamination — the improvement history reached the scorer |
| 3 | codex unavailable |
| 64 | Wrong argument count |

### `verdict-gate.sh <run-dir>`

The only place in the system that can print `PASS`.

Five checks, in order:

1. **Independent comparison.** Any axis where self-score and independent score differ by 2 or more exits 1 — and the instruction is to strengthen that axis's anchors, not the artifact. A 1-point gap silently adopts the lower score.
2. **Reverse check.** If no reference reaches 3 on some axis, that axis describes an unreachable ideal; exit 1.
3. **Homogeneity.** Zero variance across final axis scores suggests one overall impression copied across the row; exit 1.
4. **Counterexample.** `counterexample.md` must exist (absent → exit 2) and must *fail* the sealed formula. A counterexample that passes means the rubric has a blind spot; exit 1, add an axis, re-score from the baseline.
5. **Unverified-axis block.** If any axis lacks anchors, measurement or an independent score, no `PASS` is issued. This is the last enforcement point of the honesty invariant.

| Exit | Condition |
|---|---|
| 0 | `PASS` printed |
| 1 | Verdict failure — one of checks 1 through 4 |
| 2 | Evidence file missing, receipt mismatch, or an unverified axis |
| 64 | Wrong argument count |

## Instruments and shipping hygiene

### `measure-skill.sh <skill-dir> <run-dir>`

Measures a Claude Code skill's structure — line counts, fence counts, script and document counts — into `<run-dir>/metrics/`, with a provenance sidecar, written atomically. The first column is the round, so `--simplify` evidence can be compared across rounds. Thresholds promoted into `gate.conf` are judged here by exit code; `gate.conf` is parsed as data and never executed as shell.

| Exit | Condition |
|---|---|
| 0 | Measured, sealed thresholds met |
| 1 | A sealed threshold was not met |
| 2 | Contract violation |
| 64 | Wrong argument count |

### `measure-repo.sh <repo-dir> <run-dir>`

Measures a GitHub repository. M1–M7 are preconditions: a single H1 in a root `README.md`, a definition sentence near the top, a copy-pasteable install command, a license notice, a real root `LICENSE` file the platform recognizes, live links, and relative assets that exist. A precondition failure exits 1 and stops the scoring entirely — it is not diluted into a score. M8–M18 are inputs only: badge and media distance, distance to the first install block, whether requirements are stated next to it, `docs/` size, unlinked documents, releases and tags, workflow test commands, test file counts, changelog size, boundary-related headings, and a full heading dump. They are printed as TSV and decide nothing on their own. A precondition failure outranks a missing-environment condition.

| Exit | Condition |
|---|---|
| 0 | Preconditions passed, inputs written |
| 1 | A precondition was violated — scoring stops |
| 2 | Contract violation |
| 3 | Environment missing |
| 64 | Wrong argument count |

### `install-gate.sh <skill-dir>`

The shipping gate. Everything here is exit 2, because a broken distribution is not a matter of degree.

Refuses: `__MACOSX/`, `.DS_Store` and `._*` residue; a script without an exec bit or a shebang; `SKILL.md` front matter that will not parse, or that declares files which do not exist; a `SKILL.md` over its 130-line ceiling; a missing member of the fixed lists of 6 references and 5 contracts; the string `reference-research` anywhere in the tree; platform brand strings inside `scripts/`, which would mean site-specific logic has leaked out of `channels.yml`; and a failure in any of the 8 exit-code regression fixtures, one of which is the Unicode-filename citation case.

| Exit | Condition |
|---|---|
| 0 | Safe to install |
| 2 | Distribution contract violated |
| 64 | Wrong argument count |
