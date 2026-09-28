# novacula design

Status: step 2 implemented. Lake package, correctness gate, term metrics, recursive cost with interim fame, raw-metric cache, history chart, badge, and a GitHub Action. Not yet built: syntax metrics, weight profiles, fame snapshot. Every decision below was made with the project owner, and changes must be recorded here.

## 1. Purpose

`novacula` assigns a deterministic complexity cost to a Lean 4 proof that is already known to be correct. A lower cost means the proof should be easier for a human to understand completely.

People and automated provers are expected to optimize the metric, so it is designed to resist gaming.

## 2. Non-goals

- **Checking correctness.** External checkers do this (section 5). Novacula refuses to score anything they have not accepted, but it is not a checker.
- **Text analysis of source code.** No regular expressions, no line counts on raw text, no LLM judges.
- **Measuring runtime.** A human accepts a finished computation regardless of how long it ran.

## 3. Principles

These principles guide the rules. When a rule gives an absurd result, the rule is changed and the reason recorded.

1. **Large differences are meaningful, small ones are not.** The main use is comparing two proofs of the same theorem, where a large gap should indicate a much more readable proof. Comparing proofs of different theorems is allowed, but only as a coarse signal (Pythagoras vs. Cardano's formula).
2. **Correctness is a precondition, not a score component.** Incorrect, incomplete, or unsanctioned-axiom proofs are rejected, never scored.
3. **Determinism.** The output depends only on the Lean version, Novacula version, dependency commits, fame corpus, and cost parameters. Two runs with the same inputs give byte-identical output.
4. **Only kernel terms and syntax trees are analyzed.** Metrics come from kernel `Expr`s, elaborated `Syntax`, InfoTrees, and other elaborator data, never from source text.
5. **Citing beats redoing work.** Using an existing result never costs more than reproving it locally.
6. **An obscure citation costs about as much as a local copy.** A dependency nobody else uses costs roughly what inlining its proof would. Splitting one proof across several repositories therefore gains nothing unless the pieces become famous on their own.
7. **Fame rewards familiar tools.** Famous results cost less than obscure ones. Over time this should surface the tools humans ought to know.
8. **Everything the kernel sees counts, automation included.** Lemmas pulled in by `simp`, `omega`, `ring` and similar tactics count like hand-written citations, discounted by fame. Tactic infrastructure used everywhere becomes famous, so short tactic proofs are not punished for their large proof terms.
9. **Computation is free for humans, code is not.** `decide`, `rfl` by evaluation, and `native_decide` are costed by the code that runs (the predicate, the `Decidable` instance, any `implemented_by` implementation), never by how long it runs.
10. **Several metrics, user-chosen weights.** Novacula outputs every raw metric and scores for named weight profiles. It ships a default profile, and users can publish their own.
11. **Transitivity.** An external declaration is costed by the same full metric as local ones, from its own kernel term, not by a cheaper stand-in.
12. **Pure Lean.** When something is better done in another language, that language is Rust, not Python.

## 4. Cost model

### 4.1 Terms

- `T`: the target declaration, or set of declarations, being scored.
- For a declaration `d`:
  - `deps(d)`: constants in the kernel term of `d` (type and value), plus the constructors of an inductive type, since understanding a type includes knowing how its values are built.
  - `local(d)`: whether `d` belongs to the project being scored (section 4.4).
  - `fame(d) ∈ [0, 1)`: 0 for local declarations; see section 6.
  - `body(d)`: the DAG term size of `d` (type and value), its dependencies excluded.
  - `cite(d)`: the DAG term size of the statement of `d` alone, the part a reader of a citation has to take in.
  - Sanctioned axioms have `body = cite = 0`: they are the foundation, not proof work.

`body` and `cite` are interim single metrics. Weight profiles (section 7.3) will combine all raw metrics into them.

### 4.2 Recursion as fame-weighted reachability

The cost is recursive: every declaration `T` reaches is costed by the same rule as `T`, down to the axioms. Fame decides how much of each one is charged:

```
w(root) = 1                 for each declaration in T
w(v)    = max over edges u → v of  w(u) · (1 − fame(u))

cost(T) = Σ over reachable d with w(d) ≥ cutoff of
            w(d) · ( fame(d) · cite(d) + (1 − fame(d)) · body(d) )
```

Properties:

- A dependency with fame near 1 costs about `cite`, and its own dependencies are barely charged.
- A dependency with fame 0 costs what copying its proof, and its whole dependency tree, into the project would. These are principles 5 and 6.
- Every declaration is charged once, at the largest weight it is reached with. A naive recursion `cost(T) = body(T) + Σ cost(dep)` would charge a lemma shared by `k` paths `k` times, which grows exponentially on a library such as Mathlib. Maximizing a product of factors in `[0, 1]` is a shortest-path problem on `−log w`, so a Dijkstra walk gives an order-independent result. Ties are broken by name, and the float sums follow the walk order, so the result is deterministic.
- Scoring a set `T` of several declarations charges what they share once. The history records each tracked theorem alone and the whole set (the `*` row); the badge shows the set.
- The cutoff (default `10⁻⁶`) bounds the walk and is part of the determinism inputs.

### 4.3 Computation order

Decision: the cost is computed in three phases, so that fame is applied only after every raw value it discounts is known.

1. **Raw metrics.** Collect every declaration reachable from `T` (a worklist, not recursion, so million-declaration developments do not overflow the stack) and compute `body` and `cite` for each. These values depend only on the declaration's own term, so they are cached per module and reused while the Lean version and the module's olean are unchanged (section 9).
2. **Fame** of every reached declaration, from one scan of the corpus (section 6).
3. **The walk** of section 4.2.

Reason: raw metrics are the expensive, reusable part. Fame and the walk depend on the corpus and on parameters, so keeping them out of the cache means a change of fame or parameters never invalidates it.

### 4.4 What counts as a dependency

Definitions are dependencies exactly like theorems and go through the same formula, including definitions that appear in the target's own statement.

- **Charged once.** A definition reached many times is charged once, at its highest weight. A human only has to understand it once.
- **Invoking an obscure definition costs what spelling it out would.** At `fame = 0` the formula charges the definition's own body, which is what writing the same conditions inline as hypotheses would cost. Moving part of a theorem into a definition therefore gains nothing by itself.
- **Fame discounts invocation proportionally.** "Let `f` be continuous" costs little because `Continuous` is famous. Spelling out the epsilon-delta condition inline costs more. `LipschitzWith` costs more than `Continuous` because fewer declarations use it.
- The generality of a hypothesis and the strength of a conclusion are not scored directly. A stronger result is expected to earn fame.

Two proofs of the same theorem share the statement's cost exactly, so the statement adds a constant that never changes their order. It does affect the coarse cross-theorem signal, as it should: a theorem stated in obscure vocabulary is harder to understand.

The project being scored is its Lake package: the modules built into its own `.lake/build`, as opposed to the toolchain and the packages under `.lake/packages`. Decision: locality comes from where the olean lives, not from the module name, because one package can have several roots (`NavierStokes`, `Euler`, `ComparatorChallenges`).

## 5. Correctness gate

Before scoring, all of the following must hold. Otherwise Novacula reports a rejection and no cost:

1. `leanchecker` (lean4checker, shipped with every toolchain since Lean 4.28) replays every module of the project. Configured with `LEAN4CHECKER`, called as `exe <Module>` per module.
2. `nanoda` accepts the targets and everything they depend on. Configured with `NANODA`, called as `exe <Module> <Decl>...`. `scripts/nanoda-check` is the adapter: it exports the declarations with lean4export and pipes the export to nanoda.
3. The axioms `T` depends on, found by walking kernel terms rather than by trusting `#print axioms` in the submitted file, are a subset of the sanctioned set.

Default sanctioned axioms (profile-overridable, recorded in output):

- `propext`, `Quot.sound`, `Classical.choice`, `Lean.ofReduceBool`, `Lean.trustCompiler`
- the axioms `native_decide` mints, named `<decl>._native.<tactic>.ax_N`, which assert the result of one compiled evaluation. Sanctioned by decision. The evaluated code is still costed, per principle 9.

Raw metrics are always reported. Only the cost is withheld from a rejected proof.

## 6. Fame

### 6.1 Target model

`fame(d)` combines, with profile weights:

- **Repository fame:** stars from a frozen snapshot (e.g. from Reservoir), mapped through a log-sigmoid. About 10 stars maps to near zero.
- **Declaration prominence within the indexed corpus:**
  - kernel in-degree: how many distinct declarations in other modules and repositories use `d`
  - how many distinct downstream repositories use `d`
  - membership in curated lists (Mathlib `docs/100.yaml`, `docs/1000.yaml`)
- **Caps:** `private` declarations, generated auxiliaries (`_aux`, `.proof_n`, `match_n`, `_eq_n`), and `@[deprecated]` aliases have capped prominence. A deprecated alias is resolved to its target first.

A famous repository does not make every internal lemma famous: repository fame and declaration prominence are combined, not added.

Fame is a property of a corpus snapshot. Changing the snapshot is an accepted, versioned source of score changes.

### 6.2 Interim model (implemented)

Until the snapshot exists, fame is kernel in-degree alone, measured on the loaded environment:

- The corpus is everything the targets import plus the modules in `CostParams.corpus` (`NOVACULA_CORPUS`). Decision: projects that depend on Mathlib are scored with the corpus `Mathlib`. Reason: with only the imported part of Mathlib as corpus, widely used lemmas such as `MeasureTheory.integral_map` had fame below 0.1 because most of their users were not loaded, and fame depended on which files the project happened to import.
- A user of `d` is a distinct declaration outside the scored project and outside `d`'s own module. A project therefore cannot make its own lemmas famous.
- Generated auxiliaries (`Foo.proof_1`, `Foo.match_2`, `Foo._f`, `_private` helpers) belong to their owner `Foo`. They earn no fame of their own but share the owner's, and a use by an auxiliary counts as a use by its owner. Reason: automation such as `omega` and `simp` places most of its lemma uses inside auxiliaries, so skipping them left core automation lemmas at fame 0. Conversely, a capped auxiliary with fame 0 let the full weight of a famous definition flow into its proof.
- `n` users give `fame = nᵏ / (nᵏ + pᵏ)`. Defaults: pivot `p = 4`, `k = 1`, so 1 user gives 0.2, 4 give 0.5, and 100 give 0.96. Reason: measured on `msc_proofs` with the Mathlib corpus, `p = 16, k = 2` put more than 95% of each analysis theorem's cost in long chains of Mathlib lemmas with a handful of users each (`trendLine`: 1.66M), and `p = 16, k = 1` still gave 0.61M. `p = 4, k = 1` gave 75k, where the project's own proofs are a visible share of the cost. These are profile parameters (`NOVACULA_FAME_PIVOT`, `NOVACULA_FAME_EXP`) and will be refit on labeled pairs.

Powers are computed by multiplication, so the result does not depend on the platform's `libm`. The corpus scan runs in parallel over modules. Its counts are sums, so scheduling cannot change them.

## 7. Metric families

All metrics are reported raw. Profiles combine them into `body(d)` and `cite(d)`.

### 7.1 Term metrics (every declaration, from kernel `Expr`)

- DAG-shared term size, and the same for the statement alone
- number of distinct constants referenced
- maximum binder and `let` nesting depth
- branching: applications of recursors and `casesOn` / `match` auxiliaries
- computational checks: for `decide`, `rfl` by evaluation and `native_decide`, the evaluated predicate and its `Decidable` instance are reached by the walk like any other dependency, so their code is costed

### 7.2 Syntax metrics (declarations with source, from `Syntax` and InfoTrees; not yet built)

- tactic count and nesting depth
- cyclomatic complexity: 1 + branch points (`cases`, `rcases`, `obtain` patterns, `induction`, `by_cases`, `split`, `match` arms, `<;>` fan-out, `·` focusing blocks)
- maximum number of simultaneously open goals (from `TacticInfo` goal lists)
- tactics per source line, using syntax positions
- declarative structure: `have` / `show` / `calc` steps with non-trivial stated types that are used later. Unused or trivial steps earn nothing, which prevents farming `have h : True := trivial`.

### 7.3 Profiles

A profile is a JSON file (parsed with `Lean.Json`) containing metric weights, fame parameters, the weight cutoff, and the sanctioned axiom set. Its hash is part of the output. Until profiles exist, `CostParams` holds the parameters, read from environment variables and echoed in every report.

## 8. Toolchain policy

- Development targets the latest stable Lean release, currently v4.34.1. The pin lives in `lean-toolchain`.
- One run of Novacula uses one Lean version.
- An olean can only be read by the Lean version that wrote it. Decision: to score another project, Novacula is rebuilt on that project's own toolchain and runs inside its `lake env`. The Lean version is recorded in every row, shown on the badge, and marked as a band on the chart, since scores are comparable only within one version.
- A dependency that does not build on the chosen toolchain cannot be scored. This is reported, not worked around.
- Novacula supports a window of Lean versions (builds and passes the selftest on 4.33.1, 4.34.0-rc2 and 4.34.1). Version-specific API use lives in `Novacula/Compat.lean`.

## 9. Caching

- Key: (Lean version, metrics version, module, module key). The module key is the `.olean.hash` Lake writes next to each olean, or `core` for toolchain modules, which the Lean version fixes. A module with neither is recomputed on every run.
- Value: the raw term metrics of every constant the module declares, in olean order, as one JSON file under `.lake/novacula-cache` (or `NOVACULA_CACHE`).
- Filled lazily: only modules the targets reach are computed.
- Only raw metrics are cached, never costs. `metricsVersion` is bumped whenever `termMetrics` changes.
- The GitHub Action keeps the cache between runs with `actions/cache`.

## 10. Architecture

A single Lake package, `Novacula`:

| Module | Responsibility | State |
|---|---|---|
| `Novacula/Gate.lean` | external checkers, sanctioned-axiom walk | built |
| `Novacula/Term.lean` | term metrics from kernel `Expr` | built |
| `Novacula/Graph.lean` | reachability, raw-metric cache, interim fame, the walk (4.2, 4.3, 6.2, 9) | built |
| `Novacula/Chart.lean` | history chart and badge (11b) | built |
| `Novacula/Compat.lean` | Lean version shims | built |
| `Novacula/Syntax.lean` | re-elaboration via `Lean.Elab.Frontend`, InfoTree and syntax metrics | planned |
| `Novacula/Fame.lean` | corpus snapshot, repository stars, curated lists | planned |
| `Novacula/Profile.lean` | profile parsing and metric combination | planned |
| `Main.lean` | CLI: `score`, `csv`, `chart`, `badge`, `selftest` | built |
| `action.yml` | GitHub Action (section 11c) | built |

`score` prints JSON: determinism inputs, gate results, the target's raw metrics, and the cost with its largest contributors.

## 11. Testing

- **Toy fixtures (no Mathlib, fast), in the selftest:**
  - gate: `sorry` and a custom axiom are rejected
  - `native_decide` is accepted and costed by its code
  - the same `decide` check over a range of 20 and of 200 has the same term metrics and the same cost
  - a famous citation (`Nat.add_comm`) costs less than a local reproof
  - citing two results where one suffices costs more
  - a lemma shared by two scored theorems is charged once
  - raw metrics read back from the cache give the same costs
  - determinism: two runs give byte-identical output
- **Still to add:** `debug.skipKernelTC` rejected; an obscure import costs about the same as a local copy; splitting a proof into two obscure fake repositories gives no gain; moving hypotheses into a local definition changes nothing; a famous hypothesis (fake `Continuous`) costs less than the same condition spelled out and less than a rarely used one (fake `LipschitzWith`); farmed trivial `have`s earn nothing.
- **Mathlib pairs:** alternative proofs of the same theorem, labeled by preference; the preferred proof must win by a margin.
- **Scale:** `RianKoja/msc_proofs` (every theorem), `openai/NavierStokesAndEuler` (the four comparator theorems), and Anthropic's `fermats-last-theorem` (section 13).

## 11b. History tracking

`targets.txt` lists tracked declarations, remarkable results first. A line `Module Decl` tracks one declaration; `Module *` tracks every user-written theorem of `Module` and its submodules. `make track` appends their raw metrics and cost to `data/history.csv` with the date and Novacula revision. Rows carry the Lean version because scores are comparable only within one version (principle 3). A row has an empty cost when the gate rejected it. `docs/history.svg` draws one line per declaration and one shaded band per Lean version, on a log scale once values span more than two decades. All coordinates are integers, so the same history renders identical bytes.

## 11c. GitHub Action

Decision: projects adopt Novacula with one job in their CI:

```yaml
  novacula:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v5
      - uses: RianKoja/novacula@main
        with:
          theorems: all        # or a list of title theorems
```

plus a `schedule` trigger for periodic reruns. The action builds the project, rebuilds Novacula, lean4export and nanoda on the project's toolchain (section 8), runs the gate, and scores the selected theorems with the Mathlib corpus when the project uses Mathlib. It writes a table to the job summary. On pushes to the default branch, scheduled runs and manual runs, it also appends the rows to `history.csv` on a separate `novacula` branch, replacing any earlier rows of the same day, and redraws `history.svg` and `badge.svg` there. Reason: the README can show the badge and chart from raw URLs without every run adding a commit to `main`. The badge shows the cost of the whole selection and the Lean version.

## 12. Open questions

- A normalization that makes cross-theorem comparisons more than a coarse signal.
- Redundancy (cosine law plus Pythagoras): the model already prefers one citation over two. Deterministic ablation ("is cited lemma A provable from cited lemma B with light automation?") is deferred.
- Explicit reinvention detection (a local lemma whose normalized statement hash matches a library declaration). Comparisons already favor the citing proof, so this would be report-only.
- Fame snapshot source and refresh policy. The interim in-degree fame depends on the corpus version.
- Weight fitting from labeled pairs (pairwise logistic regression, in Lean), including the fame pivot.

## 13. Known pitfalls

- **Goodhart's law.** Assume an optimizer will game any metric. Keep a held-out set of labeled pairs that weight fitting never sees.
- **Aliases and wrappers** used to launder citations: resolve `abbrev` and alias chains before scoring. Not done yet.
- **Toolchain drift:** large repositories may not build on the chosen toolchain.
- **Scale.** Anthropic's Fermat's Last Theorem development has 60,475 modules and 1.05M declarations on Lean 4.33.1. Its own README reports a from-source build of 5.5 hours at 96 jobs, 67 GB under `.lake` plus about 220 GB of temporary C files, and single modules that need 36 GB of memory. No prebuilt oleans are published, and Novacula needs them. Scoring it is therefore a matter of building it once on a machine with that capacity; after that, Novacula's own cost is one environment load, the corpus scan and the walk.
- **Mathlib refactors** rename and move lemmas; labeled pairs must be rerun on each new pin.
- **Fame feedback loop:** prominence is measured on the corpus that the metric itself pushes toward.
