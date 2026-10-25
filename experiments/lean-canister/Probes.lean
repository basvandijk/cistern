module

/-!
The probes, which measure recursion depth and `String.map` (see README.md). The canister's
`probe` query (Canister.lean) runs them in PocketIC, and RunProbe.lean natively.
-/

public section

/-- Non-tail recursion. -/
def deep : Nat → Nat
  | 0 => 0
  | n + 1 => 1 + deep n

/-- Non-tail recursion in a state monad, as monadic Lean code often is. -/
def countM : Nat → StateM Nat Unit
  | 0 => pure ()
  | n + 1 => do countM n; modify (· + 1)

/-- Recursion through closures: `k` is called through `lean_apply_1` once per level. -/
def deepK : Nat → (Nat → Nat) → Nat
  | 0, k => k 0
  | n + 1, k => deepK n (fun r => k (r + 1))

/-- As `deepK`, but each level adds to a bignum, which uses frames in linear memory. -/
def deepKB : Nat → (Nat → Nat) → Nat
  | 0, k => k (2 ^ 70)
  | n + 1, k => deepKB n (fun r => k (r + 1))

/-- `n` characters: `lo`, `lo + 1`, ..., `lo + m - 1`, and so on. -/
def chars (lo m n : Nat) : String :=
  String.ofList ((List.range n).map fun i => Char.ofNat (lo + i % m))

/-- A probe: `prepare` makes the input of a size, which is not measured, and `run` is the work to
measure. The result of `run` depends on all of the work, so that none of it can be skipped.

The input is a value rather than something that `run` captures: Lean's compiler turns
`fun n => let x := e; fun _ => b` into `fun n _ => let x := e; b`, which would compute `e` in the
measured part. -/
structure Probe where
  Input : Type
  prepare : Nat → Input
  run : Input → Nat

def Probe.of (prepare : Nat → α) (run : α → Nat) : Probe := ⟨α, prepare, run⟩

/-- The probes by name. In the canister, `toUpper` gets a shared string (see
`Ic0.countInstructions`). -/
def probes : List (String × Probe) := [
  -- No work: what measuring itself costs.
  ("noop", .of id id),
  ("deep", .of id deep),
  ("countM", .of id fun n => ((countM n).run 0).2),
  ("repr", .of List.range fun xs => (toString (repr xs)).length),
  ("zip", .of List.range fun xs => (xs.zip xs).length),
  ("deepK", .of id fun n => deepK n id),
  ("deepKB", .of id fun n => deepKB n id),
  ("toUpper", .of (chars 0x61 26) fun s => s.toUpper.length), -- a-z
  ("toUpperNonAscii", .of (chars 0x100 0x100) fun s => s.toUpper.length) -- U+0100-U+01FF
]
