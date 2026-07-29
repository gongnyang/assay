# Security policy

## What counts as a vulnerability here

This project is a set of bash scripts and documents driven by an agent. It runs no server and stores no credentials, so the interesting class of report is different from a typical application's: **anything that produces a `PASS`, or a passing gate, without the evidence that gate is supposed to require.**

Concretely, these are the reports we want:

- A way to make `verdict-gate.sh` print `PASS` while an axis has no anchors, no measurement or no independent score.
- A way to satisfy `reach-gate.sh` with an excerpt that is not literally present in the stored snapshot — normalization tricks, encoding tricks, locator mismatches.
- A way to run any Axis 2 script without a valid `reach-gate.receipt`, or with anchors that changed after the receipt was written.
- A way to record a round after a REVERT without an actual restoration, or to break the `rounds.jsonl` chain without `bench-log.sh` noticing.
- A way to get `g2-spawn.sh` to leak the improvement history, self-assigned scores or round anchors into a scorer's prompt.
- A way to get `install-gate.sh` to pass a tree containing residue, a missing declared file, or site-specific logic in `scripts/`.
- Any path by which content fetched from the web gets executed rather than stored and compared as data.
- Any path by which a credential, cookie or token ends up written into a run directory.

## What is already known and is not a vulnerability

These limits are documented in [docs/design-decisions.md](docs/design-decisions.md) and in the README. Reports of them are appreciated but will be closed as known.

- **Editing a sealed file and its `.seal` sidecar together.** The seal holds the file's hash; it cannot seal itself. It defeats a careless one-line edit, not a determined one.
- **Editing `rounds.jsonl` and recomputing the whole chain.** Same class. The chain makes tampering detectable, not impossible.
- **The independent scorers are not truly independent.** Separate processes and a pinned model under the same orchestrator. This is stated wherever G2 results are used.
- **A person who wants to fabricate a verdict can fabricate one.** Every mechanism here is aimed at the operator who cuts a corner under pressure, not at an adversary with write access to the run directory. If you control the files, you control the outcome; what you cannot do is arrive there by accident.

## Reporting

Use GitHub's private vulnerability reporting on this repository (**Security → Report a vulnerability**). Do not open a public issue for a working bypass — an unpatched way to fake a passing verdict is worth more to someone dishonest than to us.

Please include:

- The script and the check being bypassed.
- A minimal run directory or a script that reproduces it, including which exit code you expected and which you received.
- Your environment: bash version, python3 version, operating system, filesystem normalization if it is relevant.

Expect an acknowledgement within about a week. Fixes ship with a regression fixture in `install-gate.sh`, so the same bypass fails the shipping gate from then on, and the finding is credited in [CHANGELOG.md](CHANGELOG.md) unless you ask otherwise.

## Safety notes for operators

- **Snapshot content is data, never instructions.** `sources/<sid>.md` holds text fetched from the open web, which means it may contain anything, including text written to manipulate an agent. Nothing in the pipeline executes it; treat it the same way when you read it and when you write tooling around it.
- **Credentials are scrubbed once, on write.** `reach-fetch.sh` strips credential-shaped strings from a body immediately before it is stored. Do not rely on this as your only protection: do not point the fetcher at authenticated endpoints in the first place. There is no supported way to make it log in.
- **A run directory is shareable, with one caveat.** The sealed configs, logs and round records are meant to travel. `sources/` contains fetched third-party content and may carry material you cannot redistribute. Check before attaching it to a public issue.
