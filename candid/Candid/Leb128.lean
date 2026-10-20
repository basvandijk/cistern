module

/-!
LEB128, the binary format's encoding of numbers of any size: seven bits per byte, least
significant first, with the high bit (0x80) set on every byte but the last. Unsigned LEB128
encodes `nat`, lengths, counts and field ids; signed LEB128 (SLEB128), in which bit 6 (0x40) of
the last byte is the sign, encodes `int` and type references.

`Nat` and `Int` are arbitrary-precision, so these functions handle numbers of any size. Numbers
of up to 64 bits are written, and those of up to nine bytes read, with `UInt64` and `Int64`
arithmetic. A longer number is split in halves, each of which is written or read on its own, and
so on: a number of `n` bytes then takes about `n log n` steps. Taking seven bits at a time off a
big `Nat` instead, or adding them to one, would copy the number each time, about `n²` steps,
which a message could exploit with a number of a million bytes, for a canister that decodes it or
one that encodes it again.
-/

public section

namespace Candid.Leb128

/-- Appends the LEB128 encoding of `n` to `out`. At most ten bytes: 64 bits, seven at a time. -/
def pushUInt64 (out : ByteArray) (n : UInt64) : ByteArray := Id.run do
  let mut out := out
  let mut n := n
  for _ in [0:10] do
    if n < 0x80 then
      return out.push n.toUInt8
    out := out.push (n.toUInt8 ||| 0x80)
    n := n >>> 7
  return out

/-- Appends the SLEB128 encoding of `i` to `out`: seven bits at a time, until the rest, which `>>>`
shifts arithmetically, keeping the sign, is 0 with bit 6 of the last byte clear, or -1 with it
set. -1 is `7f`, 63 is `3f`, 64 is `c0 00` and -128 is `80 7f`. At most ten bytes. -/
def pushInt64 (out : ByteArray) (i : Int64) : ByteArray := Id.run do
  let mut out := out
  let mut i := i
  for _ in [0:10] do
    let byte := i.toUInt64.toUInt8 &&& 0x7f
    i := i >>> 7
    if (i == 0 && byte &&& 0x40 == 0) || (i == -1 && byte &&& 0x40 != 0) then
      return out.push byte
    out := out.push (byte ||| 0x80)
  return out

/-- Appends the `count` seven-bit groups of `bits`, the least significant first, each with the high
bit set, as all bytes but the last of a LEB128 number have it; `bits` is below `2 ^ (7 * count)`.
Up to nine groups, 63 bits, are taken from a `UInt64`. More are split in halves: the low half is
`bits &&& (2 ^ (7 * half) - 1)`, the high half `bits >>> (7 * half)`. `1 <<< k` is `2 ^ k`, as a
shift, which takes one pass over the number.

`termination_by count` tells Lean what gets smaller with each recursive call, so that it can
check that the recursion ends; it proves that by itself, from the condition of the `if`. -/
def pushGroups (out : ByteArray) (bits count : Nat) : ByteArray :=
  if count ≤ 9 then Id.run do
    let v := bits.toUInt64
    let mut out := out
    for k in [0:count] do
      out := out.push ((v >>> (7 * k).toUInt64).toUInt8 ||| 0x80)
    return out
  else
    let half := count / 2
    let out := pushGroups out (bits &&& ((1 <<< (7 * half)) - 1)) half
    pushGroups out (bits >>> (7 * half)) (count - half)
termination_by count

/-- Appends `bits`, a number below `2 ^ (7 * count)`, as `count` groups of seven bits, all but the
last with the high bit set; `count` is at least 1. -/
private def pushBits (out : ByteArray) (bits count : Nat) : ByteArray :=
  let rest := 7 * (count - 1)
  (pushGroups out (bits &&& ((1 <<< rest) - 1)) (count - 1)).push (bits >>> rest).toUInt8

/-- Appends the LEB128 encoding of `n` to `out`: as many groups of seven bits as `n` has, the last
one not zero. `Nat.log2 n` is the position of the highest bit that is set. -/
def pushNat (out : ByteArray) (n : Nat) : ByteArray :=
  if n < 2 ^ 64 then pushUInt64 out n.toUInt64
  else pushBits out n (n.log2 / 7 + 1)

/-- Appends the SLEB128 encoding of `i` to `out`: `i` in two's complement, in the fewest groups of
seven bits, `count`, whose highest bit is the sign, so that `-2^(7 · count - 1) ≤ i <
2^(7 · count - 1)`. For a negative `i`, two's complement in `7 · count` bits is
`2^(7 · count) + i`, which is the bits of `-i - 1` flipped (`^^^`, exclusive or, with all ones),
and `-i - 1` is what must be below `2^(7 · count - 1)`. -/
def pushInt (out : ByteArray) (i : Int) : ByteArray :=
  if -2 ^ 63 ≤ i && i < 2 ^ 63 then pushInt64 out (Int64.ofInt i)
  else
    let magnitude := if i ≥ 0 then i.toNat else (-i - 1).toNat
    let count := (magnitude.log2 + 8) / 7
    let bits := if i ≥ 0 then magnitude else magnitude ^^^ ((1 <<< (7 * count)) - 1)
    pushBits out bits count

/-- The number that the seven-bit groups of the bytes from `i` to `j` (exclusive) make, the
first group the least significant. Up to nine bytes, 63 bits, are combined in a `UInt64`. A
longer number is split in halves, each computed on its own, then combined: a number of `n` bytes
takes about `n log n` steps. Adding the groups one by one would build an ever larger `Nat` each
time, about `n²` steps. -/
def groupsValue (bytes : ByteArray) (i j : Nat) : Nat :=
  if j ≤ i + 9 then Id.run do
    let mut v : UInt64 := 0
    for k in [i:j] do
      v := v ||| ((bytes[k]! &&& 0x7f).toUInt64 <<< (7 * (k - i)).toUInt64)
    return v.toNat
  else
    let m := (i + j) / 2
    groupsValue bytes i m + (groupsValue bytes m j <<< (7 * (m - i)))
termination_by j - i

/-- The position after the LEB128 number that starts at `pos`, after its first byte below 0x80,
or `none` if the input ends before that. -/
def endOf? (bytes : ByteArray) (pos : Nat) : Option Nat := Id.run do
  for h : i in [pos:bytes.size] do
    if bytes[i] < 0x80 then return some (i + 1)
  return none

/-- The LEB128 number at `pos` in `bytes`, and the position after it, or `none` if the input
ends before its last byte. Overlong encodings, with high zero groups (`80 00` for 0), are
accepted, as the spec allows. -/
def readNat (bytes : ByteArray) (pos : Nat) : Option (Nat × Nat) := do
  let stop ← endOf? bytes pos
  return (groupsValue bytes pos stop, stop)

/-- The SLEB128 number at `pos` in `bytes`, and the position after it, or `none` if the input
ends before its last byte. The groups make a number of `7 · k` bits in two's complement: if bit
6 of the last byte is set, it is negative, `2^(7 · k)` less, which the shift `1 <<< (7 * k)`
computes. -/
def readInt (bytes : ByteArray) (pos : Nat) : Option (Int × Nat) := do
  let stop ← endOf? bytes pos
  let n := groupsValue bytes pos stop
  let negative := bytes[stop - 1]! &&& 0x40 != 0
  return (if negative then (n : Int) - ((1 <<< (7 * (stop - pos)) : Nat) : Int) else n, stop)

/-- The LEB128 encoding of `n`. -/
def ofNat (n : Nat) : ByteArray := pushNat .empty n

/-- The SLEB128 encoding of `i`. -/
def ofInt (i : Int) : ByteArray := pushInt .empty i

end Candid.Leb128
