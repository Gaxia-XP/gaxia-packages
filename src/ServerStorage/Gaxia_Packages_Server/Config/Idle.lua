--!strict
-- Config/Idle.lua — IdleService tunables
return {
	DefaultRate = 1,           -- units/sec when a player has no configured rate
	MaxOffline  = 8 * 3600,    -- offline accrual clamp (s) — a month away ≠ a month's pay
}
