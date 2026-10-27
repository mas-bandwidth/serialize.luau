; The serialize.luau roadmap: the data ROADMAP.md is generated from.
; Same shape as nova-sprint's docs/roadmap.sexp: data, never evaluated. Edit this file, then
; regenerate ROADMAP.md with the roadmap tool (github.com/mas-bandwidth/nova-tools/tools/roadmap):
;   roadmap --file docs/roadmap.sexp --out ROADMAP.md
; Never edit ROADMAP.md by hand. Created 2026-10-27 for the work left open when the port moved to
; standard 2.1 (the wrap-up order: rejected and the re-vendor landed, the rest recorded here).
(roadmap "v1"
 :title "serialize.luau roadmap"
 :text "Planned work for serialize.luau. Created 2026-10-27, when the port moved to serialize standard 2.1 (v2.1.0): the rejected refusal reason (U2) and the v2.1.0 re-vendor landed; the remaining uniform rules of IMPLEMENTING.md and the 2026-10-27 audit findings are recorded here, each with its reproducer and the condition that closes it. Landed work is in git."

 :groups
 (
  (group "standard-2.1" :title "Standard 2.1: the uniform rules"
   :text "IMPLEMENTING.md U1 to U16 (vendored from serialize v2.1.0). U2 landed with 2.1.0; the rest are unaudited against this port.")
  (group "audit-2026-10-27" :title "Audit findings, 2026-10-27"
   :text "The cross-port security and correctness audit's findings for this port (AUDIT-LEDGER.md, heading luau). Reproducers are in /Volumes/nova/ai/rowan/working/serialize-love/audit2/serialize.luau/test/audit/ (targeted_test.luau, hostile_test.luau). Each fix runs its reproducer first and confirms it fails.")
 )

 :items
 (
  (item "u-rules-audit" :group "standard-2.1" :area "serialize.luau"
   :title "audit U1 and U3 to U16 against this port, and fix each rule it breaks"
   :text "For each rule the port breaks: a unit test red now, the fix, the test green (no real time, no sockets, zero analyzer diagnostics). Rules already kept get a one-line note. Known starting point: U14 (a public fail(reason), and an object error value outside the closed list must latch rejected; serializeObject still latches the caller's own value as given) and U16 (the two findings below). Done when: every rule U1 to U16 is noted kept or has a landed test plus fix on green main."
   :date "2026-10-27"
   :origin "PORT-2.1-BRIEF.md step 4, deferred by the wrap-up order 2026-10-27")
  (item "ledger-fractional-bits" :group "audit-2026-10-27" :area "serialize.luau"
   :title "M: a non-integer bits parameter is accepted (U16 declaration validation)"
   :text "serializeBits with a fractional bit count is accepted, moves the bit position to a fraction, reads wrong values and traps later. Reproducer: targeted_test.luau TestC_FractionalBitsParam and TestC2_FractionalBitsConsequences. Done when: TestC* pass: every stream raises on a non-integer bits declaration before any bit moves, with a unit test."
   :date "2026-10-27"
   :origin "AUDIT-LEDGER.md, luau, M")
  (item "ledger-precomputed-wrap" :group "audit-2026-10-27" :area "serialize.luau"
   :title "L: the precomputed compressed_float validator is fooled by a 2^32 wrap (U16)"
   :text "serializeCompressedFloatPrecomputed accepts bogus constants whose width check wraps at 2^32. Reproducer: targeted_test.luau TestD_PrecomputedBogusConstants. Done when: TestD passes: bogus precomputed constants raise on every stream, with a unit test."
   :date "2026-10-27"
   :origin "AUDIT-LEDGER.md, luau, L")
  (item "ledger-uint128-empty-holder" :group "audit-2026-10-27" :area "serialize.luau"
   :title "L: serializeUint128 read into an empty holder {} raises"
   :text "A read into {} raises instead of assigning the value. Reproducer: targeted_test.luau TestA_Uint128ReadEmptyHolder. Done when: TestA passes, with a unit test."
   :date "2026-10-27"
   :origin "AUDIT-LEDGER.md, luau, L")
  (item "ledger-uint64-number" :group "audit-2026-10-27" :area "serialize.luau"
   :title "L: a number written to serializeUint64 or serializeBits64 raises a raw Luau error, not the documented misuse text"
   :text "Writing a plain number where an integer is required surfaces the integer library's own error instead of a serialize: raise naming the rule (DESIGN.md (g)). Reproducer: targeted_test.luau TestB_Uint64WriteNumber. Done when: TestB passes: the raise names the rule in serialize's own text, with a unit test."
   :date "2026-10-27"
   :origin "AUDIT-LEDGER.md, luau, L")
  (item "perf-reader-speed" :group "audit-2026-10-27" :area "serialize.luau"
   :title "perf: the reader is about 3.4x slower than the writer (bit at a time)"
   :text "A separate performance job, not a correctness fix. Reproducer: targeted_test.luau TestF_ReaderSpeed. Timing runs go only on amd-3 with nothing else running; never trade read-path speed for a check without measuring it. Done when: the reader is measured on amd-3 within an agreed ratio of the writer, before and after numbers recorded."
   :date "2026-10-27"
   :origin "AUDIT-LEDGER.md, luau, L (perf card)")
 ))
