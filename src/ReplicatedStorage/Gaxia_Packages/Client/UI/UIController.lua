--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   UIController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/UIController
-- Purpose:  Central UI manager. Builds templates via the code-first
--           Templates module (no .rbxm binary), and exposes convenience
--           getters for HUD / Overlays under PlayerGui.Gaxia_UI.
-- ─────────────────────────────────────────────────────────────

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UIController = {}
-- The module's own type (every function below), so the server stub and the
-- client module share one type and `Gaxia.UI.UIController.<method>` autocompletes.
export type UIController = typeof(UIController)

-- Client-only module. The server gets an EMPTY table (calls error there); only
-- its type is the client module's.
if not RunService:IsClient() then
	return ({} :: any) :: typeof(UIController)
end

-- ── Constants ──
local SCREEN_WAIT_TIMEOUT: number = 5
local ACTIVE_SCREEN_NAME: string = "Gaxia_UI"

-- ── Cached references ──
local LocalPlayer: Player = Players.LocalPlayer
local PlayerGui: PlayerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

-- ── Templates (code-first, replaces legacy StarterGui Templates.rbxm) ──
-- Sibling require (typed): keeps the dependency local and avoids the master
-- loader's lazy proxy round-trip.
local Templates = require(script.Parent.Templates)

-- Names CloneTemplate knows (re-exported from Templates for callers).
export type TemplateName = Templates.TemplateName

-- ── GetActiveScreen ──
-- Returns the cloned ScreenGui in PlayerGui (Roblox auto-clones from StarterGui).
function UIController.GetActiveScreen(): ScreenGui?
	local screen = PlayerGui:WaitForChild(ACTIVE_SCREEN_NAME, SCREEN_WAIT_TIMEOUT)
	-- WHY: nil-safe — caller decides how to handle missing UI.
	if screen and screen:IsA("ScreenGui") then
		return screen
	end
	return nil
end

-- ── HUD ──
-- Container for persistent on-screen elements (health bars, text labels).
function UIController.HUD(): Folder?
	local screen = UIController.GetActiveScreen()
	if not screen then
		return nil
	end
	local hud = screen:FindFirstChild("HUD")
	if hud and hud:IsA("Folder") then
		return hud
	end
	return nil
end

-- ── Overlays ──
-- Container for modal / temporary UI (menus, dialogs, inventory).
function UIController.Overlays(): Folder?
	local screen = UIController.GetActiveScreen()
	if not screen then
		return nil
	end
	local overlays = screen:FindFirstChild("Overlays")
	if overlays and overlays:IsA("Folder") then
		return overlays
	end
	return nil
end

-- ── CloneTemplate ──
-- Builds a fresh instance of the named template via the code-first
-- Templates module, parents it (default = active ScreenGui), and flips
-- Visible=true so callers can stage further without an extra step.
-- The legacy name "CloneTemplate" is preserved so existing call sites
-- (NotificationService / HealthBarController / MenuController /
-- InventoryController) keep working — semantics are identical from
-- their perspective.
function UIController.CloneTemplate(templateName: TemplateName | string, parent: Instance?): GuiObject?
	-- Looked up by runtime name (unknown names warn below), hence the `any` index.
	local builder = (Templates :: any)[templateName]
	if typeof(builder) ~= "function" then
		warn(`[UIController] Template '{templateName}' not registered in Templates module`)
		return nil
	end

	local ok, result = pcall(builder, nil)  -- build unparented first
	if not ok then
		warn(`[UIController] Build failed for '{templateName}': {tostring(result)}`)
		return nil
	end
	if not result or not (result :: any):IsA("GuiObject") then
		warn(`[UIController] Template '{templateName}' did not return a GuiObject`)
		return nil
	end

	local inst = result :: GuiObject
	inst.Visible = true
	inst.Parent = parent or UIController.GetActiveScreen()
	return inst
end

return UIController
