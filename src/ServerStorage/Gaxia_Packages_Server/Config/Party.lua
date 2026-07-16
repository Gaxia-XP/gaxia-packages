--!strict
-- Config/Party.lua — PartyService tunables
return {
	MaxSize       = 4,
	PoolScanLimit = 50,  -- oldest-N queued parties scanned per matchmaking poll (throughput cap)
	PoolTTL       = 120, -- matchmaking pool entry TTL (s)
}
