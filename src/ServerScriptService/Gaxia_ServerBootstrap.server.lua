--!strict
--[[
	Script  : Gaxia_ServerBootstrap (Server)
	Location: ServerScriptService.Gaxia_ServerBootstrap
	Purpose : Boot the Gaxia server stack:
	            • GaxiaServer.Boot() starts the services listed in Config/Features
	              (or the game-owned ServerStorage.GaxiaFeatures) in dependency
	              order. Services not listed start on first use.
	            • Wire AntiCheat.OnAction into the default action handler (kick on
	              "hard"; AntiCheat runs in observe mode until
	              Config.AntiCheat.Enforce = true, so it only reports "observe").
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

-- ── Master loader + boot ──────────────────────────────────────
local GaxiaServer = require(ServerStorage:WaitForChild("Gaxia_Packages_Server"))
GaxiaServer.Boot()

-- ── AntiCheat default action handler ──────────────────────────
-- Only when AntiCheat is running (it is in Features by default); touching
-- GaxiaServer.AntiCheat otherwise would load it just to wire this handler.
if not GaxiaServer.IsEnabled("AntiCheat") then
	print("[Gaxia_ServerBootstrap] complete — AntiCheat not enabled in Features")
	return
end
local AntiCheat = GaxiaServer.AntiCheat :: any

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
