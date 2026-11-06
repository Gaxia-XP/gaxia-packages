--!strict
--[[
	Script  : Gaxia_ServerBootstrap (Server)
	Location: ServerScriptService.Gaxia_ServerBootstrap
	Purpose : Boot the Gaxia server stack:
	            • GaxiaServer.Boot() starts the services listed in Config/Features
	              (or the game-owned ServerStorage.GaxiaFeatures) in dependency
	              order. Services not listed start on first use.
	            • Make sure the single AntiCheat enforcement owner
	              (AntiCheatEnforcement, GaxiaServer.Enforcement) is running: it alone
	              kicks/bans on "hard" candidates. AntiCheat runs in observe mode
	              until Config.AntiCheat.Enforce = true, so it only reports "observe".
	            • Log soft AntiCheat actions to Output.
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

-- ── Master loader + boot ──────────────────────────────────────
local GaxiaServer = require(ServerStorage:WaitForChild("Gaxia_Packages_Server"))
GaxiaServer.Boot()

-- ── AntiCheat action handling ─────────────────────────────────
-- Only when AntiCheat is running (it is in Features by default); touching
-- GaxiaServer.AntiCheat otherwise would load it just to wire this handler.
if not GaxiaServer.IsEnabled("AntiCheat") then
	print("[Gaxia_ServerBootstrap] complete — AntiCheat not enabled in Features")
	return
end
-- GaxiaServer's type lists only the installed packages, and AntiCheat /
-- Enforcement may not be installed: read them untyped.
local optional: any = GaxiaServer
local AntiCheat = optional.AntiCheat

-- ── Single enforcement owner ──────────────────────────────────
-- Detectors only emit evidence and action candidates. AntiCheatEnforcement owns
-- every automatic Kick/Ban (exemptions, strikes, cooldown, Config.AntiCheat
-- .Enforcement.Actions); Ban starts it, and touching it here starts it too. There
-- is deliberately no second kick handler here: two enforcing consumers drifted
-- apart (exemption, dedupe) before.
if optional.Enforcement == nil then
	warn("[Gaxia_ServerBootstrap] AntiCheatEnforcement unavailable — automatic AntiCheat actions are disabled")
end

-- Soft action → warn via Output. Plug in your own warning UI / log here.
-- ("hard" / "observe" candidates: AntiCheatEnforcement decides, the Journal
-- records them.)
AntiCheat.OnAction:Connect(function(player: Player, reason: string, kind: string)
	if kind == "soft" then
		warn(`[Gaxia_AntiCheat] soft action against {player.Name}: {reason}`)
	end
end)

print("[Gaxia_ServerBootstrap] complete — services + AntiCheat online")
