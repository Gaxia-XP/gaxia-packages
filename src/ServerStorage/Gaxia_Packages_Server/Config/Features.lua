--!strict
-- Config/Features.lua — which services start when the server boots.
--
-- Services listed here start at boot, in this order (anything they Need starts
-- first). A service that is NOT listed is never loaded unless the game uses it:
-- it starts the first time game code touches GaxiaServer.<Name> or calls one of
-- its functions. Names autocomplete and typos are flagged (Types.ServiceName).
--
-- GAME-OWNED OVERRIDE: the Companion plugin's Install/Update replaces this whole
-- package (Config included), so do not customise this file in your place. Instead
-- create a ModuleScript ServerStorage.GaxiaFeatures that returns
--     { Services = { "Data", "Player", ... } }
-- and it replaces the list below.
--
-- Worth listing when your game uses them (they have work to do before first use):
--   "Monetization"   binds MarketplaceService.ProcessReceipt — REQUIRED if you sell
--                    developer products, or receipts are never granted
--   "Settings"       creates the client settings remote (Events/Gaxia_Settings)
--   "Party"          creates the party invite remotes + joins pending invites
--   "Analytics"      starts the event funnel (Economy/Level/Quest → sink)
--   "Journal"        records AntiCheat flags/actions (ring buffer + optional store)
--   "AntiCheatAdmin" registers /acflags /acclear /acban /acunban /ac /flag
--   "Event"          starts the timed-event scheduler loop
--   "Cooldown"       starts the cooldown sweep loop
--   "Idle", "Placement", "Visit"   per-player state hooks
-- Everything else (Economy, Item, Quest, …) is a plain API with nothing to do
-- until it is called; listing it only makes it load at boot instead of on first use.

local Types = require(script.Parent.Parent.Types)

local Features: Types.Features = {
	Services = {
		"AntiCheat", -- observe mode by default: see Config/AntiCheat.lua (Enforce)
		"Data",
		"Player",
		"Item",
		"Economy",
		"Pet",
		"Tool",
		"Zone",
		"Chat",
		"Admin",
		"Quest",
		"Achievement",
		"Level",
		"Migration",
		"Leaderboard",
		"Messages",
		"Ban",
		"Webhook",
		"Friend",
		"Guild",
	},
}

return Features
