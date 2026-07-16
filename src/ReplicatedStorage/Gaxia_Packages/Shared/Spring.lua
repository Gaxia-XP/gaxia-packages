--!strict
--[[
	Spring.lua
	Location: ReplicatedStorage/Gaxia_Packages/Shared/Spring
	Purpose: Critically-damped (or under-damped) analytic spring solver for
	         number, Vector2, and Vector3 values. Frame-rate independent
	         because we evaluate the closed-form solution rather than stepping.

	Equations of motion for damped harmonic oscillator (mass = 1):
		x'' + 2 * d * w * x' + w^2 * x = w^2 * target
	where w = Speed (angular frequency) and d = Damper (damping ratio).
	Solved analytically per-axis below.
--]]

-- ── Types ──
export type SpringValue = number | Vector2 | Vector3

export type Spring = {
	Position: SpringValue,
	Velocity: SpringValue,
	Target:   SpringValue,
	Damper:   number,
	Speed:    number,
	Update:  (self: Spring, dt: number) -> SpringValue,
	Impulse: (self: Spring, velocity: SpringValue) -> (),
}

local Spring = {}
Spring.__index = Spring

-- ── Internal: zero value matching the type of `v` ──

local function zeroLike(v: SpringValue): SpringValue
	local t = typeof(v)
	if t == "Vector3" then
		return Vector3.zero
	elseif t == "Vector2" then
		return Vector2.zero
	end
	return 0
end

-- ── Construction ──

function Spring.new(initial: SpringValue): Spring
	local self = setmetatable({
		Position = initial,
		Velocity = zeroLike(initial),
		Target   = initial,
		Damper   = 1,    -- critically damped by default
		Speed    = 10,
	}, Spring)
	return (self :: any) :: Spring
end

-- ── Analytic step ──

-- Closed-form solution for one timestep dt. Operates element-wise on Vectors.
-- WHY analytic (not Euler integration): stable across any dt and exact for
-- linear springs — no numerical drift even with huge frame hitches.
function Spring:Update(dt: number): SpringValue
	local d   = self.Damper
	local w   = self.Speed
	local pos = self.Position
	local vel = self.Velocity
	local tgt = self.Target

	-- Work in the target's frame (offset = position - target).
	local offset: any = (pos :: any) - (tgt :: any)
	local v: any      = vel

	-- Critically damped (d == 1): special case to avoid division by zero in the
	-- generic formula. Solution: x(t) = (A + B*t) * exp(-w*t)
	if d == 1 then
		local decay   = math.exp(-w * dt)
		local newOff: any = (offset + v * dt) * decay - (offset * w * dt) * decay
		-- Derivative: v(t) = (-w*A + B - w*B*t) * exp(-w*t)
		local newVel: any = (v - (offset * w + v * w) * dt) * decay
		self.Position = (newOff + (tgt :: any)) :: SpringValue
		self.Velocity = newVel :: SpringValue
		return self.Position
	end

	-- Under-damped (d < 1): oscillating decay.
	if d < 1 then
		local wd     = w * math.sqrt(1 - d * d) -- damped angular frequency
		local decay  = math.exp(-d * w * dt)
		local cos    = math.cos(wd * dt)
		local sin    = math.sin(wd * dt)
		-- x(t) = e^{-dwt} * (A cos(wd t) + B sin(wd t)), where A = offset, B = (v + d*w*offset)/wd
		local A: any = offset
		local B: any = (v + offset * (d * w)) * (1 / wd)
		local newOff: any = decay * (A * cos + B * sin)
		local newVel: any = decay * ((B * wd - A * (d * w)) * cos - (A * wd + B * (d * w)) * sin)
		self.Position = (newOff + (tgt :: any)) :: SpringValue
		self.Velocity = newVel :: SpringValue
		return self.Position
	end

	-- Over-damped (d > 1): two real exponential decays.
	local r        = math.sqrt(d * d - 1)
	local r1       = -w * (d - r) -- slow decay rate
	local r2       = -w * (d + r) -- fast decay rate
	-- x(t) = c1 * e^{r1 t} + c2 * e^{r2 t}
	-- c1 = (v - offset*r2) / (r1 - r2), c2 = offset - c1
	local invDen   = 1 / (r1 - r2)
	local c1: any  = (v - offset * r2) * invDen
	local c2: any  = offset - c1
	local e1       = math.exp(r1 * dt)
	local e2       = math.exp(r2 * dt)
	local newOff: any = c1 * e1 + c2 * e2
	local newVel: any = c1 * (r1 * e1) + c2 * (r2 * e2)
	self.Position = (newOff + (tgt :: any)) :: SpringValue
	self.Velocity = newVel :: SpringValue
	return self.Position
end

-- ── Impulse ──

-- Additive velocity kick — useful for "punch" effects without re-targeting.
function Spring:Impulse(velocity: SpringValue): ()
	self.Velocity = ((self.Velocity :: any) + (velocity :: any)) :: SpringValue
end

return Spring
