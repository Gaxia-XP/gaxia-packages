--!strict
-- Config/Raid.lua — RaidService tunables
return {
	Currency          = "Coins",
	Cooldown          = 300,     -- attacker re-raid cooldown (s)
	RevengeProtection = 600,     -- defender shield after being raided (s)
	LootFraction      = 0.1,     -- fraction of defender vault value lootable
	MaxLoot           = 1000000, -- hard cap per raid
	RevengeMax        = 20,      -- revenge-list length kept per defender
}
