# novacula design

Status: step 1 implemented (Lake package, correctness gate, term metrics, toy selftest). Every decision below was made with the project owner; changes must be recorded here.

## 1. Purpose

`novacula` assigns an opinionated, deterministic complexity cost to a Lean 4 proof that is already known to be correct. Lower cost means a proof that should be easier for a human to fully understand.

The metric is meant to be optimized over time (by people and by automated provers), so it is designed to resist gaming.

## 2. Non-goals

- **Checking correctness.** That is delegated to external checkers (section 5). Novacula refuses to score anything that has not passed them, but it never tries to be a checker itself.
- **Text analysis of source code.** No regex, no line counting on raw text, no LLM judges.
- **Measuring runtime.** A human accepts a finished computation regardless of how long it ran.

## 3. Principles

These are guiding principles, not laws. When a rule below produces an absurd result, fix the rule and record why.

1. **Large differences are meaningful, small ones are not.** The main use is comparing two proofs of the same theorem: a large cost gap should strongly indicate a much more human-friendly proof. Comparing proofs of different theorems is allowed but only means "this one is likely more complex" (Pythagoras vs. Cardano's formula).
2. **Correctness is a precondition, not a score component.** Incorrect, incomplete, or unsanctioned-axiom proofs are rejected, never scored.
3. **Determinism.** The output depends only on: Lean version, Novacula version, dependency commits, fame snapshot, weight profile. Running twice with the same inputs must give byte-identical output.
4. **Only kernel terms and syntax trees are analyzed.** Metrics come from kernel `Expr`s, elaborated `Syntax`, and InfoTrees, never from source text.
5. **Citing beats redoing work.** Using an existing result must never cost more than reproving it locally.
6. **An obscure citation costs about the same as a local copy.** A dependency with no fame (e.g. a repo with ~10 stars that nobody cites) costs roughly what inlining its proof would. This removes any incentive to split one proof across several repositories, unless those pieces become famous on their own.
7. **Fame rewards familiar tools.** Famous results cost less than obscure ones. Over time this should surface the powerful tools humans ought to know, because proofs built on familiar tools are easier to understand.
8. **Everything the kernel sees counts, including automation.** Lemmas pulled in by `simp`, `omega`, `ring`, etc. count like hand-written citations, discounted by fame. Tactic infrastructure that is used everywhere ends up famous, so readable one-line tactic proofs are not punished for their internal proof terms.
9. **Computation is free for humans, code is not.** `decide`, `rfl` by evaluation, and `native_decide` are costed by the complexity of the code that runs (the predicate, the `Decidable` instance, any `implemented_by` implementation), never by how long it runs.
10. **Several metrics, user-chosen weights.** Novacula outputs every raw metric plus scores for named weight profiles. It ships a default profile; users can publish their own, so a community default can emerge.
11. **Transitivity.** The cost of an external declaration is computed by running the same full metric on its own repository (cached), not by a cheaper stand-in.
12. **Pure Lean.** If something is really better done elsewhere, the other language is Rust, not Python.

## 4. Cost model

### 4.1 Terms

- `T`: the target declaration being scored.
- For a declaration `d`:
  - `deps(d)`: constants referenced by the kernel term of `d` (type and value).
  - `local(d)`: whether `d` belongs to the package being scored.
  - `fame(d) ∈ [0, 1]`: 0 for local declarations; see section 6.
  - `body(d) ≥ 0`: complexity of `d`'s own proof or definition, excluding its dependencies (section 7).
  - `cite(d) ≥ 0`: the flat cost of citing a fully famous declaration (a profile weight, possibly scaled by prominence).

### 4.2 Recursion as fame-weighted reachability

Walking from `T`, each declaration is charged according to how famous it is, and fame also damps how much of its own dependency tree is charged:

```
w(T) = 1
w(v) = max over edges u → v of  w(u) · (1 − fame(u))

cost(T) = Σ over reachable d with w(d) > 0 of
            w(d) · ( fame(d) · cite(d) + (1 − fame(d)) · body(d) )
```

Properties:

- A fully famous dependency (`fame = 1`) costs `cite` and its dependency tree adds nothing.
- A zero-fame dependency costs exactly what copying its proof (and its whole tree) locally would. That is principles 5 and 6.
- Shared dependencies are charged once, at the largest weight they are reached with, so a DAG is never double-counted. Maximizing a product of factors in `[0, 1]` is a shortest-path problem on `−log w`, so a Dijkstra-style walk gives an order-independent result.
- A weight cutoff (profile parameter, e.g. `w < 1e-6`) bounds the walk. The cutoff is part of the determinism inputs.

### 4.3 What counts as a dependency

Definitions are dependencies exactly like theorems, and go through the same fame-weighted formula. This includes definitions that appear in the target's own statement.

- **Charged once.** A definition reached many times is charged once, at its highest weight, like any other node. However complex a definition is, a human only has to understand it once.
- **Invoking an obscure definition costs what spelling it out would.** At `fame = 0` the formula charges the definition's own body, which is what writing the same conditions inline as explicit hypotheses would cost. So moving part of a theorem into a definition never gains anything by itself.
- **Fame discounts invocation proportionally.** "Let `f` be continuous" costs little, because `Continuous` is famous. Spelling out the epsilon-delta condition inline costs more. Asking for `LipschitzWith` costs more than asking for `Continuous`, because it is less widely known.
- Generality of a hypothesis and strength of the conclusion are not scored directly. A stronger result is expected to earn fame, and fame is where that shows up.
- Axioms in the sanctioned set: cost 0 (they are the foundation, not proof work).

Consequence: two proofs of the same theorem share the statement's cost exactly, so it is a constant offset that never changes their ordering. It does matter for the coarse cross-theorem signal, which is correct: a theorem stated in obscure vocabulary is harder to understand.

## 5. Correctness gate

Before scoring, all of the following must hold, or Novacula exits with a rejection and no score:

1. `lean4checker` passes on the environment containing `T`.
2. `nanoda` passes on the same environment.
3. The axioms `T` depends on (found by walking kernel terms, not by trusting `#print axioms` output from the submitted file) are a subset of the sanctioned set.

Default sanctioned axioms (profile-overridable, recorded in output):

- `propext`, `Quot.sound`, `Classical.choice`, `Lean.ofReduceBool`, `Lean.trustCompiler`
- the per-use axioms `native_decide` mints, named `<decl>._native.<tactic>.ax_N`, which assert the result of one compiled evaluation. Sanctioned by decision; the evaluated code is still costed, per principle 9.

## 6. Fame

`fame(d)` combines, with profile weights:

- **Repository fame:** stars from a frozen snapshot (e.g. from Reservoir), mapped through a log-sigmoid. Around 10 stars maps to near zero.
- **Declaration prominence within the indexed corpus:**
  - kernel in-degree: how many distinct declarations in other modules and repositories use `d`
  - how many distinct downstream repositories use `d`
  - membership in curated famous lists (Mathlib `docs/100.yaml`, `docs/1000.yaml`)
- **Caps:** `private` declarations, auto-generated auxiliaries (`_aux`, `.proof_n`, `match_n`, `_eq_n`), and `@[deprecated]` aliases have prominence capped. A deprecated alias is resolved to its target first.

A famous repository does not make every internal lemma famous: repository fame and declaration prominence are combined, not simply added.

Fame is a property of a corpus snapshot. Changing the snapshot is an accepted and versioned source of score change.

## 7. Metric families

All metrics are reported raw. Profiles combine them into `body(d)` and `cite(d)`.

### 7.1 Term metrics (every declaration, from kernel `Expr`)

- DAG-shared term size (log scale)
- number of distinct constants referenced
- maximum binder / `let` nesting depth
- branching: applications of recursors and `casesOn` / `match` auxiliaries
- computational checks: for `decide`, `rfl`-by-evaluation, `native_decide`, the body cost of the evaluated predicate and its `Decidable` instance (and `implemented_by` targets), plus a per-use profile surcharge

### 7.2 Syntax metrics (declarations with source, from `Syntax` and InfoTrees)

- tactic count and nesting depth
- cyclomatic-style complexity: 1 + branch points (`cases`, `rcases`, `obtain` patterns, `induction`, `by_cases`, `split`, `match` arms, `<;>` fan-out, `·` focusing blocks)
- maximum number of simultaneously open goals (from `TacticInfo` goal lists)
- tactics per source line, using syntax positions, not text
- declarative structure: `have` / `show` / `calc` steps with non-trivial stated types that are actually used later. Unused or trivial ones earn nothing, which prevents farming `have h : True := trivial`.

### 7.3 Profiles

A profile is a JSON file (parsed with `Lean.Json`) containing metric weights, fame parameters, the weight cutoff, and the sanctioned axiom set. The profile's hash is part of the output.

## 8. Toolchain policy

- Development targets the latest stable Lean release (`elan` `stable`), currently v4.34.0. The pin lives in `lean-toolchain`.
- One run of Novacula uses one Lean version (the "Novacula toolchain").
- Dependencies are re-checked and rebuilt on Novacula toolchain, or oleans already built by that exact toolchain are trusted. Re-checking long developments is an accepted cost.
- A dependency that does not build on Novacula toolchain cannot be scored; this is reported, not worked around.
- Novacula source supports a window of current Lean versions (CI matrix). Version-specific API differences live in one shim module.

## 9. Caching

- Key: (repository, commit, Lean version, Novacula version, profile hash where relevant).
- Value: per-declaration raw metrics (term and syntax) as JSON.
- Filled lazily per module: a huge repository is only elaborated for the modules the target actually reaches.
- Scores are recomputed from cached raw metrics; only raw metrics are cached, never final scores.

## 10. Architecture

A single Lake package, `Novacula`:

| Module | Responsibility |
|---|---|
| `Novacula/Gate.lean` | run lean4checker and nanoda, sanctioned-axiom walk |
| `Novacula/Term.lean` | term metrics from kernel `Expr` |
| `Novacula/Syntax.lean` | re-elaboration via `Lean.Elab.Frontend`, InfoTree and syntax metrics |
| `Novacula/Graph.lean` | dependency extraction and the fame-weighted walk (4.2) |
| `Novacula/Fame.lean` | corpus index, prominence, snapshot loading |
| `Novacula/Profile.lean` | profile parsing and metric combination |
| `Novacula/Cache.lean` | raw metric cache |
| `Novacula/Compat.lean` | Lean version shims |
| `Main.lean` | CLI: `score`, `compare`, `index` |

Output of `score` is JSON: determinism inputs, gate results, raw metrics per reached declaration, per-profile scores, and a breakdown of the top cost contributors.

## 11. Testing

- **Toy fixtures (no Mathlib, fast):**
  - gate: `sorry`, custom axiom, `debug.skipKernelTC` are rejected
  - `native_decide` accepted and costed by code
  - the same `decide` check over a range of 100 vs 10000 costs about the same
  - a famous import costs less than a local reproof
  - an obscure import costs about the same as a local copy
  - splitting a proof into two obscure fake repositories gives no gain
  - citing two results where one suffices costs more
  - moving hypotheses into a local definition changes nothing
  - a famous hypothesis (fake `Continuous`) costs less than the same condition spelled out inline, and less than a rarely used one (fake `LipschitzWith`)
  - farmed trivial `have`s earn nothing
  - determinism: two runs give byte-identical output
- **Mathlib pairs:** alternative proofs of the same theorem, labeled by preference; the preferred proof must win by a margin.
- **Scale:** Anthropic's complete FLT formalization (sampled subtrees), `openai/NavierStokesAndEuler`, Mathlib itself (also the fame index source).

## 11b. History tracking

`targets.txt` lists tracked declarations, remarkable results first. `make track` appends their raw
metrics to `data/history.csv` with the date and Novacula revision, so the metric's own evolution can
be charted in the README later. Rows carry the Lean version, because scores are only comparable
within one version tuple (section 3, principle 3).

## 12. Open questions

- A normalization that makes cross-theorem comparisons more than a coarse signal.
- Redundancy (cosine law plus Pythagoras): the model already prefers one citation over two. Deterministic ablation ("is cited lemma A provable from cited lemma B with light automation?") is deferred.
- Explicit reinvention detection (a local lemma whose normalized statement hash matches a library declaration): comparisons already favor the citing proof, so this is report-only if built at all.
- Fame snapshot source and refresh policy.
- Weight fitting from labeled pairs (pairwise logistic regression, in Lean).

## 13. Known pitfalls

- **Goodhart's law.** Assume an optimizer will game any metric. Keep a held-out set of labeled pairs that weight fitting never sees.
- **Aliases and wrappers** used to launder citations: resolve `abbrev`/alias chains before scoring.
- **Toolchain drift:** big repositories may not build on Novacula toolchain.
- **Cost of the full recursive metric** on multi-million-line developments: lazy per-module caching is mandatory.
- **Mathlib refactors** rename and move lemmas; labeled pairs must be re-run on each new pin.
- **Fame feedback loop:** prominence is measured on the corpus that the metric itself is pushing toward.
