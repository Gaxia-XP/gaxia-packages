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
local Gaxia = require(
	ReplicatedStorage:WaitForChild("Gaxia_Packages")
) :: any

-- ── Start client AntiCheat ──
-- Reading the AntiCheat key triggers ClientAntiCheat to require — its module
-- body kicks off the sampler loop on its own. We hold the reference so the
-- GC can't collect it.
local ClientAC = Gaxia.AntiCheat
if ClientAC == nil then
	warn("[Gaxia_ClientBootstrap] ClientAntiCheat unavailable")
end

-- ── Pre-warm common namespaces ──
-- Touching these once forces their underlying modules to load now (during
-- character spawn) rather than on first user interaction (mid-gameplay frame).
local _ = Gaxia.UI       -- UIController + its dependents
local _ = Gaxia.Input    -- InputManager (lazy if absent)
local _ = Gaxia.Camera   -- CameraController (lazy if absent)
local _ = Gaxia.Sound    -- SoundController (lazy if absent)
-- AdminPanel wires its toolbar button, F2 hotkey, and role-hint subscription
-- in its module body — touch it once so that happens at spawn (the panel only
-- shows its button to moderator+; F2 opens the shell for anyone but the server
-- gates all content + rejects unauthorized actions).
local _ = Gaxia.UI.AdminPanel
-- ChatFeedback subscribes to Events/Chat/SystemMessage in its module body —
-- pre-warm so chat-command replies (/help, admin command outcomes) render
-- from the first command typed.
local _ = Gaxia.ChatFeedback
-- PetController subscribes to PetSync/PetHatch and binds the P toggle key in its
-- module body — pre-warm so the pet panel is reachable from spawn.
local _ = Gaxia.UI.PetController

print("[Gaxia_ClientBootstrap] complete — shared package + ClientAntiCheat online")
