module

public import Candid.Value

/-!
The text format of Candid (spec: "Type Structure" and "Values"): `.did` files, types and values.

- `parseInterface` reads a `.did` file: its type definitions, such as `type List = opt record {
  head : nat; tail : List };`, and its service, such as `service : { greet : (text) -> (text) }`.
- `parseType` reads one type, and `parseValues` a list of values, such as `(42, "hi", opt true)`.
- `annotate` and `annotateArgs` give parsed values the types that they are expected to have: the
  text `42` is a number, which becomes a `nat8` at the type `nat8` and a `nat` at the type `nat`,
  as the Rust crate's `annotate_type` does.

Parsing has two steps, as in the Rust crate. The *lexer*, `lex`, cuts the text into tokens (names,
reserved words, numbers, string literals and punctuation) and skips white space and comments. It
works on the text's UTF-8 bytes rather than its characters, because a string literal stands for
bytes: the escape `\ff` is the byte 255, which is not UTF-8 on its own, as `blob "\ff"` needs.
Then *parsing functions*, one per rule of the grammar, read the tokens from left to right
("recursive descent"); each looks at the next token, or the next two, to choose a rule.

A parsing function has the type `Parser α`, which is `EStateM Error State α`: a function from the
parser's `State` (the tokens, and which of them is next) to either a result of type `α` with the
state after it, or an `Error`. `EStateM` ("error and state") is a *monad*, the kind of type that
`do` blocks are written in. In `do let t ← ty; expectPunct ";"; return t`, each step runs on the
state that the step before left, `let t ← ty` names the result of the parser `ty`, and the first
error ends the whole block, as `?` does in Rust; `(← peek)` inside an expression runs `peek` first
and stands for its result. `get` and `modify` read and change the state, and `throw` fails. The
parsers do not backtrack: one that fails has read tokens, and its error ends the parse.

The grammar is recursive, as a record type contains types, so the functions that parse types
call each other. Lean cannot see that this ends (it does: each call reads tokens), so they are
`partial def`s, which Lean compiles without a proof that they end; their result type must have a
default value (an `Inhabited` instance), which `EStateM` has. A depth limit, `maxDepth`, keeps
deeply nested text from exhausting the stack.

Text can come from anyone (a canister may take arguments in the text format), so the work is
kept in proportion to the length of the text where it can be: the sorts are merge sorts, names
and labels are found by binary search (`Definitions`, `findById`, `findCase`), only the digits of
a number that matter are read, the type annotations of a text may fill in 16 missing record
fields per byte of it (`fillsPerByte`), and error messages show long names, numbers and types in
part. A whole number of `k` digits still takes time in proportion to `k * k`, as in the Rust
crate (`digitsValue`).
-/

public section

namespace Candid

namespace Parse

/-- How deeply types and values may nest in the text (`opt opt …`), and in `annotate`. -/
def maxDepth : Nat := 512

/-! ## Tokens -/

/-- The reserved words, which a name cannot be unless it is quoted: those of the Rust lexer. The
names of the primitive types are not among them: `nat` is a name that stands for a type, so
`record { nat : nat }` is a record with a field called `nat`. Neither are `true` and `false`,
which are the booleans where a value is expected and names elsewhere. (The Rust lexer reads
them as booleans everywhere, so the printers quote them where they are names: `keywords`.) -/
def reservedWords : Array String :=
  #["null", "opt", "vec", "record", "variant", "func", "service", "oneway", "query",
    "composite_query", "blob", "type", "import", "principal"]

/-- A token of the text format. -/
inductive Token where
  /-- A name such as `List`, `nat` or `true`: an ASCII letter or `_`, then letters, digits and
  `_`, which is not a reserved word. -/
  | ident (name : String)
  /-- One of the `reservedWords`. -/
  | keyword (word : String)
  /-- A whole number, in decimal or in hexadecimal (`0x2a`), without its `_` separators. -/
  | number (n : Nat)
  /-- A decimal fraction such as `0.5`, `3.` or `1e-3`, whose value is `mantissa * 10^exponent`,
  or, if it has more than 800 significant digits, a number that rounds to the same float. -/
  | float (mantissa : Nat) (exponent : Int)
  /-- A string literal: the bytes that it stands for, which need not be UTF-8. -/
  | text (bytes : ByteArray)
  /-- The sign of a number, `-` or `+`. -/
  | sign (negative : Bool)
  /-- A punctuation mark: `=`, `(`, `)`, `{`, `}`, `;`, `,`, `.`, `:`, `->`, `==`, `!=` or `!:`. -/
  | punct (symbol : String)
  /-- The end of the text. -/
  | eof
  deriving Inhabited, BEq

/-- At most `max` characters of `s`, for an error message. A name in a text from anyone can be
as long as the text, and a canister traps, rather than rejects a call, if its reject message is
longer than a reply may be. -/
private def capped (s : String) (max : Nat := 100) : String :=
  if s.length ≤ max then s else (s.take max).toString ++ "…"

/-- A number for an error message: its digits, unless it has more than 30 of them, which would
take long to write (`toString` takes time in proportion to the square of their number), and
would make a long message. -/
private def numberText (i : Int) : String :=
  if i.natAbs < 10 ^ 30 then toString i
  else if i < 0 then "a negative number of more than 30 digits"
  else "a number of more than 30 digits"

/-- The token as an error message names it. A function written with `|` cases, like this one, is
defined by a `match` on its argument: the first case whose pattern fits is taken, as in a Rust
`match`; `.ident name` is short for `Token.ident name`, as the type is known. -/
def Token.describe : Token → String
  | .ident name => s!"the name {capped name}"
  | .keyword word => s!"the keyword {word}"
  | .number n => if n < 10 ^ 30 then s!"the number {n}" else numberText n
  | .float _ _ => "a decimal fraction"
  | .text _ => "a string"
  | .sign negative => if negative then "'-'" else "'+'"
  | .punct symbol => s!"'{symbol}'"
  | .eof => "the end of the text"

/-- A token, and the byte offset in the text where it starts. -/
structure Lexeme where
  token : Token
  start : Nat
  deriving Inhabited

/-! ## The lexer -/

/-- The byte at `i` as a character, or `'\x00'` after the end. An ASCII byte becomes the character
it encodes, and a byte of a longer UTF-8 sequence a character that the lexer does not look for. -/
private def charAt (input : ByteArray) (i : Nat) : Char :=
  if h : i < input.size then Char.ofNat input[i].toNat else '\x00'

/-- Whether `c` is a hexadecimal digit. -/
private def isHexDigit (c : Char) : Bool :=
  c.isDigit || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')

/-- The value of a hexadecimal digit. -/
private def hexDigitValue (c : Char) : Nat :=
  if c.isDigit then c.toNat - '0'.toNat
  else if 'a' ≤ c && c ≤ 'f' then c.toNat - 'a'.toNat + 10
  else c.toNat - 'A'.toNat + 10

/-- The position of the first byte at or after `pos` that is not `ok`, or the end of the input.
`termination_by` tells Lean why the recursion ends: `input.size - pos` gets smaller with each
call, which Lean checks, so this needs no `partial`. -/
private def scanWhile (input : ByteArray) (ok : Char → Bool) (pos : Nat) : Nat :=
  if h : pos < input.size then
    if ok (Char.ofNat input[pos].toNat) then scanWhile input ok (pos + 1) else pos
  else pos
termination_by input.size - pos

/-- The number that the digits between `start` and `stop` spell in `base`, 10 or 16; other
characters there, such as `_` and `.`, are skipped. `Id.run do` runs a `do` block that has no
effects, in which `let mut` variables and `for` loops work as in an imperative language.

A large `Nat` is a bignum, and `n * base + digit` makes a new one as large as `n`, so a number of
`k` digits would take time in proportion to `k * k`, with every digit a step. The digits are
gathered nine (in hexadecimal seven) at a time in `chunk`, a small number, which makes nine
times fewer steps; it is still quadratic, as in the Rust crate, so a number of a million digits
is slow. -/
private def digitsValue (base : Nat) (input : ByteArray) (start stop : Nat) : Nat := Id.run do
  -- `base ^ chunkDigits` is below 2^31, so that `chunk` is never a bignum, also on wasm32.
  let chunkDigits := if base == 16 then 7 else 9
  let scale := base ^ chunkDigits
  let mut n := 0
  let mut chunk := 0
  let mut count := 0
  for i in [start:stop] do
    let c := charAt input i
    if c.isDigit || (base == 16 && isHexDigit c) then
      chunk := chunk * base + hexDigitValue c
      count := count + 1
      if count == chunkDigits then
        n := n * scale + chunk
        chunk := 0
        count := 0
  return n * base ^ count + chunk

/-- The number that the digits between `start` and `stop` spell, as `digitsValue` says, if it is
below `bound`, else `bound`. It stops at `bound`, so that a long run of digits, where only a
small number makes sense, costs no more than a short one. -/
private def digitsValueUpTo (bound base : Nat) (input : ByteArray) (start stop : Nat) : Nat :=
  Id.run do
    let mut n := 0
    for i in [start:stop] do
      let c := charAt input i
      if c.isDigit || (base == 16 && isHexDigit c) then
        n := n * base + hexDigitValue c
        if n ≥ bound then return bound
    return n

/-- How many significant digits of a decimal fraction `lexMantissa` keeps. -/
private def mantissaDigits : Nat := 800

/-- The mantissa of a decimal fraction whose digits are between `start` and `stop` (the point is
skipped), and how many digits at its end it leaves out: `(m, k)` for the number `m * 10^k`.

A float has 17 significant decimal digits, but rounding a decimal fraction to the nearest float
correctly can take up to 768 of them, so the first `mantissaDigits` are kept, and the others
read only to see whether they are all zeros. If they are not, a digit 1 takes the place of the
first of them, which makes the number a little more than the kept digits say, as the whole
number is, and rounds as it does: the floats, and the numbers halfway between two of them, have
fewer digits. So a fraction of a million digits costs little more than one of 800. -/
private def lexMantissa (input : ByteArray) (start stop : Nat) : Nat × Nat := Id.run do
  let mut m := 0
  let mut kept := 0
  let mut left := 0
  let mut nonzero := false
  for i in [start:stop] do
    let c := charAt input i
    if c.isDigit then
      if kept < mantissaDigits then
        -- Zeros before the first other digit are not significant: `m` stays 0.
        if m != 0 || c != '0' then kept := kept + 1
        m := m * 10 + hexDigitValue c
      else
        left := left + 1
        if c != '0' then nonzero := true
  return if nonzero then (m * 10 + 1, left - 1) else (m, left)

/-- The text between `start` and `stop`, which is ASCII. -/
private def asciiText (input : ByteArray) (start stop : Nat) : String := Id.run do
  let mut s := ""
  for i in [start:stop] do
    s := s.push (charAt input i)
  return s

/-- The character at `pos` for an error message: the UTF-8 sequence there, quoted, or the byte in
hexadecimal. -/
private def describeCharAt (input : ByteArray) (pos : Nat) : String :=
  let utf8 := (List.range 4).findSome? fun i =>
    String.fromUTF8? (input.extract pos (pos + i + 1))
  match utf8 with
  | some s => quote s
  | none => s!"byte 0x{hexDigits (input[pos]!).toNat}"

/-- An error at byte `pos`. -/
private def errorAt (pos : Nat) (message : String) : Except Error α :=
  throw { message, offset := some pos }

/-- The position after the block comment `/* … */` that starts at `start`. Block comments nest,
as the spec says: `/* a /* b */ c */` is one comment. (`while` loops, unlike `for` loops over a
range, may run forever as far as Lean knows; this one moves `pos` forward each time.) -/
private def skipBlockComment (input : ByteArray) (start : Nat) : Except Error Nat := do
  let mut depth := 0
  let mut pos := start
  while pos < input.size do
    let c := charAt input pos
    let c1 := charAt input (pos + 1)
    if c == '/' && c1 == '*' then
      depth := depth + 1
      pos := pos + 2
    else if c == '*' && c1 == '/' then
      depth := depth - 1
      pos := pos + 2
      if depth == 0 then return pos
    else
      pos := pos + 1
  errorAt start "unclosed comment"

/-- The position of the first token at or after `pos`: white space (space, tab, carriage return,
line feed), line comments `// …` and block comments are skipped. -/
private def skipTrivia (input : ByteArray) (pos : Nat) : Except Error Nat := do
  let mut pos := pos
  while pos < input.size do
    let c := charAt input pos
    let c1 := charAt input (pos + 1)
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' then
      pos := pos + 1
    else if c == '/' && c1 == '/' then
      pos := scanWhile input (· != '\n') pos
    else if c == '/' && c1 == '*' then
      pos ← skipBlockComment input pos
    else
      break
  return pos

/-- The bytes that the escape sequence at `pos`, a `\` in a string literal, stands for, and the
position after it. As in the Rust lexer, the longest of these applies: `\u{2603}` is the UTF-8 of
a Unicode scalar value (a code point that is not a surrogate) in hexadecimal, with `_`s allowed
after the first digit; `\e2` is one byte, in hexadecimal; `\n`, `\r`, `\t`, `\\`, `\"` and `\'`
are those characters. -/
private def lexEscape (input : ByteArray) (pos : Nat) : Except Error (List UInt8 × Nat) := do
  let c1 := charAt input (pos + 1)
  let c2 := charAt input (pos + 2)
  if c1 == 'u' && c2 == '{' && isHexDigit (charAt input (pos + 3)) then
    let stop := scanWhile input (fun c => isHexDigit c || c == '_') (pos + 3)
    if charAt input stop == '}' then
      let n := digitsValueUpTo 0x110000 16 input (pos + 3) stop
      if n ≤ 0x10FFFF && !(0xD800 ≤ n && n ≤ 0xDFFF) then
        return (String.utf8EncodeChar (Char.ofNat n), stop + 1)
      -- The digits as written, as the Rust lexer shows them, but at most 20 characters of them.
      let shown := asciiText input (pos + 3) (min stop (pos + 23))
      let digits := String.ofList (shown.toList.filter (· != '_'))
      errorAt pos s!"Unicode escape out of range {digits}{if stop > pos + 23 then "…" else ""}"
  if isHexDigit c1 && isHexDigit c2 then
    return ([(16 * hexDigitValue c1 + hexDigitValue c2).toUInt8], pos + 3)
  match c1 with
  | 'n' => return ([0x0a], pos + 2)
  | 'r' => return ([0x0d], pos + 2)
  | 't' => return ([0x09], pos + 2)
  | '\\' => return ([0x5c], pos + 2)
  | '"' => return ([0x22], pos + 2)
  | '\'' => return ([0x27], pos + 2)
  | _ =>
    if pos + 1 ≥ input.size then errorAt pos "unclosed string"
    else errorAt pos s!"unknown escape character {describeCharAt input (pos + 1)}"

/-- The bytes that the string literal starting at `start` (its `"`) stands for, and the position
after it. The bytes between the quotes are taken as they are, except for escape sequences
(`lexEscape`); a line break may be among them. -/
private def lexText (input : ByteArray) (start : Nat) : Except Error (ByteArray × Nat) := do
  -- `out` is a local variable that nothing else refers to, so `push` adds to it in place.
  let mut out := ByteArray.empty
  let mut pos := start + 1
  while pos < input.size do
    let c := charAt input pos
    if c == '"' then
      return (out, pos + 1)
    else if c == '\\' then
      let (bytes, next) ← lexEscape input pos
      for b in bytes do
        out := out.push b
      pos := next
    else
      out := out.push input[pos]!
      pos := pos + 1
  errorAt start "unclosed string"

/-- The largest exponent of a decimal fraction that `lexNumber` reads: beyond it, the fraction
is infinite, or 0, whatever its digits, as a text cannot have so many of them. -/
private def maxExponent : Nat := 10 ^ 12

/-- The number that starts at `pos` with a digit, or with a `.` before a digit, and the position
after it. As in the Rust lexer, it is the longest of a whole number, `[0-9][0-9_]*` or
`0x[0-9a-fA-F][0-9a-fA-F_]*`, and a decimal fraction, `[0-9]*.[0-9]*` or
`[0-9]+(.[0-9]*)?[eE][+-]?[0-9]+`; the sign is a token of its own. The spec writes `0x` only,
so `0X1f` is the number 0 and the name `X1f` (the Rust lexer takes `0X1f` for a number, and its
parser then fails on it). -/
private def lexNumber (input : ByteArray) (pos : Nat) : Token × Nat :=
  if charAt input pos == '0' && charAt input (pos + 1) == 'x' && isHexDigit (charAt input (pos + 2))
  then
    let stop := scanWhile input (fun c => isHexDigit c || c == '_') (pos + 2)
    (.number (digitsValue 16 input (pos + 2) stop), stop)
  else
    -- The candidates: a whole number, which may have `_`s, and the two kinds of fractions,
    -- which may not. `intEnd` ends the digits before the point, `fracEnd` those after it.
    let wholeEnd := scanWhile input (fun c => c.isDigit || c == '_') pos
    let intEnd := scanWhile input Char.isDigit pos
    let hasPoint := charAt input intEnd == '.'
    let fracEnd := if hasPoint then scanWhile input Char.isDigit (intEnd + 1) else intEnd
    let e := charAt input fracEnd
    let expSign := charAt input (fracEnd + 1)
    let expStart := if expSign == '+' || expSign == '-' then fracEnd + 2 else fracEnd + 1
    let hasExponent := intEnd > pos && (e == 'e' || e == 'E') && (charAt input expStart).isDigit
    let floatEnd :=
      if hasExponent then scanWhile input Char.isDigit expStart
      else if hasPoint then fracEnd
      else pos
    if floatEnd > wholeEnd then
      let fracDigits := if hasPoint then fracEnd - intEnd - 1 else 0
      let exponent : Int :=
        if hasExponent then
          let n : Int := digitsValueUpTo maxExponent 10 input expStart floatEnd
          if expSign == '-' then -n else n
        else 0
      let (mantissa, left) := lexMantissa input pos fracEnd
      (.float mantissa (exponent - fracDigits + left), floatEnd)
    else
      (.number (digitsValue 10 input pos wholeEnd), wholeEnd)

/-- The token that starts at `pos`, which is not white space or a comment, and the position after
it. -/
private def lexToken (input : ByteArray) (pos : Nat) : Except Error (Token × Nat) := do
  let c := charAt input pos
  let c1 := charAt input (pos + 1)
  if c.isAlpha || c == '_' then
    let stop := scanWhile input (fun c => c.isAlphanum || c == '_') pos
    let word := asciiText input pos stop
    return (if reservedWords.contains word then .keyword word else .ident word, stop)
  if c.isDigit || (c == '.' && c1.isDigit) then
    return lexNumber input pos
  if c == '"' then
    let (bytes, stop) ← lexText input pos
    return (.text bytes, stop)
  -- Two-character marks first: `->` is not `-` followed by `>`.
  let two := String.ofList [c, c1]
  if two == "->" || two == "==" || two == "!=" || two == "!:" then
    return (.punct two, pos + 2)
  if c == '+' || c == '-' then
    return (.sign (c == '-'), pos + 1)
  if "=(){};,.:".contains c then
    return (.punct c.toString, pos + 1)
  errorAt pos s!"unexpected character {describeCharAt input pos}"

/-- The tokens of a text, given as its UTF-8 bytes, with their positions, ending with `eof`. -/
def lex (input : ByteArray) : Except Error (Array Lexeme) := do
  let mut tokens := #[]
  let mut pos ← skipTrivia input 0
  while pos < input.size do
    let (token, stop) ← lexToken input pos
    tokens := tokens.push { token, start := pos }
    pos ← skipTrivia input stop
  return tokens.push { token := .eof, start := input.size }

/-! ## The parser monad and its combinators -/

/-- The state of a parser: the tokens, which end with `eof`, the index of the next one, how
deeply the parsers that `nested` wraps are nested, and how many more missing record fields the
type annotations of values may fill in (`annotatedValue`). -/
structure State where
  tokens : Array Lexeme
  index : Nat := 0
  depth : Nat := 0
  fills : Nat

/-- A parser of `α`: it reads tokens from the state and returns an `α`, or fails with an error at
a byte offset. -/
abbrev Parser := EStateM Error State

/-- The next token, with its position. The cursor never moves past the last token, `eof`. -/
def current : Parser Lexeme := do
  let s ← get
  return s.tokens[s.index]?.getD { token := .eof, start := 0 }

/-- The next token. -/
def peek : Parser Token := return (← current).token

/-- The token after the next one. -/
def peekNext : Parser Token := do
  let s ← get
  return (s.tokens[s.index + 1]?.map (·.token)).getD .eof

/-- The byte offset where the next token starts. -/
def position : Parser Nat := return (← current).start

/-- Moves past the next token, unless it is the last one, `eof`. -/
def advance : Parser Unit :=
  modify fun s => if s.index + 1 < s.tokens.size then { s with index := s.index + 1 } else s

/-- Reads the next token. -/
def next : Parser Token := do
  let t ← peek
  advance
  return t

/-- Fails with an error at byte `pos`. -/
def failAt (pos : Nat) (message : String) : Parser α :=
  throw { message, offset := some pos }

/-- Fails with an error at the next token. -/
def failHere (message : String) : Parser α := do
  failAt (← position) message

/-- Fails because the next token is not what the grammar expects, which is `expected`. -/
def unexpected (expected : String) : Parser α := do
  failHere s!"expected {expected}, found {(← peek).describe}"

/-- Runs a check that is not a parser; its error, if any, is reported at `pos` if it has no
position of its own. -/
def liftAt (pos : Nat) (x : Except Error α) : Parser α :=
  match x with
  | .ok a => pure a
  | .error e => throw { e with offset := e.offset <|> some pos }

/-- Reads the punctuation mark `symbol` if it is next, and says whether it was. -/
def acceptPunct (symbol : String) : Parser Bool := do
  if (← peek) == .punct symbol then
    advance
    return true
  return false

/-- Reads the punctuation mark `symbol`, which must be next. -/
def expectPunct (symbol : String) : Parser Unit := do
  unless (← acceptPunct symbol) do unexpected s!"'{symbol}'"

/-- Reads the reserved word `word` if it is next, and says whether it was. -/
def acceptKeyword (word : String) : Parser Bool := do
  if (← peek) == .keyword word then
    advance
    return true
  return false

/-- Reads the reserved word `word`, which must be next. -/
def expectKeyword (word : String) : Parser Unit := do
  unless (← acceptKeyword word) do unexpected s!"'{word}'"

/-- Checks that the text has ended. -/
def expectEnd : Parser Unit := do
  unless (← peek) == .eof do unexpected "the end of the text"

/-- Items separated by `sep`, up to the punctuation mark `close`, which it does not read. The list
may be empty and may end with `sep`, as in `{ a; b; }`. -/
def sepBy (item : Parser α) (sep close : String) : Parser (Array α) := do
  let mut items := #[]
  repeat
    if (← peek) == .punct close then break
    items := items.push (← item)
    unless (← acceptPunct sep) do break
  return items

/-- Runs `p` one level deeper, failing beyond `maxDepth` levels. -/
def nested (p : Parser α) : Parser α := do
  let depth := (← get).depth
  if depth ≥ maxDepth then failHere s!"nested more than {maxDepth} levels deep"
  modify fun s => { s with depth := depth + 1 }
  let a ← p
  modify fun s => { s with depth := depth }
  return a

/-- A string literal's bytes. -/
def stringBytes : Parser ByteArray := do
  match ← peek with
  | .text bytes => advance; return bytes
  | _ => unexpected "a string"

/-- A string literal that is UTF-8 text. -/
def text : Parser String := do
  let pos ← position
  match String.fromUTF8? (← stringBytes) with
  | some s => return s
  | none => failAt pos "a string that is not valid UTF-8 text"

/-- An identifier: a name that is not quoted. -/
def ident : Parser String := do
  match ← peek with
  | .ident name => advance; return name
  | _ => unexpected "a name"

/-- A name (spec: `<name>`): an identifier, or any text in a string literal, `"a name"`. -/
def name : Parser String := do
  match ← peek with
  | .text _ => text
  | _ => ident

/-- A field label (spec: `<nat>` or `<name>`): a number below 2^32, the id itself, or a name. -/
def fieldLabel : Parser Label := do
  match ← peek with
  | .number n =>
    if n < 2 ^ 32 then
      advance
      return .num n.toUInt32
    failHere "field id out of u32 range"
  | .ident _ | .text _ => return .name (← name)
  | _ => unexpected "a field label"

/-- Whether the next tokens are a field label and the punctuation mark `symbol`, as in `a : nat`
and `1 = true`. -/
def labelBefore (symbol : String) : Parser Bool := do
  match ← peek, ← peekNext with
  | .number _, .punct s | .ident _, .punct s | .text _, .punct s => return s == symbol
  | _, _ => return false

/-- Whether the next tokens are a name and the punctuation mark `symbol`. -/
def nameBefore (symbol : String) : Parser Bool := do
  match ← peek, ← peekNext with
  | .ident _, .punct s | .text _, .punct s => return s == symbol
  | _, _ => return false

/-- A string that occurs twice in a sorted array, if there is one. -/
private def sortedDuplicate? (sorted : Array String) : Option String := Id.run do
  for h : i in [1:sorted.size] do
    if sorted[i - 1]! == sorted[i] then return some sorted[i]
  return none

/-- A string that occurs twice in `names`, if there is one.

The sorts of the parser are merge sorts, `Array.mergeSort`, which take `n * log n` steps for `n`
items, however they are ordered. `Array.qsort` is a quicksort, which takes `n * n` steps for some
orders, among them `n` equal items, which a text such as `variant { a; a; … }` would give it. -/
def duplicate? (names : Array String) : Option String :=
  sortedDuplicate? (names.mergeSort (· ≤ ·))

/-- Sorts the items by the ids of their labels, which must be distinct: fails at `pos` if two are
the same. The ids, which are hashes of names, are computed once, before the sort. -/
def sortLabels (pos : Nat) (items : Array (Label × α)) : Parser (Array (Label × α)) := do
  let sorted := (items.map fun (l, a) => (l.id, l, a)).mergeSort (·.1 ≤ ·.1)
  let mut prev : Option (UInt32 × Label) := none
  for (id, l, _) in sorted do
    -- `if let some (id', p) := prev then …` runs its block if `prev` is `some (id', p)`.
    if let some (id', p) := prev then
      if id == id' then
        if p.text == l.text then failAt pos s!"duplicate field {capped l.text}"
        else failAt pos s!"fields {capped p.text} and {capped l.text} have the same id {id}"
    prev := some (id, l)
  return sorted.map fun (_, l, a) => (l, a)

/-- Labels the fields of a record: a field without a label gets the id after the previous field's,
or 0 if it is the first, as in the Rust parser (spec: "Shorthand: Tuple Fields"); then sorts them
by id, as `sortLabels` does. -/
def numberFields (pos : Nat) (items : Array (Option Label × α)) : Parser (Array (Label × α)) := do
  let mut labelled := #[]
  let mut nextId : Nat := 0
  for (label?, a) in items do
    let label ← match label? with
      | some label => pure label
      | none =>
        if nextId < 2 ^ 32 then pure (Label.num nextId.toUInt32)
        else failAt pos "field id out of u32 range"
    labelled := labelled.push (label, a)
    nextId := label.id.toNat + 1
  sortLabels pos labelled

/-- How many missing record fields the type annotations of the values in a text may fill in, per
byte of the text, and `fillsBase` more, as the decoder's default fuel allows 16 values per byte
of a message: see `annotateWithin`. -/
def fillsPerByte : Nat := 16

/-- See `fillsPerByte`. -/
def fillsBase : Nat := 10_000

/-- Runs the parser `p` on a text, which it must read to the end. -/
def run (p : Parser α) (input : String) : Except Error α := do
  let tokens ← lex input.toUTF8
  let fills := fillsPerByte * input.utf8ByteSize + fillsBase
  match EStateM.run (do let a ← p; expectEnd; return a) { tokens, fills } with
  | .ok a _ => return a
  | .error e _ => throw e

/-! ## Types -/

/-- The primitive type that a name stands for, such as `Ty.nat` for `nat`. -/
def primitive? : String → Option Ty
  | "bool" => some .bool
  | "nat" => some .nat
  | "nat8" => some .nat8
  | "nat16" => some .nat16
  | "nat32" => some .nat32
  | "nat64" => some .nat64
  | "int" => some .int
  | "int8" => some .int8
  | "int16" => some .int16
  | "int32" => some .int32
  | "int64" => some .int64
  | "float32" => some .float32
  | "float64" => some .float64
  | "text" => some .text
  | "reserved" => some .reserved
  | "empty" => some .empty
  | _ => none

/-- The function mode that a token stands for. -/
def funcMode? : Token → Option FuncMode
  | .keyword "query" => some .query
  | .keyword "oneway" => some .oneway
  | .keyword "composite_query" => some .compositeQuery
  | _ => none

-- `mutual … end` defines functions that call each other, `partial` as the module doc says.
mutual

/-- A type (spec: `<datatype>`): a primitive type, the name of a definition, or a constructed
type, with the shorthand `blob` for `vec nat8`. -/
partial def ty : Parser Ty := nested do
  let pos ← position
  match ← next with
  | .ident n => return (primitive? n).getD (.var n)
  | .keyword "null" => return .null
  | .keyword "principal" => return .principal
  | .keyword "blob" => return .blob
  | .keyword "opt" => return .opt (← ty)
  | .keyword "vec" => return .vec (← ty)
  | .keyword "record" => recordType
  | .keyword "variant" => variantType
  | .keyword "func" => funcType
  | .keyword "service" => return .service (← serviceType)
  | t => failAt pos s!"expected a type, found {t.describe}"

/-- The fields of a record type after `record`: `{ name : nat; 1 : text; bool }`, where a field
without a label is numbered as `numberFields` says. -/
partial def recordType : Parser Ty := do
  let pos ← position
  expectPunct "{"
  let fields ← sepBy recordField ";" "}"
  expectPunct "}"
  return .record ((← numberFields pos fields).map fun (label, ty) => { label, ty })

/-- A field of a record type: `label : type`, or a type alone. -/
partial def recordField : Parser (Option Label × Ty) := do
  if (← labelBefore ":") then
    let label ← fieldLabel
    expectPunct ":"
    return (some label, ← ty)
  return (none, ← ty)

/-- The cases of a variant type after `variant`: `{ ok : nat; err : text; none }`, where a case
without a type has the type `null` (spec: "Shorthand: Enumeration Types"). -/
partial def variantType : Parser Ty := do
  let pos ← position
  expectPunct "{"
  let cases ← sepBy variantCase ";" "}"
  expectPunct "}"
  return .variant ((← sortLabels pos cases).map fun (label, ty) => { label, ty })

/-- A case of a variant type: `label : type`, or a label alone. -/
partial def variantCase : Parser (Label × Ty) := do
  let label ← fieldLabel
  if (← acceptPunct ":") then return (label, ← ty)
  return (label, .null)

/-- A sequence of argument or result types (spec: `<tuptype>`), `(nat, text)`. An argument may be
named, `(amount : nat)`; the names must be distinct, and are dropped. -/
partial def argTypes : Parser (Array Ty) := do
  let pos ← position
  expectPunct "("
  let args ← sepBy argType "," ")"
  expectPunct ")"
  if let some n := duplicate? (args.filterMap (·.1)) then
    failAt pos s!"duplicate argument name {capped n}"
  return args.map (·.2)

/-- An argument type, with its name if it has one. -/
partial def argType : Parser (Option String × Ty) := do
  if (← nameBefore ":") then
    let n ← name
    expectPunct ":"
    return (some n, ← ty)
  return (none, ← ty)

/-- A function type after `func`, as a method of a service is written (spec: `<functype>`):
`(args) -> (results)`, then at most one mode, `query`, `composite_query` or `oneway`. A `oneway`
function has no results. -/
partial def funcType : Parser Ty := do
  let pos ← position
  let args ← argTypes
  expectPunct "->"
  let rets ← argTypes
  let mut modes := #[]
  repeat
    -- `let some x := e | alternative` names the value in an `Option`, or runs the alternative.
    let some mode := funcMode? (← peek) | break
    advance
    modes := modes.push mode
  if modes.size > 1 then failAt pos "cannot have more than one mode"
  if modes == #[.oneway] && !rets.isEmpty then
    failAt pos "oneway function has non-unit return type"
  return .func args rets modes

/-- The methods of a service type after `service` (spec: `<actortype>`): `{ get : () -> (nat)
query; set : setter }`, where `setter` names a function type. The methods are sorted by name,
which must be distinct. -/
partial def serviceType : Parser (Array Method) := do
  let pos ← position
  expectPunct "{"
  let methods ← sepBy method ";" "}"
  expectPunct "}"
  let sorted := methods.mergeSort (·.name ≤ ·.name)
  if let some n := sortedDuplicate? (sorted.map (·.name)) then
    failAt pos s!"duplicate method {capped n}"
  return sorted

/-- A method of a service type: its name, then `:` and a function type, or the name of one. -/
partial def method : Parser Method := do
  let n ← name
  expectPunct ":"
  if let .ident f := ← peek then
    advance
    return { name := n, ty := .var f }
  return { name := n, ty := ← funcType }

end

/-! ## Checking types -/

/-- The definitions of a `TypeEnv`, made ready for the checks below. `TypeEnv.find?` looks
through the definitions one by one, and `TypeEnv.resolve` does so at each step of a chain of
names such as `type A = B; type B = C; …`, so on a `.did` file of thousands of definitions,
which anyone can write, the checks would take time in proportion to the square of their number,
or to its cube. These find a name by binary search, and follow each chain once. -/
structure Definitions where
  /-- The definitions. -/
  env : TypeEnv
  /-- Their names, sorted, each with the index of its definition; of a name defined twice, the
  first definition comes first. -/
  names : Array (String × Nat)
  /-- For each definition, the type at the end of its chain of names, as `TypeEnv.resolve` finds
  it, or `none` if the chain is a cycle or comes to a name that is not defined. -/
  ends : Array (Option Ty)

namespace Definitions

/-- The index of the definition of `name`, the first if there are several. A binary search:
`lo` and `hi` close in on the first name in `names` that does not come before `name`. -/
def indexOf? (d : Definitions) (name : String) : Option Nat := Id.run do
  let mut lo := 0
  let mut hi := d.names.size
  while lo < hi do
    let mid := (lo + hi) / 2
    if d.names[mid]!.1 < name then lo := mid + 1 else hi := mid
  match d.names[lo]? with
  | some (n, i) => return if n == name then some i else none
  | none => return none

/-- The definitions of `env`, with their names sorted and their chains followed. -/
def ofEnv (env : TypeEnv) : Definitions := Id.run do
  let defs := env.defs
  let d : Definitions :=
    { env, names := (defs.mapIdx fun i (n, _) => (n, i)).mergeSort (·.1 ≤ ·.1), ends := #[] }
  -- `state[i]` is 0 for a definition that no chain has reached yet, 1 for one on the chain that
  -- is being followed, and 2 for one whose end is known.
  let mut ends : Array (Option Ty) := Array.replicate defs.size none
  let mut state : Array UInt8 := Array.replicate defs.size 0
  for start in [0:defs.size] do
    if state[start]! != 0 then continue
    let mut chain := #[]
    let mut i := start
    let mut last : Option Ty := none
    repeat
      if state[i]! == 2 then
        last := ends[i]!
        break
      -- Back on the chain itself: a cycle, whose end is `none`.
      if state[i]! == 1 then break
      state := state.set! i 1
      chain := chain.push i
      match defs[i]!.2 with
      | .var name =>
        match d.indexOf? name with
        | some j => i := j
        | none => break
      | t =>
        last := some t
        break
    for j in chain do
      ends := ends.set! j last
      state := state.set! j 2
  return { d with ends }

/-- The type that `t` stands for: the end of the chain of its definition if it is a name,
`none` if that is a cycle or `t` is not defined, and `t` itself otherwise. -/
def resolve? (d : Definitions) : Ty → Option Ty
  | .var name => (d.indexOf? name).bind fun i => d.ends[i]?.join
  | t => some t

/-- Checks a type against the definitions, as `Parse.checkType` says. -/
partial def checkType (d : Definitions) (t : Ty) (methods : Bool := true) : Except Error Unit :=
  match t with
  | .var n =>
    if (d.indexOf? n).isSome then pure () else fail s!"unbound type identifier {capped n}"
  | .opt t | .vec t => d.checkType t methods
  | .record fields | .variant fields => fields.forM fun f => d.checkType f.ty methods
  | .func args rets _ => do
    args.forM (d.checkType · methods)
    rets.forM (d.checkType · methods)
  | .service ms => ms.forM fun m => do
    d.checkType m.ty methods
    if methods then
      match d.resolve? m.ty with
      | some (.func ..) => pure ()
      | _ => fail s!"method {capped (nameText m.name)} is a non-function type"
  | _ => pure ()

/-- Checks the definitions themselves, as `Parse.checkDefinitions` says. -/
def check (d : Definitions) (positions : Array Nat := #[]) : Except Error Unit := do
  let defs := d.env.defs
  let atDefinition (i : Nat) (x : Except Error Unit) : Except Error Unit :=
    x.mapError fun e => { e with offset := e.offset <|> positions[i]? }
  -- In `names`, the later definitions of a name follow its first, as the merge sort keeps the
  -- order of equal items. The error is at the first of them in the file.
  let mut twice : Option Nat := none
  for h : k in [1:d.names.size] do
    let (n, i) := d.names[k]
    if d.names[k - 1]!.1 == n then twice := some (min i (twice.getD i))
  if let some i := twice then
    atDefinition i (fail s!"duplicate binding for {capped defs[i]!.1}")
  for h : i in [0:defs.size] do
    atDefinition i (d.checkType defs[i].2 (methods := false))
  for h : i in [0:defs.size] do
    if d.ends[i]!.isNone then
      atDefinition i (fail s!"{capped defs[i].1} has cyclic type definition")
  for h : i in [0:defs.size] do
    atDefinition i (d.checkType defs[i].2)

end Definitions

/-- Checks a type against the definitions `env`, as the Rust type checker does: each name that it
uses is defined, and, if `methods` is true, the type of each method of a service type is a
function type, possibly through names. -/
def checkType (env : TypeEnv) (t : Ty) (methods : Bool := true) : Except Error Unit :=
  (Definitions.ofEnv env).checkType t methods

/-- Checks the definitions of a `.did` file, as the Rust type checker does: no name is defined
twice, the types are checked as `checkType` does, and no definition is a cycle of names such as
`type A = B; type B = A`, which stands for no type. An error in the definition at index `i` is
reported at `positions[i]`, if there is one. -/
def checkDefinitions (env : TypeEnv) (positions : Array Nat := #[]) : Except Error Unit :=
  (Definitions.ofEnv env).check positions

/-! ## `.did` files -/

/-- A type definition (spec: `<def>`), `type X = T`, without the `;` after it. -/
def typeDef : Parser (String × Ty) := do
  expectKeyword "type"
  let n ← ident
  expectPunct "="
  return (n, ← ty)

/-- A service type's methods, `{ … }`, or the name of a service type. -/
def serviceOrName : Parser Ty := do
  if let .ident n := ← peek then
    advance
    return .var n
  return .service (← serviceType)

/-- The service of a `.did` file (spec: `<actor>`), `service : { methods }`, with an optional name
after `service`, which does not matter, and with the types of the arguments of the canister's
initialization if it has them, `service : (nat) -> { … }`. The service may also be the name of a
service type, `service : S`. Returns the initialization arguments, if any, and the service. -/
def mainService : Parser (Option (Array Ty) × Ty) := do
  expectKeyword "service"
  if let .ident _ := ← peek then advance
  expectPunct ":"
  let mut initArgs := none
  if (← peek) == .punct "(" then
    initArgs := some (← argTypes)
    expectPunct "->"
  let service ← serviceOrName
  discard <| acceptPunct ";"
  return (initArgs, service)

/-- A `.did` file (spec: `<prog>`): type definitions, each followed by `;`, then an optional service
(`mainService`). The definitions are checked as `checkDefinitions` does, and the service and its
initialization arguments as `checkType` does; the service must be a service type. Imports are not
supported. -/
def interface : Parser Interface := do
  let mut defs := #[]
  let mut positions := #[]
  repeat
    match ← peek with
    | .keyword "type" =>
      positions := positions.push (← position)
      defs := defs.push (← typeDef)
      unless (← acceptPunct ";") do break
    | .keyword "import" => failHere "imports are not supported"
    | _ => break
  let env : TypeEnv := { defs }
  let d := Definitions.ofEnv env
  liftAt 0 (d.check positions)
  unless (← peek) == .keyword "service" do return { env }
  let pos ← position
  let (initArgs, service) ← mainService
  liftAt pos do
    for t in initArgs.getD #[] do d.checkType t
    d.checkType service
    match d.resolve? service with
    | some (.service _) => pure ()
    | t => fail s!"not a service type: {(t.getD service).toDidCapped}"
  return { env, initArgs, service }

end Parse

/-! ## Values and their types -/

/-- The error of a value that cannot be of type `t`. -/
private def mismatch (v : Value) (t : Ty) : Except Error α :=
  fail s!"type mismatch: {v.toTextCapped} cannot be of type {t.toDidCapped}"

/-- The value with id `id` in `sorted`, which is sorted by id; the first if there are several.
A binary search, as in `Parse.Definitions.indexOf?`. -/
private def findById (sorted : Array (UInt32 × Value)) (id : UInt32) : Option Value := Id.run do
  let mut lo := 0
  let mut hi := sorted.size
  while lo < hi do
    let mid := (lo + hi) / 2
    if sorted[mid]!.1 < id then lo := mid + 1 else hi := mid
  match sorted[lo]? with
  | some (i, v) => return if i == id then some v else none
  | none => return none

/-- The case with id `id` of a variant type. The cases of a variant type are sorted by id, as the
parser and `Ty.variantOf` sort them, so a binary search finds it, as `findById` does, which
computes the ids (hashes of names) of the cases that it looks at only. Should it not find the
case, every case is looked at, as a variant type made otherwise may have its cases in another
order; at a type whose cases are sorted, that happens only if the case is not there, and
`annotate` then fails. -/
private def findCase (cases : Array Field) (id : UInt32) : Option Field := Id.run do
  let mut lo := 0
  let mut hi := cases.size
  while lo < hi do
    let mid := (lo + hi) / 2
    let c := cases[mid]!
    let cid := c.label.id
    if cid == id then return some c
    if cid < id then lo := mid + 1 else hi := mid
  return cases.find? (·.label.id == id)

/-- The value of the integer type `t` for the number `i`, if `t` is an integer type and `i` is in
its range. -/
def intAt? (t : Ty) (i : Int) : Option Value :=
  match t with
  | .nat => if 0 ≤ i then some (.nat i.toNat) else none
  | .int => some (.int i)
  | .nat8 => if 0 ≤ i && i < 2 ^ 8 then some (.nat8 i.toNat.toUInt8) else none
  | .nat16 => if 0 ≤ i && i < 2 ^ 16 then some (.nat16 i.toNat.toUInt16) else none
  | .nat32 => if 0 ≤ i && i < 2 ^ 32 then some (.nat32 i.toNat.toUInt32) else none
  | .nat64 => if 0 ≤ i && i < 2 ^ 64 then some (.nat64 i.toNat.toUInt64) else none
  | .int8 => if -(2 ^ 7) ≤ i && i < 2 ^ 7 then some (.int8 (Int8.ofInt i)) else none
  | .int16 => if -(2 ^ 15) ≤ i && i < 2 ^ 15 then some (.int16 (Int16.ofInt i)) else none
  | .int32 => if -(2 ^ 31) ≤ i && i < 2 ^ 31 then some (.int32 (Int32.ofInt i)) else none
  | .int64 => if -(2 ^ 63) ≤ i && i < 2 ^ 63 then some (.int64 (Int64.ofInt i)) else none
  | _ => none

/-- The computations of `annotateWithin`. `StateT σ m` adds a state of type `σ` to the monad `m`:
here, to `Except Error`, how many more missing fields may be filled in, or `none` if there is no
limit. In its `do` blocks, `get` and `set` read and change the state, and a computation of
`Except Error`, such as `fail "…"` or `env.resolve #[] t`, can be used as it is: Lean *lifts* it
into `StateT`, leaving the state as it is. -/
private abbrev Annotate := StateT (Option Nat) (Except Error)

/-- Counts a missing field that `annotateWithin` fills in against the limit, if there is one, and
fails if there is none left. -/
private def fillIn : Annotate Unit := do
  match ← get with
  | some 0 => fail "type annotations fill in too many missing fields"
  | some n => set (some (n - 1))
  | none => pure ()

/-- `annotate`, below, which also counts the fields that it fills in, those that a record value
lacks and its type has at `null`, `opt` or `reserved`, against `limit`, unless that is `none`.
`record {}` at a type of `n` such fields is a value of `n` fields: a text of `n` times
`record {}`, annotated with that type, as in `(vec { record {}; … } : vec record { … })`, which
the parser annotates as it reads it, would make a value of `n * n` fields. Returns the value, and
what is left of the limit. -/
private def annotateWithin (limit : Option Nat) (env : TypeEnv) (t : Ty) (v : Value) :
    Except Error (Value × Option Nat) :=
  (go Parse.maxDepth t v).run limit
where
  /-- The work of `annotateWithin`, with `fuel` for the depth of the value: each call is on a
  smaller `fuel`, so Lean sees that the recursion ends (structural recursion on a `Nat`). A
  function after `where` is a helper of the definition above it, which can use its arguments,
  here `env`. -/
  go : Nat → Ty → Value → Annotate Value
    | 0, _, _ => fail s!"value nested more than {Parse.maxDepth} levels deep"
    | fuel + 1, t, v => do
      let t ← env.resolve #[] t
      let isNat8 (t : Ty) : Bool := env.resolve #[] t matches .ok .nat8
      match v, t with
      | _, .reserved => return .reserved
      | .float64 x, .float32 => return .float32 x.toFloat32
      | .null, .null => return .null
      | .bool b, .bool => return .bool b
      | .nat n, .nat => return .nat n
      | .nat n, .int => return .int n
      | .nat8 n, .nat8 => return .nat8 n
      | .nat16 n, .nat16 => return .nat16 n
      | .nat32 n, .nat32 => return .nat32 n
      | .nat64 n, .nat64 => return .nat64 n
      | .int8 i, .int8 => return .int8 i
      | .int16 i, .int16 => return .int16 i
      | .int32 i, .int32 => return .int32 i
      | .int64 i, .int64 => return .int64 i
      | .float32 x, .float32 => return .float32 x
      | .float64 x, .float64 => return .float64 x
      | .text s, .text => return .text s
      | .null, .opt _ | .reserved, .opt _ | .opt none, .opt _ => return .opt none
      | .opt (some v), .opt t => return .opt (some (← go fuel t v))
      | .blob bytes, .vec e => if isNat8 e then return .blob bytes else mismatch v (.vec e)
      | .vec vs, .vec e =>
        if isNat8 e then
          let mut bytes := ByteArray.emptyWithCapacity vs.size
          for v in vs do
            match v with
            | .nat8 b => bytes := bytes.push b
            | .int i =>
              if 0 ≤ i && i < 256 then bytes := bytes.push i.toNat.toUInt8
              else fail s!"{Parse.numberText i} is out of the range of nat8"
            | v => mismatch v .nat8
          return .blob bytes
        return .vec (← vs.mapM (go fuel e))
      | .record fields, .record tfields =>
        -- The value's fields by id, sorted, for a binary search per field of the type, rather
        -- than a look at every field of the value for each (`==` on labels hashes names).
        let byId := (fields.map fun (l, v) => (l.id, v)).mergeSort (·.1 ≤ ·.1)
        let mut out := #[]
        for f in tfields do
          match findById byId f.label.id with
          | some v => out := out.push (f.label, ← go fuel f.ty v)
          | none =>
            let filled ← match ← env.resolve #[] f.ty with
              | .null => pure Value.null
              | .opt _ => pure (Value.opt none)
              | .reserved => pure Value.reserved
              | _ => fail s!"record field {Parse.capped f.label.text} not found"
            fillIn
            out := out.push (f.label, filled)
        return .record out
      | .variant l v, .variant cases =>
        match findCase cases l.id with
        | some c => return .variant c.label (← go fuel c.ty v)
        | none => fail s!"variant field {Parse.capped l.text} not found"
      | .principal p, .principal => return .principal p
      | .service p, .service _ => return .service p
      | .func p m, .func .. => return .func p m
      | .int i, t =>
        match intAt? t i with
        | some v => return v
        | none =>
          if (intAt? t 0).isSome then fail s!"{Parse.numberText i} is out of the range of {t}"
          else fail s!"type mismatch: {Parse.numberText i} cannot be of type {t.toDidCapped}"
      | v, t => mismatch v t

/-- `v` at the type `t`, with the types that `env` defines, as the Rust crate's `annotate_type`
gives a parsed value its type (with `from_parser`):

- a number (`Value.int`, which is how the parser returns whole numbers) becomes a value of the
  integer type `t` if it is in its range; a float type needs a decimal fraction (`Value.float64`),
  which becomes a `float32` at `float32`;
- `null` at an `opt` type is `opt` with nothing; any value at `reserved` is `reserved`;
- a `vec` of numbers below 256, or a `blob`, at `vec nat8` is a `blob`;
- a record gets the fields of its type, in their order: a field that the value lacks is `null`,
  `opt` with nothing or `reserved` if its type is `null`, `opt` or `reserved`, else an error, and
  a field that the type lacks is dropped;
- a variant's case must be one of its type's;
- `principal`, `service` and `func` values must be at those types; their method types are not
  checked;
- other values must be of their types already: `.nat` at `nat` or `int`, `.nat8` at `nat8`, ….

The labels of record fields and variant cases become those of the type. As `Value.int` stands
for a number, an `int` that does not come from the parser, such as that of `(5 : int)`, is taken
for one too, so it becomes a `nat` at `nat`, where the Rust crate's `Int` would not. -/
def annotate (env : TypeEnv) (t : Ty) (v : Value) : Except Error Value :=
  (annotateWithin none env t v).map (·.1)

/-- Parsed values at the types of a method's arguments, as the Rust crate's `annotate_types` does:
each value at its type with `annotate`; a type without a value, at the end, gets `null`, `opt`
with nothing or `reserved` if it is `null`, an `opt` type or `reserved`, and is an error
otherwise; values without a type, at the end, are dropped. -/
def annotateArgs (env : TypeEnv) (tys : Array Ty) (vs : Array Value) :
    Except Error (Array Value) := do
  let mut out := #[]
  for h : i in [0:tys.size] do
    let t := tys[i]
    match vs[i]? with
    | some v => out := out.push (← annotate env t v)
    | none =>
      match ← env.resolve #[] t with
      | .null => out := out.push .null
      | .opt _ => out := out.push (.opt none)
      | .reserved => out := out.push .reserved
      | _ => fail s!"Omitted values cannot be of type {t.toDidCapped}"
  return out

namespace Parse

/-! ## Values -/

/-- A number, with an optional sign: a whole number is an `int` until `annotate` gives it its
type, and a decimal fraction is a `float64`. -/
def number : Parser Value := do
  let mut negative := false
  if let .sign s := ← peek then
    negative := s
    advance
  let pos ← position
  match ← next with
  | .number n => return .int (if negative then -(n : Int) else n)
  | .float m e =>
    -- `Float.ofScientific m true e` is `m / 10^e`, rounded to the nearest float.
    let x := Float.ofScientific m (e < 0) e.natAbs
    return .float64 (if negative then -x else x)
  | t => failAt pos s!"expected a number, found {t.describe}"

/-- The most characters that the text form of a principal has: those of its bytes, at most
`Principal.maxLength`, and of a checksum of 4, in base32, which writes 5 bits per character, with
a `-` after every 5 characters. -/
def maxPrincipalText : Nat :=
  let base32 := ((Principal.maxLength + 4) * 8 + 4) / 5
  base32 + (base32 - 1) / 5

/-- A principal in its text form, as a string literal: `"aaaaa-aa"`. A text too long to be one is
rejected here, as `Principal.fromText` would write it into its error, which a long text of
characters that it escapes would make five times as long. -/
def principal : Parser Principal := do
  let pos ← position
  let s ← text
  if s.length > maxPrincipalText then
    failAt pos (s!"invalid principal: a text of {s.length} characters, " ++
      s!"more than a principal's {maxPrincipalText}")
  liftAt pos (Principal.fromText s)

mutual

/-- A value (spec: `<val>`): `null`, `true`, `false`, a number, a string, `opt v`, `vec { v; … }`,
`blob "…"`, `record { name = v; 1 = v; v }`, `variant { name = v }` or `variant { name }` (whose
value is `null`), `principal "…"`, `service "…"`, `func "…".name`, or `(v)`. A record field
without a label is numbered as `numberFields` says. -/
partial def value : Parser Value := nested do
  let pos ← position
  match ← peek with
  | .ident "true" => advance; return .bool true
  | .ident "false" => advance; return .bool false
  | .number _ | .float _ _ | .sign _ => number
  | .text _ => return .text (← text)
  | t =>
    advance
    match t with
    | .keyword "null" => return .null
    | .keyword "opt" => return .opt (some (← value))
    | .keyword "blob" => return .blob (← stringBytes)
    | .keyword "vec" =>
      expectPunct "{"
      let elems ← sepBy annotatedValue ";" "}"
      expectPunct "}"
      return .vec elems
    | .keyword "record" =>
      let start ← position
      expectPunct "{"
      let fields ← sepBy recordValueField ";" "}"
      expectPunct "}"
      return .record (← numberFields start fields)
    | .keyword "variant" =>
      expectPunct "{"
      let label ← fieldLabel
      let v ← if (← acceptPunct "=") then annotatedValue else pure .null
      expectPunct "}"
      return .variant label v
    | .keyword "principal" => return .principal (← principal)
    | .keyword "service" => return .service (← principal)
    | .keyword "func" =>
      let p ← principal
      expectPunct "."
      return .func p (← name)
    | .punct "(" =>
      let v ← annotatedValue
      expectPunct ")"
      return v
    | t => failAt pos s!"expected a value, found {t.describe}"

/-- A field of a record value: `label = v`, or a value alone. -/
partial def recordValueField : Parser (Option Label × Value) := do
  if (← labelBefore "=") then
    let label ← fieldLabel
    expectPunct "="
    return (some label, ← annotatedValue)
  return (none, ← annotatedValue)

/-- A value with an optional type (spec: `<annval>`), `v : t`, which `annotate` gives `v` with no
type definitions. The fields that it fills in count against the limit of the text, `fills`
(`fillsPerByte`), which the annotations of a text share. -/
partial def annotatedValue : Parser Value := do
  let pos ← position
  let v ← value
  unless (← acceptPunct ":") do return v
  let t ← ty
  let fills := (← get).fills
  let (v, left) ← liftAt pos do
    checkType {} t
    annotateWithin (some fills) {} t v
  modify fun s => { s with fills := left.getD 0 }
  return v

end

/-- A list of values (spec: `<args>`), `(v, …)`, as the arguments of a method. -/
def args : Parser (Array Value) := do
  expectPunct "("
  let vs ← sepBy annotatedValue "," ")"
  expectPunct ")"
  return vs

end Parse

/-- The interface of a `.did` file: its type definitions and its service, checked as the Rust
type checker does (`Parse.interface`). -/
def parseInterface (text : String) : Except Error Interface :=
  Parse.run Parse.interface text

/-- A type in the text format, such as `record { name : text; age : nat8 }`. Names in it are not
checked; `Parse.checkType` checks them against definitions. -/
def parseType (text : String) : Except Error Ty :=
  Parse.run Parse.ty text

/-- A list of values in the text format, such as `(42, "hi", opt true)`, untyped: whole numbers
are `Value.int`, decimal fractions `Value.float64`, and `annotateArgs` gives them their types. -/
def parseValues (text : String) : Except Error (Array Value) :=
  Parse.run Parse.args text

end Candid
