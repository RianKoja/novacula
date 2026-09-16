# Novacula

A deterministic complexity metric for Lean 4 proofs. Lower is better: a large gap between two
proofs of the same theorem should mean one of them is much easier for a human to understand.

The name is from *novacula Occami*, Occam's razor. Cutting away what a proof does not need is
what the metric rewards.

Novacula does not check proofs. Correctness is a precondition: lean4checker and nanoda must
pass and the axioms must be in the sanctioned set, or nothing gets scored.

## The idea in one formula

Fame decides how much of a dependency you pay for:

```
w(T) = 1
w(v) = max over edges u → v of  w(u) · (1 − fame(u))

cost(T) = Σ over reachable d of  w(d) · ( fame(d) · cite(d) + (1 − fame(d)) · body(d) )
```

- Citing a famous theorem is cheap, and you do not pay for the proof behind it.
- Citing something nobody uses costs about what copying its proof into your file would, so
  splitting a proof across repositories to hide complexity gains nothing.
- Definitions work the same way: "let f be continuous" is cheap, spelling out epsilon-delta by
  hand is not, and a rarely used condition sits in between.
- Computation is free, code is not: a `decide` over a range of 10000 costs what the same check
  over a range of 10 costs, because a human accepts a finished check either way.

`DESIGN.md` has the full model, the principles behind it, and the open questions.

## Metric history

Tracked declarations are scored daily and appended to `data/history.csv`. Each shaded band is one
Lean version: a step at a band edge is the toolchain's doing, while movement inside a band comes
from the proofs themselves or from shifting fame of what they cite.

![Metric history](docs/history.svg)

## Usage

```
make test                                       # build and run the selftest
make score MODULE=Init DECL=Nat.add_comm        # JSON report for one declaration
make track                                      # append today's metrics and redraw the chart
make chart                                      # redraw the chart only
```

External checkers run only when configured:

```
LEAN4CHECKER=/path/to/exe NANODA=/path/to/exe make score MODULE=... DECL=...
```

## Status

Early. The correctness gate, the term metrics, the history tracking and this chart work. The
fame-weighted dependency walk, the syntax metrics and the weight profiles are next, in that order.
