--!strict
-- ─────────────────────────────────────────────────────────────
-- Motion.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/Motion
-- Purpose : UI motion presets — the polish layer over raw TweenService. Every
--           menu re-hand-rolls fade/slide/pop/shake with copy-pasted TweenInfo
--           and forgotten cleanup. Motion gives named enter/exit transitions
--           (FadeIn/SlideIn/Pop), a Shake, a Sequence runner (timeline of
--           tweens + delays), and Stagger (apply a preset down a list with an
--           incremental delay) so lists cascade in. Each preset returns its Tween
--           so callers can await/chain. Pairs with the 22.x component library.
--
-- Access  : Gaxia.UI.Motion  (client)
--   Gaxia.UI.Motion.FadeIn(panel)
--   Gaxia.UI.Motion.Stagger(rows, function(r) return Gaxia.UI.Motion.SlideIn(r, "Left") end, 0.05)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local DEFAULT_DUR : number = 0.25

local Motion = {}

local function info(dur: number?, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): TweenInfo
	return TweenInfo.new(dur or DEFAULT_DUR, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out)
end

local function getScale(gui: GuiObject): UIScale
	local s = gui:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Parent = gui
	end
	return s
end

-- ── Fades ──

function Motion.FadeIn(gui: GuiObject, dur: number?): Tween
	gui.BackgroundTransparency = 1
	gui.Visible = true
	local goal: { [string]: any } = { BackgroundTransparency = 0 }
	if gui:IsA("TextLabel") or gui:IsA("TextButton") or gui:IsA("TextBox") then
		gui.TextTransparency = 1
		goal.TextTransparency = 0
	end
	local t = TweenService:Create(gui, info(dur), goal)
	t:Play()
	return t
end

function Motion.FadeOut(gui: GuiObject, dur: number?): Tween
	local goal: { [string]: any } = { BackgroundTransparency = 1 }
	if gui:IsA("TextLabel") or gui:IsA("TextButton") or gui:IsA("TextBox") then
		goal.TextTransparency = 1
	end
	local t = TweenService:Create(gui, info(dur), goal)
	t.Completed:Once(function()
		gui.Visible = false
	end)
	t:Play()
	return t
end

-- ── Slide ──

local OFFSCREEN: { [string]: UDim2 } = {
	Left = UDim2.fromScale(-1.5, 0),
	Right = UDim2.fromScale(1.5, 0),
	Up = UDim2.fromScale(0, -1.5),
	Down = UDim2.fromScale(0, 1.5),
}

function Motion.SlideIn(gui: GuiObject, direction: string?, dur: number?): Tween
	local target = gui.Position
	local off = OFFSCREEN[direction or "Left"] or OFFSCREEN.Left
	gui.Position = target + off
	gui.Visible = true
	local t = TweenService:Create(gui, info(dur, Enum.EasingStyle.Quint), { Position = target })
	t:Play()
	return t
end

-- ── Pop (scale-in with overshoot) ──

function Motion.Pop(gui: GuiObject, dur: number?): Tween
	local scale = getScale(gui)
	scale.Scale = 0
	gui.Visible = true
	local t = TweenService:Create(scale, info(dur or 0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
	t:Play()
	return t
end

-- ── Shake ──

function Motion.Shake(gui: GuiObject, intensity: number?, dur: number?): Tween
	local origin = gui.Position
	local amt = intensity or 8
	local t = TweenService:Create(
		gui,
		TweenInfo.new((dur or 0.3) / 6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 5, true),
		{ Position = origin + UDim2.fromOffset(amt, 0) }
	)
	t.Completed:Once(function()
		gui.Position = origin
	end)
	t:Play()
	return t
end

-- ── Sequence (timeline of tweens + delays) ──
-- steps: each is a function returning a Tween (awaited) | a number (delay) | nil.
function Motion.Sequence(steps: { () -> any }, onComplete: (() -> ())?): ()
	task.spawn(function()
		for _, step in ipairs(steps) do
			local result = step()
			if typeof(result) == "number" then
				task.wait(result)
			elseif typeof(result) == "Instance" and result:IsA("Tween") then
				result.Completed:Wait()
			end
		end
		if onComplete then
			onComplete()
		end
	end)
end

-- ── Stagger (cascade a preset down a list) ──
function Motion.Stagger(guis: { GuiObject }, presetFn: (gui: GuiObject) -> any, gap: number?): ()
	local g = gap or 0.05
	for i, gui in ipairs(guis) do
		task.delay((i - 1) * g, function()
			presetFn(gui)
		end)
	end
end

return Motion
