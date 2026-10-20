module

public import Candid.Error
public import Candid.Ty

/-!
Principals, the identities of the Internet Computer: of canisters, users and the management
canister. A principal is at most 29 bytes. Its text form, such as `aaaaa-aa` (the management
canister) or `2vxsx-fae` (the anonymous principal), is the CRC32 of the bytes, big-endian,
followed by the bytes, in lowercase base32 (RFC 4648, without padding), in groups of five
characters separated by `-`. It is read in either case, as the Internet Computer's specification
says ("Textual representation of principals"): `AAAAA-AA` is the management canister too.
-/

public section

namespace Candid

/-- A principal: its bytes, at most 29. -/
structure Principal where
  bytes : ByteArray
  deriving Inhabited

instance : BEq Principal := ⟨fun a b => a.bytes == b.bytes⟩

namespace Principal

/-- The most bytes that a principal has. -/
def maxLength : Nat := 29

/-- The most characters that the text form of a principal has: 29 bytes and the 4 of the
checksum are 53 characters of base32, in 11 groups, with 10 `-` between them. -/
def maxTextLength : Nat := 63

/-- The management canister's principal, `aaaaa-aa`, which has no bytes. -/
def managementCanister : Principal := ⟨.empty⟩

/-- The anonymous principal, `2vxsx-fae`, the caller of a message that is not signed. -/
def anonymous : Principal := ⟨⟨#[4]⟩⟩

/-- The CRC32 of `data` (the IEEE polynomial, as in zlib), a bit at a time: principals are short,
so a table of 256 entries would not pay off. -/
def crc32 (data : ByteArray) : UInt32 :=
  let crc := data.foldl (init := 0xFFFFFFFF) fun crc b => Id.run do
    let mut crc := crc ^^^ b.toUInt32
    for _ in [0:8] do
      crc := if crc &&& 1 == 1 then (crc >>> 1) ^^^ 0xEDB88320 else crc >>> 1
    return crc
  crc ^^^ 0xFFFFFFFF

/-- The digits of base32, in lowercase. -/
private def alphabet : Array Char := "abcdefghijklmnopqrstuvwxyz234567".toList.toArray

/-- `data` in base32, five bits per character, without padding. -/
def base32 (data : ByteArray) : String := Id.run do
  let mut out := ""
  -- `buffer` holds the `bits` bits that are not written yet, in its low bits.
  let mut buffer : UInt32 := 0
  let mut bits := 0
  for b in data do
    buffer := (buffer <<< 8) ||| b.toUInt32
    bits := bits + 8
    while bits ≥ 5 do
      bits := bits - 5
      out := out.push alphabet[((buffer >>> bits.toUInt32) &&& 31).toNat]!
  if bits > 0 then
    out := out.push alphabet[((buffer <<< (5 - bits).toUInt32) &&& 31).toNat]!
  return out

/-- The bytes of a base32 text, in lower or upper case, without padding; `none` if it has another
character. Left-over bits at the end are dropped. `for c in text` takes the characters of `text`
one by one. -/
def ofBase32? (text : String) : Option ByteArray := Id.run do
  let mut out := ByteArray.empty
  let mut buffer : UInt32 := 0
  let mut bits := 0
  for c in text do
    let some digit := alphabet.idxOf? c.toLower | return none
    buffer := (buffer <<< 5) ||| digit.toUInt32
    bits := bits + 5
    if bits ≥ 8 then
      bits := bits - 8
      out := out.push ((buffer >>> bits.toUInt32) &&& 0xFF).toUInt8
  return some out

/-- The checksum of `data` that the text form starts with: its CRC32, as four bytes, the most
significant first (big-endian). -/
private def checksum (data : ByteArray) : ByteArray :=
  let crc := crc32 data
  ⟨#[(crc >>> 24).toUInt8, (crc >>> 16).toUInt8, (crc >>> 8).toUInt8, crc.toUInt8]⟩

/-- The text form of a principal: the base32 text of its checksum and its bytes, with a `-` after
every five characters. -/
def toText (p : Principal) : String := Id.run do
  let mut out := ""
  let mut n := 0
  for c in base32 (checksum p.bytes ++ p.bytes) do
    if n > 0 && n % 5 == 0 then out := out.push '-'
    out := out.push c
    n := n + 1
  return out

/-- The principal of a text form, in lower or upper case. As the Rust crate `ic_principal` does,
this decodes the text liberally, without its `-`s, checks the length and the checksum, and then
requires the text to be the text form of the result once in lower case, which checks the
grouping, and the bits after the last byte, which must be zero. `String.foldl` goes through the
characters of `text`, here to collect those that are not `-`. -/
def fromText (text : String) : Except Error Principal := do
  -- A longer text is no principal's, and the errors below would quote all of it.
  if text.length > maxTextLength then
    fail s!"invalid principal {quote (text.take maxTextLength).copy}…: longer than {maxTextLength} characters"
  let digits := text.foldl (fun s c => if c == '-' then s else s.push c) ""
  let some checked := ofBase32? digits
    | fail s!"invalid principal {quote text}: not base32"
  if checked.size < 4 then
    fail s!"invalid principal {quote text}: too short"
  if checked.size - 4 > maxLength then
    fail s!"invalid principal {quote text}: longer than {maxLength} bytes"
  let p : Principal := ⟨checked.extract 4 checked.size⟩
  if checked.extract 0 4 != checksum p.bytes then
    fail s!"invalid principal {quote text}: wrong checksum"
  -- `toLower` changes the letters `A` to `Z` only, as Rust's `to_ascii_lowercase`.
  if p.toText != text.toLower then
    fail s!"invalid principal {quote text}: expected {quote p.toText}"
  return p

instance : ToString Principal := ⟨toText⟩

instance : Repr Principal where
  reprPrec p _ := s!"Principal.fromText {quote p.toText}"

end Principal

end Candid
