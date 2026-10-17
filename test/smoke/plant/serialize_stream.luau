--!strict
-- a shadowing serialize_stream.luau the runner plants in the working
-- directory, one level above the unit (DESIGN.md (f), (i)): it raises if loaded.
error("SHADOW serialize_stream.luau loaded from outside the unit")
