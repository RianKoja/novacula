import Lean

/-! Lean version specific shims. Everything that breaks between toolchains lives here. -/

namespace Novacula
open Lean

def mkImport (m : Name) : Import := { module := m }

def loadEnv (mods : Array Name) : IO Environment := do
  initSearchPath (← findSysroot)
  importModules (mods.map mkImport) (opts := {}) (trustLevel := 0)

end Novacula
