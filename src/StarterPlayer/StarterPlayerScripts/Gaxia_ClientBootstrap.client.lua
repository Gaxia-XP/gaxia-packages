--!strict
--[[
	Script  : Gaxia_ClientBootstrap (LocalScript)
	Location: StarterPlayer.StarterPlayerScripts.Gaxia_ClientBootstrap
	Purpose : Eagerly load the Gaxia shared package and start ClientAntiCheat
	          on this client. Other client modules are lazy via Gaxia.* proxies.
]]

-- ── Single-boot guard ─────────────────────────────────────────
-- Boot ONLY the real client bootstrap — the copy StarterPlayerScripts clones
-- into each player's PlayerScripts (a descendant of Players) at spawn. The
-- identical script is bundled inert in the Companion plugin's Payload (for the
-- Installer to clone); if the plugin tree is dev-mounted into the DataModel,
-- that Payload copy must NOT start a second client stack. The Payload copy is
-- never a descendant of Players, so this check keeps it inert (a LocalScript in
-- the Payload wouldn't run anyway — belt-and-suspenders for any odd mount).
if not script:IsDescendantOf(game:GetService("Players")) then
	return
end


local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Master loader ──
local packageRoot = ReplicatedStorage:WaitForChild("Gaxia_Packages")
local Gaxia = require(packageRoot) :: any

-- ── Which client modules to load now (Features.lua or the game-owned override) ──
local features = require(packageRoot:WaitForChild("Features"))
local entries = features.Client
local override = ReplicatedStorage:FindFirstChild("GaxiaClientFeatures")
if override and override:IsA("ModuleScript") then
	local ok, result = pcall(require, override)
	if ok and type(result) == "table" and type(result.Client) == "table" then
		entries = result.Client
	else
		warn("[Gaxia_ClientBootstrap] ReplicatedStorage.GaxiaClientFeatures must return { Client = { ... } } — ignored")
	end
end

-- ── Services the server started (published by the server loader at Boot) ──
-- Normally already replicated with the package. If it never arrives (older server
-- package), load every entry like before.
local FEATURES_ATTRIBUTE = "GaxiaServerFeatures"
local published = packageRoot:GetAttribute(FEATURES_ATTRIBUTE)
local deadline = os.clock() + 10
while published == nil and os.clock() < deadline do
	task.wait(0.1)
	published = packageRoot:GetAttribute(FEATURES_ATTRIBUTE)
end
local serverStarted: { [string]: boolean }? = nil
if type(published) == "string" then
	local set: { [string]: boolean } = {}
	for name in string.gmatch(published, "[^,]+") do
		set[name] = true
	end
	serverStarted = set
end

-- ── Pre-warm ──
-- Touching a key loads its module now (during character spawn) rather than on
-- first use. Modules such as ClientAntiCheat, AdminPanel, ChatFeedback and
-- PetController wire their loops, hotkeys and subscriptions in their module body.
for _, entry in ipairs(entries) do
	local needs = entry.RequiresServer
	if needs and serverStarted and not serverStarted[needs] then
		continue
	end
	local value: any = Gaxia
	for part in string.gmatch(entry.Key, "[^.]+") do
		value = if value ~= nil then value[part] else nil
	end
	if value == nil then
		warn(`[Gaxia_ClientBootstrap] {entry.Key} unavailable`)
	end
end

print("[Gaxia_ClientBootstrap] complete — client features loaded")
