--!strict
--[[
	Script  : Gaxia_ServerBootstrap (Server)
	Location: ServerScriptService.Gaxia_ServerBootstrap
	Purpose : Eagerly boot the Gaxia server stack:
	            • Load the master server package (GaxiaServer.Shared / .AntiCheat)
	            • Force-load every Lib service so their PlayerAdded hooks wire up
	              before the first player joins.
	            • Load the AntiCheat orchestrator + all detectors.
	            • Bind the single AntiCheat enforcement owner after detectors load.
]]

-- ── Single-boot guard ─────────────────────────────────────────
-- Boot ONLY when this is the place's real server bootstrap: a DIRECT child of
-- ServerScriptService (where default.project.json mounts it, and where the
-- Companion plugin's Installer clones it on "Install Gaxia"). The identical
-- script is also bundled — meant to stay inert — inside the plugin's Payload so
-- the Installer has a copy to place. If the plugin tree is dev-mounted into the
-- DataModel, that Payload copy is a *descendant* of ServerScriptService but NOT
-- a direct child (its parent is the Payload folder), so this strict `==` parent
-- check keeps it from booting a SECOND AntiCheat + DataManager alongside the
-- place's own stack. Must be `==`, never IsDescendantOf — the Payload copy IS a
-- descendant of ServerScriptService when dev-mounted there.
if script.Parent ~= game:GetService("ServerScriptService") then
	return
end

local ServerStorage = game:GetService("ServerStorage")

-- ── Master loader ──────────────────────────────────────────────
-- GaxiaServer is the namespace returned by the server master init module.
local GaxiaServer = require(ServerStorage:WaitForChild("Gaxia_Packages_Server")) :: any

-- ── Force-load Lib services ───────────────────────────────────
-- The Lib namespace is a lazy proxy: accessing GaxiaServer.<Name> requires
-- the underlying module. We touch each service here so its module body runs
-- (PlayerAdded hooks, signal definitions, etc.) before any player joins.
local LIB_SERVICES: { string } = {
	"Data", -- DataManager — must be first; other services use it
	"Settings", -- Net RPC registration before any client settings request
	"Player", -- PlayerService
	"Item", -- ItemService
	"Economy", -- EconomyService
	-- Pet: stat-boost pet system. Force-loaded so its NetService remotes AND its
	-- ItemDef/Loot/Codex catalog register before any player joins — a client
	-- firing PetBuyEgg before the server registered that remote would error.
	"Pet", -- PetService
	"Tool", -- ToolService
	"Zone", -- ZoneService
	-- Chat MUST load before Admin so AdminCommands' chat bridge can register
	-- each built-in command into the ChatCommandSystem at AdminCommands' load.
	"Chat", -- ChatCommandSystem
	"Admin", -- AdminCommands (auto-grants owner role to game creator)
	"Quest", -- QuestSystem
	"Achievement", -- AchievementSystem
	"Level", -- LevelSystem
	"Migration", -- DataMigration
	"Leaderboard", -- LeaderboardService
	"Messages", -- CrossServerMessaging
	-- Ban: persistent ban storage + PlayerAdded gate. MUST load before "Admin"
	-- so BanService.gate is registered for PlayerAdded before any player
	-- connects, AND before "Webhook" so Webhook.autoSubscribe sees Ban already
	-- present without triggering a lazy require from inside task.spawn. The
	-- /ban and /unban chat commands in AdminCommands are thin wrappers around
	-- BanService.Ban / .Unban — one ban code path for the whole framework.
	"Ban", -- BanService
	-- Webhook: load so its auto-reports (Ban / AntiCheat) wire up at boot when a
	-- channel URL is configured. No-ops harmlessly if no channels are set.
	"Webhook", -- WebhookService
	-- Friend: drains cross-server invite queue at PlayerAdded; needs to be loaded
	-- early so the drain hook is registered before late PlayerAdded events.
	"Friend",
	"Party", -- register invite RPCs before client UI can invoke them
	-- Guild: reconciles orphan GuildId on PlayerAdded; subscribes "guild:vault"
	-- via CrossServerMessaging. Must load AFTER Webhook (so the optional Guild
	-- auto-report subscriber in Task 8 sees Guild already present).
	"Guild",
}
for _, key in ipairs(LIB_SERVICES) do
	local mod = GaxiaServer[key]
	if mod == nil then
		warn(`[Gaxia_ServerBootstrap] Failed to load service '{key}'`)
	end
end

-- ── AntiCheat orchestrator + detectors ────────────────────────
-- Requiring the orchestrator runs its loader which auto-discovers every
-- sibling detector ModuleScript and starts the shared sampler loop.
local AntiCheat =
	require(ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("AntiCheat")) :: any

-- ── Single enforcement owner ──────────────────────────────────
-- Detectors only emit evidence/action candidates. This module owns every
-- automatic Kick/Ban decision and starts in Config.AntiCheat.Enforcement.Mode
-- = "observe", so rollout can be calibrated without punishing players.
local Enforcement = GaxiaServer.Enforcement
if Enforcement and Enforcement.Start then
	Enforcement.Start(AntiCheat, GaxiaServer.Ban)
else
	warn(
		"[Gaxia_ServerBootstrap] AntiCheatEnforcement unavailable — automatic AntiCheat actions are disabled"
	)
end

print("[Gaxia_ServerBootstrap] complete — services + AntiCheat online")
