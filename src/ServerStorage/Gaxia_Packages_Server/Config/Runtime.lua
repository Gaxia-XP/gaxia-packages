--!strict
-- Config/Runtime.lua — Runtime flags
-- NOTE: UI notification/animation constants are CLIENT-side (Toast /
-- NotificationService) and can't read this server-only Config — they stay in
-- Shared/Constants (client-readable), same boundary as Network rate limits.
return {
	DebugMode      = false,
	VerboseLogging = false,
	Environment    = "production", -- "production" | "development" | "test"
}
