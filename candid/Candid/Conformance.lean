import Candid

/-!
The conformance suite of Candid (https://github.com/dfinity/candid/tree/master/test): files
`*.test.did` of type definitions and assertions, in the grammar of the suite's README, which
extends the text format:

```
type T = …;
assert <input> : (types) "description";        the input decodes, or parses, at the types
assert <input> !: (types) "description";       it does not
assert <input> == <input> : (types) "…";       both do, to equal values
assert <input> != <input> : (types) "…";       both do, to values that are not equal
```

An input is a message, `blob "DIDL…"`, or values in the text format, `"(1, true)"`; the
description is optional.

This program judges the assertions as the Rust runner does (candid_parser/src/test.rs, `check`):
a message is decoded at the types with `decodeValues`, the file's definitions being the
`TypeEnv` its names refer to; values in the text format are parsed with `parseValues` and given
the types with `annotateArgs`. Values are compared with `==`, which is structural, as Rust's
`PartialEq` is: floats compare as numbers, so a NaN differs from itself.

It prints a line per assertion, `pass` or `FAIL`, where the assertion is and its description,
and for a failure why; then a line per file and the totals. It also counts the assertions of
each form, and checks the counts against those of the suite at the commit that the flake pins.
It exits with 1 if an assertion fails, a file does not parse, or a count is not the expected one,
and with 2 if it is used wrongly. It is a program, not a module, which `lean --run` can run:

```
lean --run Candid/Conformance.lean test/prim.test.did test/construct.test.did …
```
-/

open Candid Candid.Parse

/-- An input of an assertion. -/
inductive Input where
  /-- A message in the binary format, `blob "DIDL…"`: the bytes of the string literal. -/
  | blob (bytes : ByteArray)
  /-- Values in the text format, `"(…)"`: the text of the string literal. -/
  | text (text : String)

/-- An assertion of a test file. -/
structure Assertion where
  /-- Where `assert` is in the file, as a byte offset. -/
  offset : Nat
  /-- The input that is decoded or parsed at `types`. -/
  left : Input
  /-- The input that `left` is compared with, for `==` and `!=`. -/
  right : Option Input
  /-- The types of the arguments, after `:` or `!:`. -/
  types : Array Ty
  /-- Whether the assertion is `:` or `==`, which assert success and equality, rather than `!:`
  or `!=`, which assert failure and inequality. -/
  pass : Bool
  /-- The description at the end, if there is one. -/
  description : Option String

/-- A test file: its type definitions, to which the types of the assertions may refer, and its
assertions. -/
structure TestFile where
  env : TypeEnv
  assertions : Array Assertion

/-! ## Parsing

The parsers are written with those of Candid/Parse.lean (`Parser`, `peek`, `advance`,
`expectPunct`, `argTypes`, …), whose module comment explains how they work: a `Parser α` reads
tokens and returns an `α`; in its `do` blocks, `(← peek)` runs `peek` and stands for its result.
-/

/-- An input: `blob "…"` or `"…"`. -/
def input : Parser Input := do
  if (← acceptKeyword "blob") then return .blob (← stringBytes)
  return .text (← text)

/-- An assertion. `assert` is a name, not a reserved word, as in the Rust parser. The names in its
types must be defined in `defs`, the file's definitions. `s!"… {x} …"` is a string with the text
of `x` in it. -/
def assertion (defs : Definitions) : Parser Assertion := do
  let offset ← position
  unless (← peek) == .ident "assert" do unexpected "assert"
  advance
  let left ← input
  let opPos ← position
  let op ← next
  let mut right := none
  if op == .punct "==" || op == .punct "!=" then
    right := some (← input)
    expectPunct ":"
  else if !(op == .punct ":" || op == .punct "!:") then
    failAt opPos s!"expected ':', '!:', '==' or '!=', found {op.describe}"
  let typesPos ← position
  let types ← argTypes
  liftAt typesPos (types.forM (defs.checkType ·))
  let description ← match ← peek with
    | .text _ => some <$> text
    | _ => pure none
  return { offset, left, right, types, pass := op == .punct ":" || op == .punct "==", description }

/-- A test file (the Rust grammar's `Test`): type definitions, then assertions, each followed by
`;` (which the last may lack). The definitions are checked as in a `.did` file. -/
def testFile : Parser TestFile := do
  let mut defs := #[]
  let mut positions := #[]
  repeat
    unless (← peek) == .keyword "type" do break
    positions := positions.push (← position)
    defs := defs.push (← typeDef)
    unless (← acceptPunct ";") do break
  let env : TypeEnv := { defs }
  let checked := Definitions.ofEnv env
  liftAt 0 (checked.check positions)
  let mut assertions := #[]
  repeat
    unless (← peek) == .ident "assert" do break
    assertions := assertions.push (← assertion checked)
    unless (← acceptPunct ";") do break
  return { env, assertions }

/-- The line and column, both from 1, of a byte offset in a text. -/
def lineColumn (text : String) (offset : Nat) : Nat × Nat := Id.run do
  let bytes := text.toUTF8
  let mut line := 1
  let mut column := 1
  for i in [0:min offset bytes.size] do
    let b := bytes[i]!
    if b == 0x0a then
      line := line + 1
      column := 1
    -- Count characters, not bytes: UTF-8 continuation bytes are 0b10xxxxxx.
    else if b &&& 0xc0 != 0x80 then
      column := column + 1
  return (line, column)

/-- The lines, from 1, of byte offsets in a text, which must come in increasing order, as those of
a file's assertions do. One pass over the text finds them all: `pos` and `line` move forward from
one offset to the next. -/
def linesOf (text : String) (offsets : Array Nat) : Array Nat := Id.run do
  let bytes := text.toUTF8
  let mut lines := #[]
  let mut line := 1
  let mut pos := 0
  for offset in offsets do
    while pos < min offset bytes.size do
      if bytes[pos]! == 0x0a then line := line + 1
      pos := pos + 1
    lines := lines.push line
  return lines

/-! ## Counting -/

/-- The forms of assertions that the suite has: the kinds of the inputs and the operator. -/
def forms : Array String :=
  #["blob :", "blob !:", "blob == text", "blob != text", "blob == blob", "text only"]

/-- The form of an assertion, one of `forms` or another. -/
def Assertion.form (a : Assertion) : String :=
  let op := match a.right, a.pass with
    | none, true => ":"
    | none, false => "!:"
    | some _, true => "=="
    | some _, false => "!="
  match a.left, a.right with
  | .text _, none | .text _, some (.text _) => "text only"
  | .text _, some (.blob _) => s!"text {op} blob"
  | .blob _, none => s!"blob {op}"
  | .blob _, some (.text _) => s!"blob {op} text"
  | .blob _, some (.blob _) => s!"blob {op} blob"

/-- How many assertions there are of each of the `forms`, and of any other form that occurs.
`(·.1 == f)` is short for the function `fun c => c.1 == f`, and `(·, 0)` for `fun f => (f, 0)`. -/
def countForms (assertions : Array Assertion) : Array (String × Nat) := Id.run do
  let mut counts := forms.map (·, 0)
  for a in assertions do
    let f := a.form
    match counts.findIdx? (·.1 == f) with
    | some i => counts := counts.modify i fun (f, n) => (f, n + 1)
    | none => counts := counts.push (f, 1)
  return counts

/-- Counts as `blob : 9, blob !: 65, …`. -/
def showCounts (counts : Array (String × Nat)) : String :=
  ", ".intercalate (counts.toList.map fun (f, n) => s!"{f} {n}")

/-- The counts of the `forms` in the suite's six files at the commit that the flake pins,
10423fae: 467 assertions. -/
def expected : Array (String × Array Nat) := #[
  ("prim.test.did", #[9, 65, 86, 0, 5, 3]),
  ("construct.test.did", #[12, 64, 84, 0, 1, 3]),
  ("reference.test.did", #[0, 29, 19, 1, 0, 1]),
  ("subtypes.test.did", #[0, 0, 58, 0, 0, 0]),
  ("overshoot.test.did", #[0, 10, 0, 0, 0, 0]),
  ("spacebomb.test.did", #[0, 17, 0, 0, 0, 0])]

/-- Sums counts of the same forms. -/
def addCounts (a b : Array (String × Nat)) : Array (String × Nat) := Id.run do
  let mut sum := a
  for (f, n) in b do
    match sum.findIdx? (·.1 == f) with
    | some i => sum := sum.modify i fun (f, m) => (f, m + n)
    | none => sum := sum.push (f, n)
  return sum

/-! ## Judging -/

/-- The values of an input at the types of an assertion, whose names `env` defines: a message is
decoded, as the Rust runner does with its `from_bytes_with_types_with_config`; values in the text
format are parsed, and then given the types, as with its `parse_idl_args` and `annotate_types`.
The result has a value for each type.

In the definition of `Input.values`, the names in the namespace `Input` need no prefix, so a
variable called `text` would be taken for the constructor `Input.text`; it is called `s`. -/
def Input.values (env : TypeEnv) (types : Array Ty) : Input → Except Error (Array Value)
  | .blob bytes => decodeValues env types bytes
  | .text s => do annotateArgs env types (← parseValues s)

/-- What is done to an input to get its values: a message is decoded, a text parsed. -/
def Input.verb : Input → String
  | .blob _ => "decode"
  | .text _ => "parse"

/-- Values as the text format writes a list of arguments, `(1, "a")`, cut after `max` characters,
as some are long. -/
def valuesText (vs : Array Value) (max : Nat := 200) : String :=
  let s := "(" ++ ", ".intercalate (vs.toList.map Value.toText) ++ ")"
  if s.length ≤ max then s else String.ofList (s.toList.take max) ++ "…"

/-- Why the assertion `a` fails, with the definitions `env`, or `none` if it holds. The Rust
runner's rules: `:` holds if the input decodes or parses, and `!:` if it does not, for whatever
reason; `==` and `!=` need both inputs to decode or parse, and hold if the values are equal, or
are not. (Where an input of `:`, `==` or `!=` does not, the Rust runner stops checking the file;
this one counts the assertion as failed and goes on. The Rust runner also encodes the values of a
message again, and says so if the bytes differ, which does not change its verdict, though an
error in encoding them stops it too; this one does not encode them.)

A `match` on two values at once, `match x, y with`, takes the first case whose patterns fit both;
a case may list several pairs of patterns, separated by `|`, if they bind the same names. -/
def Assertion.failure? (env : TypeEnv) (a : Assertion) : Option String :=
  let left := a.left.values env a.types
  match a.right with
  | none =>
    match left, a.pass with
    | .ok _, true | .error _, false => none
    | .error e, true => some s!"does not {a.left.verb}: {e}"
    | .ok vs, false => some s!"{a.left.verb}s, to {valuesText vs}"
  | some right =>
    match left, right.values env a.types with
    | .error e, _ => some s!"the left side does not {a.left.verb}: {e}"
    | _, .error e => some s!"the right side does not {right.verb}: {e}"
    | .ok l, .ok r =>
      if (l == r) == a.pass then none
      else
        let what := if a.pass then "the values differ" else "the values are equal"
        some s!"{what}: {valuesText l} and {valuesText r}"

/-- The line of the result of an assertion at `line` of the file `name`: `pass` or `FAIL`, where
the assertion is, its description, quoted as in the file, and for a failure, why. -/
def resultLine (name : String) (line : Nat) (a : Assertion) (failure : Option String) : String :=
  let description := match a.description with
    | some d => s!" {quote d}"
    | none => ""
  match failure with
  | none => s!"pass {name}:{line}{description}"
  | some why => s!"FAIL {name}:{line}{description}: {why}"

/-! ## The program -/

/-- Judges the assertions of the test files named on the command line, and prints the result of
each, the totals of each file, and of all; before the results of a file, the counts of its forms.
Exits with 1 if an assertion fails, a file does not parse or a count is not the expected one, and
with 2 without arguments or if a file cannot be read. -/
def main (args : List String) : IO UInt32 := do
  if args.isEmpty then
    IO.eprintln "usage: lean --run Candid/Conformance.lean FILE.test.did …"
    return 2
  let mut ok := true
  let mut total : Array (String × Nat) := forms.map (·, 0)
  let mut names : Array String := #[]
  let mut passed := 0
  let mut failed := 0
  for path in args do
    let name := (System.FilePath.mk path).fileName.getD path
    names := names.push name
    -- `try … catch` handles an error that `readFile` throws, which names the file; `return`
    -- ends `main`, not just the loop.
    let text ← try IO.FS.readFile path catch e => do
      IO.eprintln (toString e)
      return 2
    match Parse.run testFile text with
    | .error e =>
      let (line, column) := lineColumn text (e.offset.getD 0)
      IO.println s!"{name}:{line}:{column}: {e.message}"
      ok := false
    | .ok file =>
      let counts := countForms file.assertions
      total := addCounts total counts
      IO.println (s!"{name}: {file.assertions.size} assertions, " ++
        s!"{file.env.defs.size} type definitions: {showCounts counts}")
      -- `counts` lists the `forms` first, then any other form that occurs.
      if let some (_, want) := expected.find? (·.1 == name) then
        unless counts.map (·.2) == want do
          IO.println s!"{name}: expected {showCounts (forms.zip want)}"
          ok := false
      let lines := linesOf text (file.assertions.map (·.offset))
      let mut filePassed := 0
      -- `zip` pairs each assertion with its line.
      for (a, line) in file.assertions.zip lines do
        let failure := a.failure? file.env
        IO.println (resultLine name line a failure)
        if failure.isNone then filePassed := filePassed + 1
      let fileFailed := file.assertions.size - filePassed
      IO.println s!"{name}: {filePassed} passed, {fileFailed} failed, of {file.assertions.size}"
      passed := passed + filePassed
      failed := failed + fileFailed
  let count := total.foldl (· + ·.2) 0
  IO.println s!"all: {count} assertions: {showCounts total}"
  -- With all six files, the totals are those of the suite: 467 assertions.
  if expected.all (names.contains ·.1) then
    let want := expected.foldl (fun acc (_, counts) => addCounts acc (forms.zip counts))
      (forms.map (·, 0))
    if total == want && count == 467 then
      IO.println "the counts are the expected ones"
    else
      IO.println s!"expected 467 assertions: {showCounts want}"
      ok := false
  IO.println s!"{passed} passed, {failed} failed, of {passed + failed}"
  return if ok && failed == 0 then 0 else 1
