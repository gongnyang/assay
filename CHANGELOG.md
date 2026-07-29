# Changelog

All notable changes to this project are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For this project, a **breaking change** means any of the following, because they are what other people's runs depend on: an exit code changing meaning, a field being added to or removed from a contract file, a run artifact being renamed or moved, or a gate accepting something it previously refused.

## [0.1.0] — 2026-07-30

First public release. This is a rebuild rather than an increment: the predecessor skill enforced three of its stages and left the rest to the agent's self-report.

### Added

- **Axis 1 (Reach): access, collection and verification.** `reach-init.sh` seals the driving question and the collection floor. `reach-fanout.sh` splits it into 3–7 axes with one collector worker each and rejects near-duplicate axes. `reach-fetch.sh` climbs a fixed L0–L4 ladder declared in `contracts/channels.yml`, logs every attempt, and refuses to declare failure while any rung is untried. `reach-gate.sh` is the single door into Axis 2. `reach-refute.sh` re-verifies anchors from a different worker against the original URL. `reach-doctor.sh` diagnoses rung availability read-only.
- **Anchors as literal substrings.** `reach-gate.sh` compares every `excerpt` against its stored snapshot and refuses anything that is not literally there. Snapshots carry a SHA-256 that is recomputed on every gate run.
- **The junction receipt.** `reach-gate.sh` writes `reach-gate.receipt` recording the hashes of `reach.conf`, `sources.jsonl` and `anchors.jsonl`. `bench-init.sh`, `rubric-lint.sh` and `verdict-gate.sh` refuse to start without it or if those hashes have moved, so Axis 2 cannot run on hand-made files.
- **Enforcement for the previously unenforced stages.** `rubric-lint.sh` (rubric integrity, formerly discipline only), `g2-spawn.sh` (independent scoring with the improvement history physically excluded from the prompt, formerly a prompt template), `verdict-gate.sh` (the only issuer of `PASS`, formerly a checklist), `bench-revert.sh` (restoration with hash evidence, formerly an instruction).
- **Seals.** `reach.conf` and `gate.conf` get a `.seal` sidecar holding their hash; every consumer verifies it on startup.
- **Hash-chained rounds.** `rounds.jsonl` records carry `prev_hash` and `self_hash`; the chain is verified before every append, and the Pareto comparison reads the chain rather than `scores.tsv`.
- **Measurement provenance.** Instruments write a `.tsv.prov` sidecar next to every TSV; only provenance-backed measurements count as evidence.
- **`SIMPLIFY` verdict.** An equal total is now adoptable when a provenance-backed measurement shows line count, file count or dependency count falling. Previously an equal total was always a REVERT, so the inherited "a simplification is a win" rule had no implementation.
- **`measure-repo.sh`**, implementing the repository preconditions M1–M7 (which stop scoring on violation) and the scoring inputs M8–M18 (which decide nothing on their own).
- **`install-gate.sh`**, the shipping gate: residue, shebangs and exec bits, front matter against declared files, the `SKILL.md` line ceiling, banned strings, brand strings in `scripts/`, and 16 exit-code regression fixtures.
- **Documentation:** [docs/how-it-works.md](docs/how-it-works.md), [docs/gates.md](docs/gates.md), [docs/design-decisions.md](docs/design-decisions.md), [docs/genealogy.md](docs/genealogy.md), and this repository's public README in English and Korean.

### Changed

- **The loop now always closes.** PASS at the sealed mark, STOP after three consecutive REVERTs, or STOP outside the sealed scope. The inherited discipline was to run until a human interrupts.
- **A single scalar metric became a multi-axis anchored rubric** with `PASS ⟺ min(axis) ≥ M AND sum(axis) ≥ S`, and the rubric itself is attacked with a counterexample at G3.
- **Usage errors exit `64` everywhere.** Two scripts previously used `2`, which is the code that means the evidence is invalid.
- **A missing python3 exits `3`** from every script, guarded at the top. Eleven scripts previously surfaced it as `127`.
- **Axis IDs must match `^[A-Za-z][A-Za-z0-9_-]*$`,** enforced when the pass mark is sealed rather than discovered at the final gate.
- **Both instruments take `<target> <run-dir>`** and write atomically into `<run-dir>/metrics/` with a `round` first column.
- **The ladder order is read from `channels.yml`,** not from a hardcoded table. Reordering the list is now the way to change the policy.
- **The G2 axis list is read from `gate.conf`,** not parsed from `rubric.md` headings.
- **The `scripts/` size budget was revised** from 1,000–1,400 lines to a ceiling of 3,200 total and 220 per file, to pay for the mechanisms above. The `SKILL.md` ceiling of 130 lines did not move.

### Fixed

- **Unicode filenames are accepted in anchor citations.** The citation regex was ASCII-only while the guidance text advertised Korean filename examples, so legitimate anchors on Korean-language targets were rejected as uncited.
- **A round can no longer be recorded after an unrestored REVERT.** The predecessor announced REVERT and had no way to know whether anything was reverted, which invalidated every measurement after the first failure.
- **`git reset --hard` corrected to `git reset`** in the inherited citation. The original text contains no `--hard`; see [docs/genealogy.md](docs/genealogy.md).
- **macOS archive residue** (`__MACOSX/`, `.DS_Store`) removed from the distribution and now refused by `install-gate.sh`.

### Removed

- **Every citation of `reference-research`.** The predecessor cited it in eight places, with section numbers. It could not be found on the machine that claimed to inherit from it, and no public source matches the quoted text; the principles worth keeping were re-declared as this skill's own clauses. `install-gate.sh` fails the tree if the string returns. Full record in [docs/genealogy.md](docs/genealogy.md).
- **Academic citations that could not be verified against the original** — Goodhart, Campbell, Pareto's 1906 text, the ESL quotation, and the Minto attribution, which was refuted outright. The rules they were used to justify remain; they now stand on the audit findings in [docs/design-decisions.md](docs/design-decisions.md) instead.
- **The STORM structural precedent,** whose supporting quotation joined two non-adjacent paragraphs into one apparent quote.
