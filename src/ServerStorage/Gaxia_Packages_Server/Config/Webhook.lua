--!strict
-- Config/Webhook.lua — WebhookService tunables (SERVER-PRIVATE, never replicated)
-- Channels hold secret URLs (Discord etc.). AutoReport maps an event source
-- to a channel name; that channel must have a URL set or the report stays off.
export type WebhookConfig = {
	Enabled: boolean,
	-- Channel name -> webhook URL (a secret).
	Channels: { [string]: string },
	-- Event source ("Bans", "AntiCheat", "Guild") -> channel name.
	AutoReport: { [string]: string },
	RateLimit: {
		MinInterval: number,
		MaxQueue: number,
		MaxRetries: number,
	},
	Username: string,
}

local Webhook: WebhookConfig = {
	Enabled = true,
	Channels = {
		-- BanReports = "https://discord.com/api/webhooks/...",
		-- ShopStock  = "https://discord.com/api/webhooks/...",
	},
	AutoReport = {
		Bans      = "BanReports",  -- Ban.OnBan / Ban.OnUnban -> this channel
		AntiCheat = "BanReports",  -- AntiCheat hard actions -> this channel
		Guild     = "GuildEvents", -- Guild create / disband / owner-transfer -> this channel
	},
	RateLimit = {
		MinInterval = 2,   -- seconds between sends per channel
		MaxQueue    = 100, -- drop oldest beyond this (bounded memory)
		MaxRetries  = 3,   -- on HTTP 429 / transient failure
	},
	Username = "Gaxia", -- default Discord webhook username override
}

return Webhook
