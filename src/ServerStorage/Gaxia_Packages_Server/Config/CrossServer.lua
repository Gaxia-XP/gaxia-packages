--!strict
-- Config/CrossServer.lua — Cross-server messaging (CrossServerMessaging) tunables
-- Token bucket over MessagingService (~150 msg/min platform cap).
return {
	TokenRefillPerSec = 2,  -- sustained publish rate
	TokenBurstMax     = 10, -- burst allowance for bursty events
}
