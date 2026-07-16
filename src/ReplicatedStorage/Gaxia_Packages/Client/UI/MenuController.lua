--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   MenuController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/MenuController
-- Purpose:  Open/close modal menus from MenuTemplate.
--           Tracks open menus to prevent duplicates.
-- ─────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- WHY this explicit type:
-- The early-return guard below needs to match the module's real return shape
-- so Luau collapses the (server-return | client-return) union into a single
-- typed value. Without this, `Gaxia.UI.MenuController.<method>` does not
-- autocomplete because the union resolves to `any`.
export type MenuController = {
	Open: (menuName: string, builder: ((content: ScrollingFrame) -> ())?) -> Frame?,
	Close: (menuName: string) -> (),
}

-- Client-only module.
if not RunService:IsClient() then
	return ({} :: any) :: MenuController
end

local UIController = require(script.Parent:WaitForChild("UIController"))

-- ── Constants ──
local function getConstants(): { [string]: any }
	local pkg = ReplicatedStorage:FindFirstChild("Gaxia_Packages")
	if not pkg then return {} end
	local shared = pkg:FindFirstChild("Shared")
	if not shared then return {} end
	local constMod = shared:FindFirstChild("Constants")
	if not constMod or not constMod:IsA("ModuleScript") then return {} end
	local ok, data = pcall(require, constMod)
	if ok and typeof(data) == "table" then
		return data
	end
	return {}
end

local CONST = getConstants()
local ANIM_TIME: number = (CONST.UI_ANIMATION_TIME :: number?) or 0.25
local TEMPLATE_NAME: string = "MenuTemplate"

-- ── State ──
type OpenMenu = {
	frame: Frame,
	closeConn: RBXScriptConnection?,
}
local openMenus: { [string]: OpenMenu } = {}

local MenuController = {}

-- Forward declaration so Open() can reference Close().
local Close: (menuName: string) -> ()

-- ── Open ──
function MenuController.Open(
	menuName: string,
	builder: ((content: ScrollingFrame) -> ())?
): Frame?
	-- WHY: prevent duplicates — re-open is a no-op returning existing frame.
	if openMenus[menuName] then
		return openMenus[menuName].frame
	end

	local overlays = UIController.Overlays() or UIController.GetActiveScreen()
	local frame = UIController.CloneTemplate(TEMPLATE_NAME, overlays)
	if not frame or not frame:IsA("Frame") then
		warn(`[MenuController] failed to clone MenuTemplate for '{menuName}'`)
		return nil
	end

	frame.Name = menuName

	-- Title
	pcall(function()
		local title = frame:FindFirstChild("Title")
		if title and title:IsA("TextLabel") then
			title.Text = menuName
		end
	end)

	-- Wire close button if present.
	local closeConn: RBXScriptConnection? = nil
	pcall(function()
		local closeBtn = frame:FindFirstChild("CloseButton", true)
		if closeBtn and closeBtn:IsA("GuiButton") then
			closeConn = closeBtn.Activated:Connect(function()
				Close(menuName)
			end)
		end
	end)

	-- Call builder with the Content ScrollingFrame if it exists.
	if builder then
		pcall(function()
			local content = frame:FindFirstChild("Content")
			if content and content:IsA("ScrollingFrame") then
				builder(content)
			end
		end)
	end

	-- Fade-in tween.
	pcall(function()
		frame.BackgroundTransparency = 1
		local tween = TweenService:Create(
			frame,
			TweenInfo.new(ANIM_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 0 }
		)
		tween:Play()
	end)

	openMenus[menuName] = {
		frame = frame,
		closeConn = closeConn,
	}
	return frame
end

-- ── Close ──
Close = function(menuName: string): ()
	local entry = openMenus[menuName]
	if not entry then
		return
	end
	openMenus[menuName] = nil

	if entry.closeConn then
		entry.closeConn:Disconnect()
	end

	local frame = entry.frame
	if not frame or not frame.Parent then
		return
	end

	pcall(function()
		local tween = TweenService:Create(
			frame,
			TweenInfo.new(ANIM_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		tween:Play()
		tween.Completed:Wait()
		frame:Destroy()
	end)
end

MenuController.Close = Close

return MenuController :: MenuController
