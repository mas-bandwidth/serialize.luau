--!strict
-- serialize_smoke_present.luau — a test-only family file the lazy dispatch
-- loads from the unit directory (DESIGN.md (h)); no card creates it in src/.
return table.freeze({ marker = "smoke_present from the unit" })
