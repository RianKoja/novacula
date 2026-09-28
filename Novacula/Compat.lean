import Lean

/-! Lean version specific shims. Everything that breaks between toolchains lives here. -/

namespace Novacula
open Lean

def mkImport (m : Name) : Import := { module := m }

def loadEnv (mods : Array Name) : IO Environment := do
  initSearchPath (← findSysroot)
  importModules (mods.map mkImport) (opts := {}) (trustLevel := 0)

/-- Module that declares `n`, if it was imported. -/
def moduleOf? (env : Environment) (n : Name) : Option Name :=
  (env.getModuleIdxFor? n).bind fun i => env.header.moduleNames[i.toNat]?

/-- Constants declared by each imported module, in olean order, paired with the module name. -/
def modulesWithConsts (env : Environment) : Array (Name × Array Name) :=
  env.header.moduleNames.zip (env.header.moduleData.map (·.constNames))

/-- The `.olean` a module was loaded from. -/
def oleanOf (mod : Name) : IO System.FilePath := findOLean mod

/-- Was `n` written by a user, as opposed to generated? Generated lemmas such as `congr_simp`
have no declaration range. Ranges come from the elaborator, not from source text. -/
def hasDeclRange (env : Environment) (n : Name) : Bool :=
  (declRangeExt.find? (level := .exported) env n <|> declRangeExt.find? (level := .server) env n).isSome

end Novacula
