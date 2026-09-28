# novacula

Deterministic complexity cost for correct Lean 4 proofs. Lower cost means easier for a human to fully understand. Read `DESIGN.md` before changing anything.

## Keep docs current

- Every decision or guideline the project owner gives goes into `DESIGN.md` (decision + reason) in the same change that implements it.
- This file holds only what an implementer needs day to day: rules, commands, layout.

## Hard rules

- Pure Lean 4. If something is really better in another language, use Rust, never Python.
- Never analyze source text. Only kernel `Expr`, elaborated `Syntax`, and InfoTrees.
- Never measure runtime. Computational checks are costed by their code.
- Not a correctness checker. lean4checker and nanoda must both pass, and axioms must be in the sanctioned set, or the tool rejects without scoring.
- Deterministic: same (Lean version, Novacula version, dependency commits, fame snapshot, profile) gives byte-identical output. No wall clock, no hash-map iteration order, no network at scoring time.
- Obscure citation ≈ local copy; famous citation is cheap; citing never costs more than reproving (DESIGN.md sections 3 and 4).
- Definitions go through the same formula as theorems, statement definitions included: invoking an obscure definition costs what spelling it out inline would, and fame discounts it.
- All raw metrics are always emitted; profiles only combine them.
- Version-specific Lean API usage lives only in `Novacula/Compat.lean`.
- No em dashes in code, comments, docs, or commit messages.

## Commands

    make test                               # build everything and run the selftest
    make score MODULE=Fixtures DECL=Fixtures.branchy
    make track                              # append today's metrics and redraw the chart
    make chart                              # redraw docs/history.svg only
    make history                            # last rows of the history

Under the hood:

    lake build                              # library and the `novacula` exe
    lake build Fixtures                     # toy fixtures in test/
    lake exe novacula selftest                # toy checks, must stay green
    lake exe novacula score <Module> <Decl>   # JSON report for one declaration
    lake exe novacula badge <csv> <svg>       # badge from a history file

External checkers are invoked only when configured: `LEAN4CHECKER=leanchecker` (ships with the
toolchain) and `NANODA=scripts/nanoda-check` (needs `LEAN4EXPORT` and `NANODA_BIN`). Unconfigured
checkers are reported as `not-configured`, `gate.ok` stays false, and no cost is reported.

Cost parameters come from `NOVACULA_CORPUS` (e.g. `Mathlib`), `NOVACULA_FAME_PIVOT` and
`NOVACULA_FAME_EXP` until profiles exist. The raw-metric cache lives in `.lake/novacula-cache`
(`NOVACULA_CACHE`); bump `metricsVersion` in `Novacula/Graph.lean` whenever `termMetrics` changes.

To score another project, rebuild Novacula with its `lean-toolchain` and run the binary under its
`lake env`. `action.yml` does exactly this in CI.

## History tracking

`make track` appends one row per declaration in `targets.txt` to `data/history.csv`, tagged with
the date and Novacula revision passed in by the Makefile. The tool never reads a clock, so an
old revision reproduces its old rows. Reruns on the same date and revision are no-ops.
`make track` then redraws `docs/history.svg`, the chart shown in README.md: one line per tracked
declaration, one shaded vertical band per Lean version, integer coordinates so the same history
renders identical bytes. `Module *` in `targets.txt` tracks every theorem under `Module`.
The daily Kestra flow `kbm.novacula/novacula-daily` runs this on the latest stable Lean and
pushes the result.

## Two clones push to main

The daily flow works in its own clone (`~/Desktop/selfhosting/novacula/work`) and pushes the
day's data and chart. Always `git pull --rebase origin main` before pushing from a dev clone.

## Tests

- Toy fixtures without Mathlib for every principle in DESIGN.md section 11; these must stay fast.
- Mathlib preference pairs and scale repos (Anthropic FLT, openai/NavierStokesAndEuler, Mathlib) run as a separate slow suite.
- Every new metric or cost rule adds a fixture that fails if the rule breaks.
