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
--   Gaxia.UI.Toast.ShowAction({ Text = "Bob invited you", OnAccept = join, OnDecline = skip })
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")

-- Accent colour of a toast (Theme Primary / Success / Warning / Danger).
export type ToastVariant = "info" | "success" | "warn" | "error"
export type ToastOpts = { Text: string, Title: string?, Duration: number?, Variant: (ToastVariant | string)? }
export type ToastStats = { visible: number, queued: number }
-- A toast with Accept / Decline buttons. Exactly one of OnAccept / OnDecline runs (on its own thread,
-- so it may yield): OnDecline also runs when the toast times out (Duration, default 15 s) or is cleared.
export type ToastActionOpts = {
	Text: string,
	Title: string?,
	Variant: (ToastVariant | string)?,
	Duration: number?,
	AcceptText: string?,
	DeclineText: string?,
	OnAccept: (() -> ())?,
	OnDecline: (() -> ())?,
}

local Toast = {}

-- ── Server stub (typed as the client module so Gaxia.UI.Toast autocompletes) ──
if not RunService:IsClient() then
	return ({
		Show = function() end,
		ShowAction = function() end,
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
local ACTION_TOAST_H : number = 104
local BUTTON_W : number = 100
local BUTTON_H : number = 30
local GAP : number = 8
local TOP : number = 16
local RIGHT_INSET : number = 16
local SLIDE : TweenInfo = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DEFAULT_DURATION : number = 3
local DEFAULT_ACTION_DURATION : number = 15

local ACCENT: { [string]: string } = {
	info = "Primary", success = "Success", warn = "Warning", error = "Danger",
}

local maxVisible : number = 3
-- A waiting toast; `action` is set for ShowAction toasts.
type Pending = { opt: ToastOpts, action: ToastActionOpts? }
local queue: { Pending } = {}
-- A toast on screen. `cancel` (action toasts) answers "decline" when it is cleared.
type Live = { frame: Frame, height: number, cancel: (() -> ())? }
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

-- Y of the next toast slot (action toasts are taller, so heights add up).
local function nextY(): number
	local y = TOP
	for _, l in ipairs(visible) do
		y += l.height + GAP
	end
	return y
end

local function reflow(): ()
	local y = TOP
	for _, l in ipairs(visible) do
		TweenService:Create(l.frame, SLIDE, {
			Position = UDim2.new(1, -(TOAST_W + RIGHT_INSET), 0, y),
		}):Play()
		y += l.height + GAP
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

-- One Accept / Decline button of an action toast.
local function actionButton(parent: Frame, name: string, text: string, color: string, x: number, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AutoButtonColor = true
	b.Size = UDim2.fromOffset(BUTTON_W, BUTTON_H)
	b.Position = UDim2.new(0, x, 1, -(BUTTON_H + 8))
	b.BackgroundColor3 = Theme.Color(color)
	b.Font = Theme.Get().Font.Bold
	b.TextSize = 14
	b.TextColor3 = Theme.Color("BackgroundDeep")
	b.Text = text
	local cr = Instance.new("UICorner")
	cr.CornerRadius = UDim.new(0, Theme.Radius("S"))
	cr.Parent = b
	b.Activated:Connect(function()
		onClick()
	end)
	b.Parent = parent
	return b
end

local function render(pending: Pending): ()
	local opt = pending.opt
	local action = pending.action
	local height = if action then ACTION_TOAST_H else TOAST_H
	local f = Instance.new("Frame")
	f.Name = "Toast"
	f.Size = UDim2.fromOffset(TOAST_W, height)
	f.Position = UDim2.new(1, 20, 0, nextY()) -- start offscreen-right
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

	local live: Live = { frame = f, height = height }
	if action then
		-- Exactly one answer per toast: a click, the timeout or Clear (both "decline").
		local answered = false
		local function answer(accepted: boolean): ()
			if answered then
				return
			end
			answered = true
			dismiss(live)
			local callback = if accepted then action.OnAccept else action.OnDecline
			if callback then
				task.spawn(callback) -- its own thread: callbacks may yield (InvokeServer)
			end
		end
		live.cancel = function()
			answer(false)
		end
		actionButton(f, "Accept", action.AcceptText or "Accept", "Success", 16, function()
			answer(true)
		end)
		actionButton(f, "Decline", action.DeclineText or "Decline", "Danger", 16 + BUTTON_W + 8, function()
			answer(false)
		end)
		task.delay(opt.Duration or DEFAULT_ACTION_DURATION, function()
			answer(false)
		end)
	else
		task.delay(opt.Duration or DEFAULT_DURATION, function()
			dismiss(live)
		end)
	end

	f.Parent = gui()
	table.insert(visible, live)
	reflow()
end

pump = function(): ()
	while #visible < maxVisible and #queue > 0 do
		local pending = table.remove(queue, 1) :: Pending
		render(pending)
	end
end

-- ── Public API ──

-- Queues a toast: at most MaxVisible (default 3) show at once, the rest wait their turn.
function Toast.Show(opt: ToastOpts): ()
	table.insert(queue, { opt = opt })
	pump()
end

-- Queues a toast with Accept / Decline buttons (labels: AcceptText / DeclineText). Clicking one runs OnAccept or OnDecline; when the toast times out (Duration, default 15 s) or Toast.Clear removes it, OnDecline runs. Exactly one callback runs, on its own thread (it may yield).
function Toast.ShowAction(opt: ToastActionOpts): ()
	local shown: ToastOpts = { Text = opt.Text, Title = opt.Title, Variant = opt.Variant, Duration = opt.Duration }
	table.insert(queue, { opt = shown, action = opt })
	pump()
end

function Toast.SetMaxVisible(n: number): ()
	maxVisible = math.max(1, n)
	pump()
end

-- Removes every toast, shown and waiting. Action toasts answer "decline" (OnDecline runs).
function Toast.Clear(): ()
	local waiting = table.clone(queue)
	table.clear(queue)
	for _, l in ipairs(table.clone(visible)) do
		if l.cancel then
			l.cancel()
		else
			dismiss(l)
		end
	end
	for _, pending in ipairs(waiting) do
		local action = pending.action
		if action and action.OnDecline then
			task.spawn(action.OnDecline)
		end
	end
end

function Toast.Stats(): ToastStats
	return { visible = #visible, queued = #queue }
end

return Toast
