------------------------------ MODULE ReadBoundary ------------------------------
(***************************************************************************)
(* The read stream's input boundary: new and reset over a value that may   *)
(* or may not be a buffer, and a read into a holder that may or may not be *)
(* one. State is what ReadStream keeps: the installed data (its kind and   *)
(* byte length), the bit count derived from it, the bit index, and the     *)
(* latched failure.                                                        *)
(*                                                                         *)
(* Reset installs all of that together. A value that is not a buffer       *)
(* installs an empty, already refused stream (value_out_of_range, no bits).*)
(* OldReset = TRUE models the order before the change: the data is         *)
(* assigned first, the length of a non-buffer then raises, and the old     *)
(* count, cursor and failure stay beside the new data. That is the         *)
(* reversed witness, ReadBoundaryOldReset.cfg, and it must fail.           *)
(*                                                                         *)
(* A read checks its holder before any bit moves: a plain table, or a      *)
(* table whose value is a raw field, is accepted; anything else is refused *)
(* value_out_of_range with no bits moved and no metamethod run. OldHolder  *)
(* models the order before the change: the bits move, then the value is    *)
(* assigned to the holder, which raises on a non-table or frozen holder    *)
(* and runs caller code through __newindex. OldHolder is a definition, so  *)
(* the configurations that do not name it check the new order; the        *)
(* reversed witness, ReadBoundaryOldHolder.cfg, overrides it with          *)
(* OldHolderOn and must fail.                                              *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS MaxBytes, OldReset

OldHolder == FALSE
OldHolderOn == TRUE

\* the holders a read is given: plain (no metatable), raw (a metatable and a
\* raw value field), notTable (nil, a number), frozen, newindex (a metatable
\* with __newindex and no raw value), index (__index only, no raw value)
Holders == {"plain", "raw", "notTable", "frozen", "newindex", "index"}
Accepted == {"plain", "raw"}

VARIABLES kind,     \* "buf" or "bad": what the installed data is
          len,      \* byte length of the installed data (0 for "bad")
          numBits,  \* the stream's bit count
          bits,     \* the bit index
          err,      \* "none" or "out"
          raised,   \* TRUE once any call raised
          metaRan,  \* TRUE once a read ran a holder's metamethod
          badMoved  \* TRUE once a read into a refused holder moved bits or
                    \* ended without value_out_of_range latched

vars == <<kind, len, numBits, bits, err, raised, metaRan, badMoved>>

Init == /\ kind = "buf" /\ len = 0 /\ numBits = 0 /\ bits = 0
        /\ err = "none" /\ raised = FALSE
        /\ metaRan = FALSE /\ badMoved = FALSE

\* reset over a buffer of n bytes: all bookkeeping together
ResetBuf(n) ==
  /\ kind' = "buf" /\ len' = n /\ numBits' = 8 * n /\ bits' = 0
  /\ err' = "none" /\ raised' = FALSE
  /\ UNCHANGED <<metaRan, badMoved>>

\* reset over a value that is not a buffer
ResetBad ==
  /\ IF OldReset
     THEN /\ kind' = "bad" /\ len' = 0
          /\ UNCHANGED <<numBits, bits, err>>
          /\ raised' = TRUE
     ELSE /\ kind' = "bad" /\ len' = 0 /\ numBits' = 0 /\ bits' = 0
          /\ err' = "out" /\ raised' = FALSE
  /\ UNCHANGED <<metaRan, badMoved>>

\* the bits of a read of w: refused when already failed, past the end, or on
\* a stream with no buffer
Move(w) ==
  IF err = "none" /\ bits + w <= numBits
     THEN /\ bits' = bits + w /\ UNCHANGED err
     ELSE /\ UNCHANGED bits /\ err' = "out"

\* a read of w bits into holder h
Read(w, h) ==
  /\ UNCHANGED <<kind, len, numBits>>
  /\ IF ~OldHolder
     THEN IF h \in Accepted
          THEN /\ Move(w)
               /\ UNCHANGED <<raised, metaRan, badMoved>>
          ELSE /\ UNCHANGED bits /\ err' = "out"
               /\ UNCHANGED <<raised, metaRan, badMoved>>
     ELSE /\ Move(w)
          /\ LET stored == err = "none" /\ bits + w <= numBits IN
             /\ raised' = (raised \/ (stored /\ h \in {"notTable", "frozen"}))
             /\ metaRan' = (metaRan \/ (stored /\ h = "newindex"))
             /\ badMoved' = (badMoved \/ (h \notin Accepted /\ stored))

Next == \/ \E n \in 0..MaxBytes : ResetBuf(n)
        \/ ResetBad
        \/ \E w \in 1..MaxBytes, h \in Holders : Read(w, h)

Spec == Init /\ [][Next]_vars

\* the bit count always matches the installed data
CountMatchesData == numBits = 8 * len

\* the cursor is inside the data
CursorInside == bits <= numBits

\* a non-buffer is always an already refused, empty stream
BadIsRefused == kind = "bad" => (err = "out" /\ bits = 0 /\ numBits = 0)

\* no call raises
NeverRaises == raised = FALSE

\* no read runs caller code through its holder
NoCallerCode == metaRan = FALSE

\* a read into a holder that is not one moves no bits and latches
\* value_out_of_range
BadHolderRefused == badMoved = FALSE

=============================================================================
