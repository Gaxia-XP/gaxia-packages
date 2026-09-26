--!strict
-- ─────────────────────────────────────────────────────────────
-- Toast.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/Toast
-- Purpose : Transient toast notifications with a real FIFO queue. The existing
--           NotificationService stacks template clones and *drops the oldest*
--           when full — a burst of pickups silently eats notifications. Toast
--           instead QUEUES: at most MaxVisible show at once, the rest wait and
--           slide in as slots free, so nothing is lost. Self-rendered from
--           Gaxia.Theme tokens (no template/UIController dependency) with a left
--           accent bar per variant (info/success/warn/error).
--
-- Access  : Gaxia.UI.Toast  (client)
--   Gaxia.UI.Toast.Show({ Title = "Saved", Text = "Progress saved", Variant = "success" })
--   Gaxia.UI.Toast.SetMaxVisible(3)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")

-- Accent colour of a toast (Theme Primary / Success / Warning / Danger).
export type ToastVariant = "info" | "success" | "warn" | "error"
export type ToastOpts = { Text: string, Title: string?, Duration: number?, Variant: (ToastVariant | string)? }
export type ToastStats = { visible: number, queued: number }

local Toast = {}

-- ── Server stub (typed as the client module so Gaxia.UI.Toast autocompletes) ──
if not RunService:IsClient() then
	return ({
		Show = function() end,
		SetMaxVisible = function() end,
		Clear = function() end,
		Stats = function(): any return { visible = 0, queued = 0 } end,
	} :: any) :: typeof(Toast)
end

-- ── Client implementation ──
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Theme = require(script.Parent.Parent.Parent.Shared.Theme)

local TOAST_W : number = 290
local TOAST_H : number = 64
local GAP : number = 8
local TOP : number = 16
local RIGHT_INSET : number = 16
local SLIDE : TweenInfo = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DEFAULT_DURATION : number = 3

local ACCENT: { [string]: string } = {
	info = "Primary", success = "Success", warn = "Warning", error = "Danger",
}

local maxVisible : number = 3
local queue: { ToastOpts } = {}
type Live = { frame: Frame }
local visible: { Live } = {}

local function gui(): Instance
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local sg = pg:FindFirstChild("GaxToasts")
	if not sg then
		local new = Instance.new("ScreenGui")
		new.Name = "GaxToasts"
		new.ResetOnSpawn = false
		new.IgnoreGuiInset = true
		new.DisplayOrder = 2000
		new.Parent = pg
		sg = new
	end
	return sg
end

local function onscreenY(index: number): number
	return TOP + (index - 1) * (TOAST_H + GAP)
end

local function reflow(): ()
	for i, l in ipairs(visible) do
		TweenService:Create(l.frame, SLIDE, {
			Position = UDim2.new(1, -(TOAST_W + RIGHT_INSET), 0, onscreenY(i)),
		}):Play()
	end
end

local pump: () -> () -- forward declaration

local function dismiss(live: Live): ()
	local i = table.find(visible, live)
	if not i then
		return
	end
	table.remove(visible, i)
	local f = live.frame
	local out = TweenService:Create(f, SLIDE, { Position = UDim2.new(1, 20, 0, f.Position.Y.Offset) })
	out:Play()
	out.Completed:Connect(function()
		f:Destroy()
	end)
	reflow()
	pump()
end

local function render(opt: ToastOpts): ()
	local f = Instance.new("Frame")
	f.Name = "Toast"
	f.Size = UDim2.fromOffset(TOAST_W, TOAST_H)
	f.Position = UDim2.new(1, 20, 0, onscreenY(#visible + 1)) -- start offscreen-right
	f.BackgroundColor3 = Theme.Color("Surface")
	local cr = Instance.new("UICorner")
	cr.CornerRadius = UDim.new(0, Theme.Radius("M"))
	cr.Parent = f

	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Size = UDim2.new(0, 4, 1, -8)
	accent.Position = UDim2.fromOffset(0, 4)
	accent.BorderSizePixel = 0
	accent.BackgroundColor3 = Theme.Color(ACCENT[opt.Variant or "info"] or "Primary")
	local acr = Instance.new("UICorner")
	acr.CornerRadius = UDim.new(0, 2)
	acr.Parent = accent
	accent.Parent = f

	local hasTitle = opt.Title ~= nil and opt.Title ~= ""
	if hasTitle then
		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromOffset(16, 8)
		title.Size = UDim2.new(1, -26, 0, 20)
		title.Font = Theme.Get().Font.Bold
		title.TextSize = 16
		title.TextColor3 = Theme.Color("Text")
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Text = opt.Title :: string
		title.Parent = f
	end

	local body = Instance.new("TextLabel")
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(16, if hasTitle then 30 else 8)
	body.Size = UDim2.new(1, -26, 0, if hasTitle then 26 else TOAST_H - 16)
	body.Font = Theme.Get().Font.Regular
	body.TextSize = 14
	body.TextColor3 = Theme.Color("TextMuted")
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Center
	body.TextWrapped = true
	body.Text = opt.Text
	body.Parent = f

	f.Parent = gui()

	local live: Live = { frame = f }
	table.insert(visible, live)
	reflow()
	task.delay(opt.Duration or DEFAULT_DURATION, function()
		dismiss(live)
	end)
end

pump = function(): ()
	while #visible < maxVisible and #queue > 0 do
		local opt = table.remove(queue, 1) :: ToastOpts
		render(opt)
	end
end

-- ── Public API ──

function Toast.Show(opt: ToastOpts): ()
	table.insert(queue, opt)
	pump()
end

function Toast.SetMaxVisible(n: number): ()
	maxVisible = math.max(1, n)
	pump()
end

function Toast.Clear(): ()
	table.clear(queue)
	for _, l in ipairs(table.clone(visible)) do
		dismiss(l)
	end
end

function Toast.Stats(): ToastStats
	return { visible = #visible, queued = #queue }
end

return Toast
