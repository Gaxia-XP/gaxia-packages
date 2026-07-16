--!strict
-- ─────────────────────────────────────────────────────────────
-- Motion3DService.lua  (Gaxia.Motion3D)
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/Motion3DService
-- Purpose : World/object motion — moving platforms, collectible bob, rotating
--           gems, doors, escort waypoints. To() tweens a Part's CFrame (or a
--           Model's pivot via a proxy CFrameValue) with an easing preset; Path()
--           runs a waypoint sequence; Spin/Float are looping idle animations
--           that return a stop(). Everything is server-driven so it replicates,
--           and the idle loops clean themselves up when the part is removed.
--
-- Access  : Gaxia.Motion3D  (server)
--   Gaxia.Motion3D.To(door, openCFrame, 0.5, Enum.EasingStyle.Back)
--   local stop = Gaxia.Motion3D.Float(coin, 1.5, 2) ; Gaxia.Motion3D.Spin(coin)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

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

function Motion3D.Float(part: BasePart, amplitude: number?, period: number?): () -> ()
	local amp = amplitude or 1
	local per = period or 2
	local origin = part.CFrame
	local elapsed = 0
	local stopped = false
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt: number)
		if stopped or part.Parent == nil then
			conn:Disconnect()
			return
		end
		elapsed += dt
		local offset = math.sin(elapsed / per * math.pi * 2) * amp
		part.CFrame = origin * CFrame.new(0, offset, 0)
	end)
	return function()
		stopped = true
		conn:Disconnect()
		if part.Parent then
			part.CFrame = origin
		end
	end
end

return Motion3D
