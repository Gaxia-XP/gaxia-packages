--!strict
-- ─────────────────────────────────────────────────────────────
-- Motion3DService.lua  (Gaxia.Motion3D)
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/Motion3DService
-- Purpose : World/object motion — moving platforms, collectible bob, rotating
--           gems, doors, escort waypoints. To() tweens a Part's CFrame (or a
--           Model's pivot via a proxy CFrameValue) with an easing preset; Path()
--           runs a waypoint sequence; Spin/Float are looping idle animations
--           that return a stop() and can run together on one part. Everything is server-driven so it replicates,
--           and the idle loops clean themselves up when the part is removed.
--
-- Access  : Gaxia.Motion3D  (server)
--   Gaxia.Motion3D.To(door, openCFrame, 0.5, Enum.EasingStyle.Back)
--   local stop = Gaxia.Motion3D.Float(coin, 1.5, 2) ; Gaxia.Motion3D.Spin(coin)
-- ─────────────────────────────────────────────────────────────
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Lifecycle = require(script.Parent.ServiceLifecycle)

local Motion3D = {}

local function pivotOf(target: Instance): CFrame
	if target:IsA("Model") then
		return target:GetPivot()
	end
	return (target :: BasePart).CFrame
end

-- ── Tween to a CFrame ──

function Motion3D.To(target: Instance, goal: CFrame, dur: number?, easing: Enum.EasingStyle?): Tween
	local tweenInfo = TweenInfo.new(dur or 0.5, easing or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if target:IsA("Model") then
		local proxy = Instance.new("CFrameValue")
		proxy.Value = target:GetPivot()
		local conn = proxy.Changed:Connect(function(v: CFrame)
			target:PivotTo(v)
		end)
		local t = TweenService:Create(proxy, tweenInfo, { Value = goal })
		t.Completed:Once(function()
			conn:Disconnect()
			proxy:Destroy()
		end)
		t:Play()
		return t
	end
	local t = TweenService:Create(target :: any, tweenInfo, { CFrame = goal })
	t:Play()
	return t
end

-- ── Waypoint path (sequential) ──

function Motion3D.Path(target: Instance, waypoints: { CFrame }, durPerSegment: number?, easing: Enum.EasingStyle?): ()
	local dur = durPerSegment or 0.5
	task.spawn(function()
		for _, wp in ipairs(waypoints) do
			Motion3D.To(target, wp, dur, easing)
			-- Wait the known segment duration rather than Completed:Wait() — a fast
			-- tween can fire Completed before we subscribe, which would deadlock the path.
			task.wait(dur)
		end
	end)
end

-- ── Looping idle: Spin ──
-- Spin and Float each change the part a little every frame (Spin turns it by this
-- frame's angle, Float moves it by the change in its bob height) instead of setting
-- an absolute CFrame, so both can run on the same part. Float assumes it is the only
-- thing moving the part along its up direction: if other code sets the part's
-- CFrame (To, a script) while it floats, the bob's rest height can shift by up to
-- the amplitude, also after stop(). Call stop() first, move the part, then Float again.

-- Turns `part` about its own `axis` (default Y) at degPerSec (default 90) until the
-- returned stop() is called or the part is removed.
function Motion3D.Spin(part: BasePart, axis: Vector3?, degPerSec: number?): () -> ()
	local ax = axis or Vector3.yAxis
	local speed = degPerSec or 90
	local stopped = false
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt: number)
		if stopped or part.Parent == nil then
			conn:Disconnect()
			return
		end
		part.CFrame = part.CFrame * CFrame.fromAxisAngle(ax, math.rad(speed * dt))
	end)
	return function()
		stopped = true
		conn:Disconnect()
	end
end

-- ── Looping idle: Float (bob) ──

-- Bobs `part` up and down by `amplitude` studs (default 1) along its up direction at
-- the start, once every `period` seconds (default 2), until the returned stop() is
-- called (it removes the bob offset, putting the part back at its resting height) or
-- the part is removed. Stop Float before moving the part with other code (To, a script
-- setting CFrame): a move while it floats can shift the rest height by up to `amplitude`.
function Motion3D.Float(part: BasePart, amplitude: number?, period: number?): () -> ()
	local amp = amplitude or 1
	local per = period or 2
	local up = part.CFrame.UpVector
	local elapsed = 0
	local applied = 0 -- offset currently added to the part
	local stopped = false
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt: number)
		if stopped or part.Parent == nil then
			conn:Disconnect()
			return
		end
		elapsed += dt
		local offset = math.sin(elapsed / per * math.pi * 2) * amp
		part.CFrame = part.CFrame + up * (offset - applied)
		applied = offset
	end)
	return function()
		if stopped then
			return
		end
		stopped = true
		conn:Disconnect()
		if part.Parent then
			part.CFrame = part.CFrame - up * applied
		end
		applied = 0
	end
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(Motion3D, {
	Name = "Motion3D",
	Needs = {},
})

return Motion3D
