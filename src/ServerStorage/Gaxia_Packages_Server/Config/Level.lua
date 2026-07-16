--!strict
-- Config/Level.lua — LevelSystem (progression) tunables
return {
	CurveBase     = 100, -- needed XP = floor(CurveBase * level^CurveExponent)
	CurveExponent = 1.5, -- growth exponent (higher = steeper leveling)
	StartLevel    = 1,   -- level a fresh profile starts at
}
