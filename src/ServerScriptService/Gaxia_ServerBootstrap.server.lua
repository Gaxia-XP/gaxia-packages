--!strict
--[[
	Script  : Gaxia_ServerBootstrap (Server)
	Location: ServerScriptService.Gaxia_ServerBootstrap
	Purpose : Eagerly boot the Gaxia server stack:
	            • Load the master server package (GaxiaServer.Shared / .AntiCheat)
	            • Force-load every Lib service so their PlayerAdded hooks wire up
	              before the first player joins.
	            • Load the AntiCheat orchestrator + all detectors.
	            • Wire OnAction into a default action handler (kick on hard).
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


local Players       = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

-- ── Master loader ──────────────────────────────────────────────
-- GaxiaServer is the namespace returned by the server master init module.
local GaxiaServer = require(
	ServerStorage:WaitForChild("Gaxia_Packages_Server")
) :: any

-- ── Force-load Lib services ───────────────────────────────────
-- The Lib namespace is a lazy proxy: accessing GaxiaServer.<Name> requires
-- the underlying module. We touch each service here so its module body runs
-- (PlayerAdded hooks, signal definitions, etc.) before any player joins.
local LIB_SERVICES: { string } = {
	"Data",        -- DataManager — must be first; other services use it
	"Player",      -- PlayerService
	"Item",        -- ItemService
	"Economy",     -- EconomyService
	-- Pet: stat-boost pet system. Force-loaded so its NetService remotes AND its
	-- ItemDef/Loot/Codex catalog register before any player joins — a client
	-- firing PetBuyEgg before the server registered that remote would error.
	"Pet",         -- PetService
	"Tool",        -- ToolService
	"Zone",        -- ZoneService
	-- Chat MUST load before Admin so AdminCommands' chat bridge can register
	-- each built-in command into the ChatCommandSystem at AdminCommands' load.
	"Chat",        -- ChatCommandSystem
	"Admin",       -- AdminCommands (auto-grants owner role to game creator)
	"Quest",       -- QuestSystem
	"Achievement", -- AchievementSystem
	"Level",       -- LevelSystem
	"Migration",   -- DataMigration
	"Leaderboard", -- LeaderboardService
	"Messages",    -- CrossServerMessaging
	-- Ban: persistent ban storage + PlayerAdded gate. MUST load before "Admin"
	-- so BanService.gate is registered for PlayerAdded before any player
	-- connects, AND before "Webhook" so Webhook.autoSubscribe sees Ban already
	-- present without triggering a lazy require from inside task.spawn. The
	-- /ban and /unban chat commands in AdminCommands are thin wrappers around
	-- BanService.Ban / .Unban — one ban code path for the whole framework.
	"Ban",         -- BanService
	-- Webhook: load so its auto-reports (Ban / AntiCheat) wire up at boot when a
	-- channel URL is configured. No-ops harmlessly if no channels are set.
	"Webhook",     -- WebhookService
	-- Friend: drains cross-server invite queue at PlayerAdded; needs to be loaded
	-- early so the drain hook is registered before late PlayerAdded events.
	"Friend",
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
local AntiCheat = require(
	ServerStorage:WaitForChild("Gaxia_Packages_Server")
		:WaitForChild("AntiCheat")
		
) :: any

-- ── Default OnAction handler ──────────────────────────────────
-- Soft action  → warn the player via output + game console.
-- Hard action  → kick. Use a guard so we don't kick twice in a row for the
-- same reason while the orchestrator is still emitting follow-up flags.
local kickedReasons: { [number]: { [string]: boolean } } = {}

AntiCheat.OnAction:Connect(function(player: Player, reason: string, kind: string)
	if kind == "hard" then
		local uid = player.UserId
		-- Same exemption as BanService.escalate — OnAction has two enforcing
		-- consumers and both must skip the creator/high roles, or this one
		-- still kicks the very user the escalation exemption protects.
		local Ban = GaxiaServer.Ban
		if Ban and Ban.IsEscalationExempt and Ban.IsEscalationExempt(uid) then
			warn(`[Gaxia_AntiCheat] HARD action against {player.Name}: {reason} — exempt (high role), not kicking`)
			return
		end
		kickedReasons[uid] = kickedReasons[uid] or {}
		if kickedReasons[uid][reason] then return end
		kickedReasons[uid][reason] = true
		warn(`[Gaxia_AntiCheat] HARD action against {player.Name}: {reason} — kicking`)
		-- Brief delay so the kick reason reaches the client before disconnect.
		task.delay(0.1, function()
			if player.Parent then
				player:Kick(`Kicked by Gaxia_AntiCheat (reason: {reason})`)
			end
		end)
	elseif kind == "soft" then
		-- soft: print only. Plug in your own warning UI / log here.
		warn(`[Gaxia_AntiCheat] soft action against {player.Name}: {reason}`)
	end
	-- kind == "observe": would have been "hard", but Config.AntiCheat.Enforce is
	-- false — the orchestrator already warned once; nothing to enforce here.
end)

Players.PlayerRemoving:Connect(function(player: Player)
	-- Clean up per-player kick-dedupe state so a rejoining player can be
	-- re-kicked if they cheat again.
	kickedReasons[player.UserId] = nil
end)

print("[Gaxia_ServerBootstrap] complete — services + AntiCheat online")
