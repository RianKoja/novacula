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
    make track                              # append today's metrics to data/history.csv
    make history                            # last rows of the history

Under the hood:

    lake build                              # library and the `novacula` exe
    lake build Fixtures                     # toy fixtures in test/
    lake exe novacula selftest                # toy checks, must stay green
    lake exe novacula score <Module> <Decl>   # JSON report for one declaration

External checkers are invoked only when their executables are configured:
`LEAN4CHECKER=/path/to/exe NANODA=/path/to/exe lake exe novacula score ...`. Unconfigured
checkers are reported as `not-configured` and `gate.ok` stays false.

## History tracking

`make track` appends one row per declaration in `targets.txt` to `data/history.csv`, tagged with
the date and Novacula revision passed in by the Makefile. The tool never reads a clock, so an
old revision reproduces its old rows. Reruns on the same date and revision are no-ops.
The README chart is not built yet: add it once there is enough history to plot.

## Tests

- Toy fixtures without Mathlib for every principle in DESIGN.md section 11; these must stay fast.
- Mathlib preference pairs and scale repos (Anthropic FLT, openai/NavierStokesAndEuler, Mathlib) run as a separate slow suite.
- Every new metric or cost rule adds a fixture that fails if the rule breaks.
