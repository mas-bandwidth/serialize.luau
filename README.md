# serialize.luau

A simple bitpacking serializer for Luau, wire compatible with the C++ [serialize](https://github.com/mas-bandwidth/serialize) library and [serialize.go](https://github.com/mas-bandwidth/serialize.go): the same values produce the same bytes.

The wire format is serialize's STANDARD.md, **format version 2.0**, vendored verbatim from serialize v2.1.0 (standard 2.1: the caller's own refusal, `rejected`, through `stream:reject()` or a nested object whose `serialize` returns false) with the shared conformance vectors (conformance/) and negative controls (conformance-controls/). Every vector passes, every refusal for its stated reason, and every carried control fails exactly its expected list. The pinned interpreter is Luau 0.741.

Format 2.0 in one paragraph: the wire carries only integers and bytes, and every value has exactly one encoding. Floats and doubles are finite (NaN and the infinities are refused); strings are well-formed UTF-8 with no NUL; a reader refuses padding that is not zero, a non-canonical int_relative tier and anything after the end of the object; every refusal names its reason (`stream:error()`, one of `serialize.SerializeError`); and wstring is gone.

A packet reader ends with `serializeEnd`:

```luau
local serialize = require("./serialize")

local r = serialize.ReadStream.new(packet)
if not r:serializeObject(message) or not r:serializeEnd() then
	return nil, r:error() -- "past_end", "trailing_data", "non_finite_float", ...
end
```

Standard 2.1's uniform rules (IMPLEMENTING.md U1 to U16) are kept and proved in test/uniform: a read never raises (caller misuse on read refuses `value_out_of_range`), `serialize.refusalName`, `stream:fail(reason)` and `serialize.copyString` are public, and a writer's buffer is unspecified until `flush()`.

DESIGN.md is the design: the API, the refusal reasons, the bit order, the number model, the file layout and the runner.

    make dist-luau      # fetch the pinned Luau 0.741 (sha256 checked) into dist/
    make test           # luau-analyze src/*.luau, then every test/*/
    make test T=smoke   # one test directory
    make controls       # the negative controls: each must fail exactly its list
    make fuzz           # the differential fuzz against serialize.go v2.0.0
    make fuzz-neg       # its negative control: -widen-int must make it go red
    make fuzz-extended FUZZ_SEED=S FUZZ_DURATION=3600s   # the nightly run
    tools/revendor/revendor.sh <tag or full sha>   # re-vendor the standard and the corpus

BSD 3-Clause license.
