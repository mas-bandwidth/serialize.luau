------------------------------ MODULE ReadBoundary ------------------------------
(***************************************************************************)
(* The read stream's input boundary: new and reset over a value that may   *)
(* or may not be a buffer. State is what ReadStream keeps: the installed   *)
(* data (its kind and byte length), the bit count derived from it, the     *)
(* bit index, and the latched failure.                                     *)
(*                                                                         *)
(* Reset installs all of that together. A value that is not a buffer       *)
(* installs an empty, already refused stream (value_out_of_range, no bits).*)
(* OldReset = TRUE models the order before the change: the data is         *)
(* assigned first, the length of a non-buffer then raises, and the old     *)
(* count, cursor and failure stay beside the new data. That is the         *)
(* reversed witness, ReadBoundaryOldReset.cfg, and it must fail.           *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS MaxBytes, OldReset

VARIABLES kind,     \* "buf" or "bad": what the installed data is
          len,      \* byte length of the installed data (0 for "bad")
          numBits,  \* the stream's bit count
          bits,     \* the bit index
          err,      \* "none" or "out"
          raised    \* TRUE once any call raised

vars == <<kind, len, numBits, bits, err, raised>>

Init == /\ kind = "buf" /\ len = 0 /\ numBits = 0 /\ bits = 0
        /\ err = "none" /\ raised = FALSE

\* reset over a buffer of n bytes: all bookkeeping together
ResetBuf(n) ==
  /\ kind' = "buf" /\ len' = n /\ numBits' = 8 * n /\ bits' = 0
  /\ err' = "none" /\ raised' = FALSE

\* reset over a value that is not a buffer
ResetBad ==
  IF OldReset
  THEN /\ kind' = "bad" /\ len' = 0
       /\ UNCHANGED <<numBits, bits, err>>
       /\ raised' = TRUE
  ELSE /\ kind' = "bad" /\ len' = 0 /\ numBits' = 0 /\ bits' = 0
       /\ err' = "out" /\ raised' = FALSE

\* a read of w bits: refused when already failed, past the end, or on a
\* stream with no buffer
Read(w) ==
  /\ IF err = "none" /\ bits + w <= numBits
        THEN /\ bits' = bits + w /\ UNCHANGED err
        ELSE /\ UNCHANGED bits /\ err' = "out"
  /\ UNCHANGED <<kind, len, numBits, raised>>

Next == \/ \E n \in 0..MaxBytes : ResetBuf(n)
        \/ ResetBad
        \/ \E w \in 1..MaxBytes : Read(w)

Spec == Init /\ [][Next]_vars

\* the bit count always matches the installed data
CountMatchesData == numBits = 8 * len

\* the cursor is inside the data
CursorInside == bits <= numBits

\* a non-buffer is always an already refused, empty stream
BadIsRefused == kind = "bad" => (err = "out" /\ bits = 0 /\ numBits = 0)

\* no call raises
NeverRaises == raised = FALSE

=============================================================================
