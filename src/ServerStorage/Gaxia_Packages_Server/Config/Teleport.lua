--!strict
-- Config/Teleport.lua — Cross-place teleport retry (TeleportService) tunables
return {
	Retry = { MaxAttempts = 4, BaseDelay = 1, MaxDelay = 15 }, -- backoff for failed TeleportAsync
}
