---------------------------- MODULE ReadBoundary ----------------------------
(***************************************************************************)
(* The holder boundary of a public read (IMPLEMENTING.md U7, U16).          *)
(*                                                                         *)
(* A read stream's public read takes a holder. The holder is checked once,  *)
(* in the public dispatch, before any bit moves: an unwritable holder is    *)
(* refused as value_out_of_range, the bit index does not move, and nothing  *)
(* is written. The old order read the field, then assigned, so an           *)
(* unwritable holder raised after the bits were consumed, with no refusal   *)
(* latched. A stream that already failed keeps its first reason.            *)
(*                                                                         *)
(* Variables are the read stream's: the bit index and the latched reason.   *)
(* trapped records a raise out of the read; assigned records a write to     *)
(* the holder. Spec is the checked order; SpecOldHolder reads then assigns. *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT NumBits

VARIABLES bits, reason, trapped, assigned, before, lastWritable, lastFresh
vars == <<bits, reason, trapped, assigned, before, lastWritable, lastFresh>>
readVars == <<bits, reason, trapped, assigned>>

Reasons == {"none", "value_out_of_range", "past_end"}

Init == /\ bits = 0
        /\ reason = "none"
        /\ trapped = FALSE
        /\ assigned = FALSE
        /\ before = 0
        /\ lastWritable = TRUE
        /\ lastFresh = TRUE

\* A read of width bits into a holder; writable says whether the assignment
\* would succeed.
CheckedRead(width, writable) ==
    IF reason # "none"
       THEN UNCHANGED readVars
    ELSE IF ~writable
       THEN /\ reason' = "value_out_of_range"
            /\ UNCHANGED <<bits, trapped, assigned>>
    ELSE IF bits + width > NumBits
       THEN /\ reason' = "past_end"
            /\ UNCHANGED <<bits, trapped, assigned>>
    ELSE /\ bits' = bits + width
         /\ assigned' = TRUE
         /\ UNCHANGED <<reason, trapped>>

OldHolderRead(width, writable) ==
    IF reason # "none"
       THEN UNCHANGED readVars
    ELSE IF bits + width > NumBits
       THEN /\ reason' = "past_end"
            /\ UNCHANGED <<bits, trapped, assigned>>
    ELSE /\ bits' = bits + width
         /\ IF writable
               THEN /\ assigned' = TRUE
                    /\ UNCHANGED <<reason, trapped>>
               ELSE /\ trapped' = TRUE
                    /\ UNCHANGED <<reason, assigned>>

Widths == {1, 3, 8}

\* Each step also records what it started from, so an invariant can see
\* what the step did to a holder it could not write.
Step(read(_, _)) ==
    \E width \in Widths, writable \in BOOLEAN:
        /\ read(width, writable)
        /\ before' = bits
        /\ lastWritable' = writable
        /\ lastFresh' = (reason = "none")

Next == Step(CheckedRead)
NextOldHolder == Step(OldHolderRead)

Spec == Init /\ [][Next]_vars
SpecOldHolder == Init /\ [][NextOldHolder]_vars

TypeOK == /\ bits \in 0..NumBits
          /\ reason \in Reasons
          /\ trapped \in BOOLEAN
          /\ assigned \in BOOLEAN
          /\ before \in 0..NumBits
          /\ lastWritable \in BOOLEAN
          /\ lastFresh \in BOOLEAN

\* A read never raises: an unwritable holder is a refusal.
NoTrap == ~trapped

\* An unwritable holder on a live stream is refused as value_out_of_range
\* before any bit moves, whatever the bits left.
HolderCheckedFirst ==
    (lastFresh /\ ~lastWritable) => (reason = "value_out_of_range" /\ bits = before)
=============================================================================
