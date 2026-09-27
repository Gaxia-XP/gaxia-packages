--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   MenuController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/MenuController
-- Purpose:  Open/close modal menus from MenuTemplate.
--           Tracks open menus to prevent duplicates.
-- ─────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local MenuController = {}
-- The module's own type (Open / Close below), so the server stub and the client
-- module share one type and `Gaxia.UI.MenuController.<method>` autocompletes.
export type MenuController = typeof(MenuController)

-- Client-only module. The server gets an EMPTY table (calls error there); only
-- its type is the client module's.
if not RunService:IsClient() then
	return ({} :: any) :: typeof(MenuController)
end

local UIController = require(script.Parent.UIController)
local Constants = require(script.Parent.Parent.Parent.Shared.Constants)

-- ── Constants ──
local ANIM_TIME: number = Constants.UI_ANIMATION_TIME
local TEMPLATE_NAME: UIController.TemplateName = "MenuTemplate"

-- ── State ──
type OpenMenu = {
	frame: Frame,
	closeConn: RBXScriptConnection?,
}
local openMenus: { [string]: OpenMenu } = {}

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

return MenuController
