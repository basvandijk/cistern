module

public import Candid.Error
public import Candid.Hash
public import Candid.Leb128
public import Candid.Ty
public import Candid.Principal
public import Candid.Value
public import Candid.Subtype
public import Candid.Encode
public import Candid.Decode
public import Candid.Parse
public import Candid.Class

/-!
Candid, the interface description language and binary format of the Internet Computer
(https://github.com/dfinity/candid/blob/master/spec/Candid.md), in Lean.

`import Candid` brings in all of the library except `deriving CandidType`, which needs Lean's
own modules at compile time and is in `Candid.Derive` (see README.md):

- `Candid.Ty`, `Candid.Value`, `Candid.Principal`: types and values;
- `Candid.encodeValues`, `Candid.decodeValues`: messages of values at types, and
  `Candid.decodeAny`: a message at its own types;
- `CandidType`, `CandidArgs`, `Candid.encode`, `Candid.decode`: messages of Lean values;
- `Candid.isSubtype`: the subtype relation;
- `Candid.parseInterface`, `Candid.Interface.toDid`: the `.did` text format.
-/
