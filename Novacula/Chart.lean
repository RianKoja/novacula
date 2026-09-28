import Novacula.Term

/-! SVG chart of `data/history.csv`. Each tracked declaration is one line; each Lean version
is a shaded vertical band, so a jump caused by a toolchain update is visibly attributable to
the update rather than to the proofs. All coordinates are integers: no float formatting, so
the same history always renders the same bytes. -/

namespace Novacula
open Lean

structure Row where
  date : String
  leanVersion : String
  series : String
  /-- Legend text: the declaration, or "all selected" for a `*` set row. -/
  label : String
  value : Nat
  deriving Inhabited

private def splitCsv (s : String) : Array String :=
  (s.splitOn ",").toArray.map (·.trimAscii.toString)

/-- Read history rows for one metric column, e.g. "size". -/
def readHistory (path : System.FilePath) (metric : String) : IO (Array Row) := do
  let lines ← IO.FS.lines path
  let some header := lines[0]? | throw (IO.userError "empty history file")
  let cols := splitCsv header
  let idx (name : String) : IO Nat := do
    let some i := cols.findIdx? (· == name)
      | throw (IO.userError s!"history file has no column {name}")
    return i
  let (di, li, mi, ci, vi) := (← idx "date", ← idx "leanVersion", ← idx "module", ← idx "decl", ← idx metric)
  let mut rows := #[]
  for line in lines[1:] do
    if line.trimAscii.isEmpty then continue
    let f := splitCsv line
    let get (i : Nat) : IO String := do
      let some v := f[i]? | throw (IO.userError s!"short row: {line}")
      return v
    -- Rows written before a column existed, or rejected by the gate, have no value: skip them.
    let raw := f[vi]?.getD ""
    if raw.isEmpty then continue
    let some value := raw.toNat? | throw (IO.userError s!"metric {metric} is not a number in: {line}")
    let decl ← get ci
    rows := rows.push { date := ← get di, leanVersion := ← get li
                        series := s!"{← get mi}.{decl}"
                        label := if decl == "*" then "all selected" else decl, value }
  return rows

private def palette : Array String :=
  #["#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e",
    "#17becf", "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22"]

private def esc (s : String) : String :=
  s.replace "&" "&amp;" |>.replace "<" "&lt;" |>.replace ">" "&gt;"

/-- Render the history as an SVG. Bands mark the Lean version in use on each date. -/
def renderChart (rows : Array Row) (metric : String) : String := Id.run do
  let dates := rows.toList.map (·.date) |>.eraseDups |>.mergeSort (· < ·) |>.toArray
  let series := rows.toList.map (·.series) |>.eraseDups |>.toArray
  let maxV := rows.foldl (fun m r => max m r.value) 1
  let minV := rows.foldl (fun m r => if r.value > 0 then min m r.value else m) maxV
  -- A log scale once values span more than two decades, so a set total does not flatten its
  -- parts. `lg v` is log2 in sixteenths, computed on naturals so the bytes never depend on libm.
  let logScale := maxV > 100 * minV
  let lg (v : Nat) : Nat := Nat.log2 ((max v 1) ^ 16)
  -- Same date always has one Lean version: the last row wins, matching the order of the file.
  let versionAt := fun (d : String) =>
    (rows.filter (·.date == d)).back?.map (·.leanVersion) |>.getD "?"
  let (w, left, right, top, bot) := (1060, 70, 310, 46, 64)
  let h := max 520 (top + 24 + series.size * 18 + bot)
  let plotW := w - left - right
  let plotH := h - top - bot
  let n := dates.size
  let step := if n > 1 then plotW / (n - 1) else 0
  let xOf (i : Nat) : Nat := if n > 1 then left + i * step else left + plotW / 2
  let yOf (v : Nat) : Nat :=
    if logScale then top + plotH - (plotH * (lg v - lg minV)) / max 1 (lg maxV - lg minV)
    else top + plotH - (plotH * v) / maxV
  let mut out : Array String := #[]
  out := out.push s!"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {w} {h}\" width=\"{w}\" height=\"{h}\" font-family=\"sans-serif\">"
  out := out.push s!"<rect width=\"{w}\" height=\"{h}\" fill=\"#ffffff\"/>"
  -- Lean version bands: one shaded region per run of consecutive dates on the same version.
  let mut runs : Array (String × Nat × Nat) := #[]
  for i in [0:n] do
    let v := versionAt dates[i]!
    match runs.back? with
    | some (v', s, _) => if v' == v then runs := runs.pop.push (v, s, i) else runs := runs.push (v, i, i)
    | none => runs := runs.push (v, i, i)
  let mut shade := true
  for (v, s, e) in runs do
    let x0 := if s == 0 then left else (xOf s + xOf (s - 1)) / 2
    let x1 := if e + 1 == n then left + plotW else (xOf e + xOf (e + 1)) / 2
    let fill := if shade then "#eef2f7" else "#f8fafc"
    shade := !shade
    out := out.push s!"<rect x=\"{x0}\" y=\"{top}\" width=\"{x1 - x0}\" height=\"{plotH}\" fill=\"{fill}\"/>"
    out := out.push s!"<line x1=\"{x0}\" y1=\"{top}\" x2=\"{x0}\" y2=\"{top + plotH}\" stroke=\"#c7d2de\" stroke-width=\"1\"/>"
    out := out.push s!"<text x=\"{(x0 + x1) / 2}\" y=\"{top - 12}\" font-size=\"12\" fill=\"#44546a\" text-anchor=\"middle\">Lean {esc v}</text>"
  -- Axes.
  out := out.push s!"<line x1=\"{left}\" y1=\"{top + plotH}\" x2=\"{left + plotW}\" y2=\"{top + plotH}\" stroke=\"#333\" stroke-width=\"1\"/>"
  out := out.push s!"<line x1=\"{left}\" y1=\"{top}\" x2=\"{left}\" y2=\"{top + plotH}\" stroke=\"#333\" stroke-width=\"1\"/>"
  out := out.push s!"<text x=\"{left - 10}\" y=\"{top + 4}\" font-size=\"11\" fill=\"#333\" text-anchor=\"end\">{maxV}</text>"
  out := out.push s!"<text x=\"{left - 10}\" y=\"{top + plotH}\" font-size=\"11\" fill=\"#333\" text-anchor=\"end\">{if logScale then minV else 0}</text>"
  out := out.push s!"<text x=\"20\" y=\"{top + plotH / 2}\" font-size=\"12\" fill=\"#333\" transform=\"rotate(-90 20 {top + plotH / 2})\" text-anchor=\"middle\">{esc metric}{if logScale then " (log)" else ""}</text>"
  for i in [0:n] do
    if n <= 12 || i % (n / 12 + 1) == 0 then
      out := out.push s!"<text x=\"{xOf i}\" y=\"{top + plotH + 18}\" font-size=\"10\" fill=\"#333\" text-anchor=\"middle\" transform=\"rotate(-35 {xOf i} {top + plotH + 18})\">{esc dates[i]!}</text>"
  -- One line per tracked declaration.
  for (s, k) in series.zipIdx do
    let label := ((rows.find? (·.series == s)).map (·.label)).getD s
    let color := palette[k % palette.size]!
    let pts := dates.zipIdx.filterMap fun (d, i) =>
      (rows.findRev? (fun r => r.date == d && r.series == s)).map fun r => s!"{xOf i},{yOf r.value}"
    if pts.isEmpty then continue
    out := out.push s!"<polyline fill=\"none\" stroke=\"{color}\" stroke-width=\"2\" points=\"{String.intercalate " " pts.toList}\"/>"
    for p in pts do
      let parts := p.splitOn ","
      out := out.push s!"<circle cx=\"{parts[0]!}\" cy=\"{parts[1]!}\" r=\"3\" fill=\"{color}\"/>"
    out := out.push s!"<text x=\"{left + plotW + 14}\" y=\"{top + 14 + k * 18}\" font-size=\"11\" fill=\"{color}\">{esc label}</text>"
  out := out.push "</svg>"
  return String.intercalate "\n" out.toList ++ "\n"

def chartCmd (csv svg : System.FilePath) (metric : String) : IO UInt32 := do
  let rows ← readHistory csv metric
  if rows.isEmpty then
    IO.eprintln "no history rows to chart"
    return 1
  IO.FS.writeFile svg (renderChart rows metric)
  IO.println s!"wrote {svg} from {rows.size} rows, metric {metric}"
  return 0

/-- Shields-style badge. Text widths are estimated at 7px per character, which is close enough
for digits and short labels in Verdana 11px. -/
def renderBadge (label value : String) : String :=
  let (lw, vw) := (label.length * 7 + 12, value.length * 7 + 12)
  let w := lw + vw
  String.intercalate "\n" [
    s!"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"20\" role=\"img\" aria-label=\"{esc label}: {esc value}\">",
    s!"<rect width=\"{lw}\" height=\"20\" rx=\"3\" fill=\"#555\"/>",
    s!"<rect x=\"{lw}\" width=\"{vw}\" height=\"20\" rx=\"3\" fill=\"#2b6cb0\"/>",
    s!"<rect x=\"{lw}\" width=\"4\" height=\"20\" fill=\"#2b6cb0\"/>",
    s!"<g fill=\"#fff\" font-family=\"Verdana,DejaVu Sans,sans-serif\" font-size=\"11\" text-anchor=\"middle\">",
    s!"<text x=\"{lw / 2}\" y=\"14\">{esc label}</text>",
    s!"<text x=\"{lw + vw / 2}\" y=\"14\">{esc value}</text>",
    "</g>", "</svg>", ""]

/-- Badge with the latest cost and the Lean version it was computed on. The value is the `*` set
row of the latest date (all tracked declarations scored together), or the only row if a single
declaration is tracked. -/
def badgeCmd (csv svg : System.FilePath) : IO UInt32 := do
  let rows ← readHistory csv "cost"
  let some last := rows.back? | IO.eprintln "no scored rows for a badge"; return 1
  let latest := rows.filter (·.date == last.date)
  let sets := latest.filter (·.series.endsWith ".*")
  let picked := if sets.isEmpty then latest else sets
  let total := picked.foldl (· + ·.value) 0
  IO.FS.writeFile svg (renderBadge "novacula" s!"{total} · Lean {last.leanVersion}")
  IO.println s!"wrote {svg}: {total} on Lean {last.leanVersion}"
  return 0

end Novacula
