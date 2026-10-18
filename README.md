# serialize.luau

A simple bitpacking serializer for Luau, wire compatible with the C++ [serialize](https://github.com/mas-bandwidth/serialize) library and [serialize.go](https://github.com/mas-bandwidth/serialize.go): the same values produce the same bytes.

Status: in progress. The wire format is serialize's STANDARD.md, format version 1.1, vendored verbatim with the shared conformance vectors in conformance/. The pinned interpreter is Luau 0.741.

DESIGN.md is the design: the API, the bit order, the number model, the file layout and the runner. The streams and the entry are in src/; each serialize family arrives as its own src/serialize_<family>.luau, and until then its methods raise `serialize: <family> not implemented`.

    make dist-luau      # fetch the pinned Luau 0.741 (sha256 checked) into dist/
    make test           # luau-analyze src/*.luau, then every test/*/
    make test T=smoke   # one test directory

BSD 3-Clause license.
