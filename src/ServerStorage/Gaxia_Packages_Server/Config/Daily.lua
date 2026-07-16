--!strict
-- Config/Daily.lua — DailyRewardService tunables
return {
	DaySeconds  = 86400,        -- claim gate (once per this window)
	ResetWindow = 2 * 86400,    -- streak resets if the gap exceeds this
}
