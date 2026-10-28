; The serialize.luau roadmap: the data ROADMAP.md is generated from.
; Same shape as nova-sprint's docs/roadmap.sexp: data, never evaluated. Edit this file, then
; regenerate ROADMAP.md with the roadmap tool (github.com/mas-bandwidth/nova-tools/tools/roadmap):
;   roadmap --file docs/roadmap.sexp --out ROADMAP.md
; Never edit ROADMAP.md by hand. Created 2026-10-27 for the work left open when the port moved to
; standard 2.1 (the wrap-up order: rejected and the re-vendor landed, the rest recorded here).
(roadmap "v1"
 :title "serialize.luau roadmap"
 :text "Planned work for serialize.luau. Created 2026-10-27, when the port moved to serialize standard 2.1 (v2.1.0). The re-vendor, the rejected refusal reason (U2), the uniform rules U1 and U3 to U16 of IMPLEMENTING.md and the four correctness findings of the 2026-10-27 audit have landed (test/uniform); what is left is recorded here with the condition that closes it. Landed work is in git."

 :groups
 (
  (group "audit-2026-10-27" :title "Audit findings, 2026-10-27"
   :text "The cross-port security and correctness audit's findings for this port (AUDIT-LEDGER.md, heading luau). Reproducers are in /Volumes/nova/ai/rowan/working/serialize-love/audit2/serialize.luau/test/audit/ (targeted_test.luau, hostile_test.luau). The four correctness findings landed with the uniform rules; the performance finding is a separate job.")
 )

 :items
 (
  (item "perf-reader-speed" :group "audit-2026-10-27" :area "serialize.luau"
   :title "perf: the reader is about 3.4x slower than the writer (bit at a time)"
   :text "A separate performance job, not a correctness fix. Reproducer: targeted_test.luau TestF_ReaderSpeed. Timing runs go only on amd-3 with nothing else running; never trade read-path speed for a check without measuring it. The uniform-rules change added one integer test of the bit count (bits // 1 == bits, and a type check) to serializeBits and serializeBits64 on read: measure it in the same run. Done when: the reader is measured on amd-3 within an agreed ratio of the writer, before and after numbers recorded."
   :date "2026-10-27"
   :origin "AUDIT-LEDGER.md, luau, L (perf card)")
 ))
