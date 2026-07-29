# Contributing

The product of this repository is its gates. That shapes what gets accepted.

## What is welcome

- **Bug reports with a reproduction.** The run directory is designed to be shareable: the sealed configs, the fetch log and the round records usually tell the whole story. Strip anything sensitive from `sources/` first.
- **A gate that can be bypassed.** This is the most valuable report we can receive. Please read [SECURITY.md](SECURITY.md) first — a working bypass goes through private reporting, not a public issue.
- **A new measurement instrument.** `measure-skill.sh` and `measure-repo.sh` cover skills and repositories. A new target type needs an instrument that follows the same contract: `<target> <run-dir>`, atomic TSV write into `<run-dir>/metrics/`, a `.tsv.prov` sidecar, a `round` first column, and a threshold judgement by exit code. `skill/references/instruments.md` is the contract.
- **A new channel declaration.** Adding a channel means adding an entry to `contracts/channels.yml` with its rungs, backends, probes and match patterns. It does not mean adding code.
- **Corrections to the documentation, including the genealogy.** If a claim in [docs/genealogy.md](docs/genealogy.md) is wrong, say so with the source. A verdict that flips from CONFIRMED to REFUTED is a contribution, not an embarrassment.

## What will be declined

- **Any bypass of a gate.** A `--force` flag, a `SKIP_VERIFY` environment variable, a "trust me" mode, a configuration key that turns exit 2 into a warning. These are declined regardless of how convenient the use case is, because a bypass that exists will be used, and at that moment the axis it guards stops meaning anything.
- **Weakening a check to make a test pass.** If a check is wrong, fix the check and bring a fixture that demonstrates the correct behaviour. Do not widen a comparison until the failure disappears.
- **Per-site scraping logic inside `scripts/`.** Platform strings belong in `contracts/channels.yml`. `install-gate.sh` fails the tree if they appear anywhere else, and that gate is not negotiable — it is what keeps the access layer delegated instead of slowly reimplemented.
- **Credential handling of any kind.** Login flows, cookie reading, token storage. `auth_required` is a terminal verdict that drops to the manual rung. This is a scope boundary, not a missing feature.
- **Bilingual `skill/references/`.** The skill operates in Korean; this repository's public documentation is English. Bilingual maintenance is paid at one layer on purpose.

## Requirements for a change to enforcement

Anything that touches `skill/scripts/` must arrive with all four of these.

1. **A regression fixture that fails before the change and passes after it.** `install-gate.sh` runs 8 exit-code fixtures; if your change alters what a script accepts or refuses, it belongs in that set.
2. **`bash -n` clean across every script in the tree.**
3. **`install-gate.sh <skill-dir>` exiting 0.** This checks shebangs, exec bits, the front matter against the declared files, the `SKILL.md` line ceiling, banned strings and the fixtures.
4. **No regression on non-ASCII paths.** Korean filenames, spaces and NFD-normalized paths currently work. They stopped working once before, silently, and legitimate anchors were rejected as uncited for it.

If your change alters an exit code, the meaning of an exit code, a field name in a contract file, or the name of a run artifact, update [docs/gates.md](docs/gates.md) and `skill/references/contracts.md` in the same pull request. Those two documents are the reference other people work from; a contract change that only lives in the code is a trap.

## Requirements for a change to documentation

- **Quotations are literal.** Never tidy a quoted excerpt, translate it, or replace an omitted middle with an ellipsis. This is the same rule the skill enforces on its own evidence, and it applies to prose written about the skill.
- **A claim you cannot re-open is not a claim.** If you cannot reach the source, mark it UNVERIFIED and leave it visible rather than removing the inconvenience.
- **Korean documents are written in Korean**, in a technical written register, not translated from English. English documents are written in plain technical English. Neither is a rendering of the other; `README.md` and `README.ko.md` are two originals covering the same ground.

## Pull requests

Keep them small and single-purpose — the same discipline the loop imposes, for the same reason: when several things change at once and the result is worse, nobody can tell which one did it.

State in the description what the change refuses that was previously accepted, or what it now accepts that was previously refused. If the answer to both is "nothing", say that too.
