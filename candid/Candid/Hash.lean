module

public section

namespace Candid

/-- The id of a field name, which the binary format carries instead of the name (the spec's
`hash`): the name's UTF-8 bytes `b₀ … bₖ₋₁` as a number in base 223, modulo 2^32, that is
`Σ bᵢ · 223^(k-1-i) mod 2^32`. `UInt32` arithmetic wraps around, which does the modulo.

`idlHash "Ok"` is 17724 and `idlHash "Err"` is 3456837. -/
def idlHash (name : String) : UInt32 :=
  name.toUTF8.foldl (fun h b => h * 223 + b.toUInt32) 0

end Candid
