--!strict
-- Features.lua (client) — which client modules Gaxia_ClientBootstrap loads at spawn.
--
-- Everything else in Gaxia.* still loads on first use. An entry with
-- RequiresServer is skipped when that service is not running on the server (the
-- server publishes its started services on this ModuleScript's
-- "GaxiaServerFeatures" attribute), so the client never waits for remotes that
-- will never exist.
--
-- GAME-OWNED OVERRIDE: the Companion plugin's Install/Update replaces this whole
-- package, so do not customise this file in your place. Create a ModuleScript
-- ReplicatedStorage.GaxiaClientFeatures that returns { Client = { ... } } instead.

export type ClientKey =
	"AntiCheat" | "Input" | "Camera" | "Sound" | "Effects" | "ChatFeedback" | "DebugConsole"
	| "Dialog" | "Tooltip" | "Cutscene"
	| "UI.UIController" | "UI.NotificationService" | "UI.HealthBarController" | "UI.MenuController"
	| "UI.InventoryController" | "UI.HUDController" | "UI.LoadingScreenController"
	| "UI.AdminPanel" | "UI.PetController" | "UI.FriendListPanel" | "UI.GuildPanel" | "UI.InviteToast"

export type ClientEntry = {
	Key: ClientKey,
	-- Server service (Types.ServiceName) this module talks to, if any.
	RequiresServer: string?,
}

export type ClientFeatures = {
	Client: { ClientEntry },
}

local Features: ClientFeatures = {
	Client = {
		-- ClientAntiCheat sends the heartbeats the server's HeartbeatGuard expects.
		{ Key = "AntiCheat", RequiresServer = "AntiCheat" },
		{ Key = "Input" },
		{ Key = "Camera" },
		{ Key = "Sound" },
		-- Toolbar button + F2 hotkey; the server gates all content by role.
		{ Key = "UI.AdminPanel", RequiresServer = "Admin" },
		-- Renders chat-command replies (Events/Chat/SystemMessage).
		{ Key = "ChatFeedback", RequiresServer = "Chat" },
		-- Pet panel (P key) + PetSync/PetHatch subscriptions.
		{ Key = "UI.PetController", RequiresServer = "Pet" },
	},
}

return Features
