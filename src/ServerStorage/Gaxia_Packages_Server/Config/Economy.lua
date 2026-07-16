--!strict
-- Config/Economy.lua — EconomyService tunables
return {
	MaxTransaction = 1000000,    -- per-call ceiling (anti-exploit megapayloads)
	MaxBalance     = 1000000000, -- hard balance cap (overflow guard)
}
