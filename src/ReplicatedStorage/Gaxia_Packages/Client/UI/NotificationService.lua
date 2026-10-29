--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   NotificationService
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/NotificationService
-- Purpose:  Toast notifications. Clones NotificationTemplate,
--           stacks top-right, auto-dismisses, supports type-colors.
-- ─────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- Stroke colour of a notification (any other string falls back to "info").
export type NotificationType = "info" | "success" | "warn" | "error"

local NotificationService = {}
-- The module's own type (Notify below), so the server stub and the client module
-- share one type and `Gaxia.UI.NotificationService.Notify` autocompletes.
export type NotificationService = typeof(NotificationService)

-- Client-only module. The server gets an EMPTY table (Notify errors there); only
-- its type is the client module's.
if not RunService:IsClient() then
	return ({} :: any) :: typeof(NotificationService)
end

local UIController = require(script.Parent.UIController)
local Constants = require(script.Parent.Parent.Parent.Shared.Constants)

-- ── Constants ──
local DEFAULT_DURATION: number = Constants.NOTIFICATION_DEFAULT_DURATION
local MAX_STACK: number = Constants.NOTIFICATION_MAX_STACK
local ANIM_TIME: number = Constants.UI_ANIMATION_TIME

local TEMPLATE_NAME: UIController.TemplateName = "NotificationTemplate"
local OFFSCREEN_X: UDim = UDim.new(1.2, 0)         -- starts past the right edge
local ONSCREEN_X: UDim = UDim.new(1, -16)           -- 16px inset from right
local SLOT_HEIGHT_PADDING: number = 8                -- vertical gap between toasts

-- ── Type palette (UIStroke color) ──
local TYPE_COLORS: { [string]: Color3 } = {
	info    = Color3.fromRGB(80, 160, 255),
	success = Color3.fromRGB(80, 200, 120),
	warn    = Color3.fromRGB(240, 190, 70),
	error   = Color3.fromRGB(230, 80, 80),
}

-- ── State ──
type Toast = {
	frame: Frame,
	expireAt: number,
	thread: thread?,
}

local activeToasts: { Toast } = {}

-- ── Internal: layout ──
-- WHY: anchor each toast to top-right then offset vertically by index.
local function layoutToasts(): ()
	local y = 16
	for _, toast in ipairs(activeToasts) do
		local frame = toast.frame
		frame.AnchorPoint = Vector2.new(1, 0)
		local height = frame.AbsoluteSize.Y
		if height <= 0 then
			height = frame.Size.Y.Offset
		end
		frame.Position = UDim2.new(ONSCREEN_X.Scale, ONSCREEN_X.Offset, 0, y)
		y += height + SLOT_HEIGHT_PADDING
	end
end

-- ── Internal: dismiss with fade-out ──
local function dismiss(toast: Toast): ()
	if not toast.frame or not toast.frame.Parent then
		return
	end
	-- Remove from list immediately so layout re-flows.
	for i, t in ipairs(activeToasts) do
		if t == toast then
			table.remove(activeToasts, i)
			break
		end
	end

	pcall(function()
		local tween = TweenService:Create(
			toast.frame,
			TweenInfo.new(ANIM_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		tween:Play()
		tween.Completed:Wait()
		toast.frame:Destroy()
	end)

	layoutToasts()
end

-- ── Internal: enforce max stack ──
local function enforceMaxStack(): ()
	while #activeToasts >= MAX_STACK do
		local oldest = activeToasts[1]
		if not oldest then break end
		dismiss(oldest)
	end
end

-- ── Notify ──
function NotificationService.Notify(
	title: string,
	message: string,
	duration: number?,
	notifType: (NotificationType | string)?
): ()
	enforceMaxStack()

	local frame = UIController.CloneTemplate(TEMPLATE_NAME, UIController.GetActiveScreen())
	if not frame or not frame:IsA("Frame") then
		warn("[NotificationService] failed to clone NotificationTemplate")
		return
	end

	-- Populate text fields if they exist (graceful — template shape may vary).
	pcall(function()
		local titleLabel = frame:FindFirstChild("Title")
		if titleLabel and titleLabel:IsA("TextLabel") then
			titleLabel.Text = title
		end
		local messageLabel = frame:FindFirstChild("Message")
		if messageLabel and messageLabel:IsA("TextLabel") then
			messageLabel.Text = message
		end
	end)

	-- Apply type color to UIStroke if present.
	local color = TYPE_COLORS[notifType or "info"] or TYPE_COLORS.info
	pcall(function()
		local stroke = frame:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = color
		end
	end)

	-- Slide-in from offscreen right.
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = UDim2.new(OFFSCREEN_X.Scale, OFFSCREEN_X.Offset, 0, 16)

	local toast: Toast = {
		frame = frame,
		expireAt = os.clock() + (duration or DEFAULT_DURATION),
		thread = nil,
	}
	table.insert(activeToasts, toast)
	layoutToasts()

	pcall(function()
		local slide = TweenService:Create(
			frame,
			TweenInfo.new(ANIM_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.new(ONSCREEN_X.Scale, ONSCREEN_X.Offset, 0, frame.Position.Y.Offset) }
		)
		slide:Play()
	end)

	-- Auto-dismiss timer.
	toast.thread = task.delay(duration or DEFAULT_DURATION, function()
		dismiss(toast)
	end)
end

return NotificationService
