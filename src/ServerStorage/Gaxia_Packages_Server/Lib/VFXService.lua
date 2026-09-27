--!strict
-- ─────────────────────────────────────────────────────────────
-- VFXService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/VFXService
-- Purpose : Pooled visual-effect registry — the "juice" layer. Register an
--           effect once (a builder that parents ParticleEmitters / Beams /
--           Trails / Highlights onto a holder); PlayAt fires a one-shot at a
--           world point and AutoCleanup returns the holder to a per-effect Pool
--           (Gaxia.Pool) so rapid bursts don't churn Instances. Attach pins a
--           continuous effect to a moving part and hands back a stop(). Effects
--           are spawned server-side so they replicate to everyone.
--
-- Access  : Gaxia.VFX  (server)
--   Gaxia.VFX.Register("Hit", function(p) local e=Instance.new("ParticleEmitter"); e.Parent=p end)
--   Gaxia.VFX.PlayAt("Hit", hrp.Position, { EmitCount = 30 })
-- ─────────────────────────────────────────────────────────────
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pool      = require(ReplicatedStorage.Gaxia_Packages.Shared.Pool)
local Lifecycle = require(script.Parent.ServiceLifecycle)

export type EffectBuilder = (parent: Instance) -> ()
export type PlayOpts = { Duration: number?, EmitCount: number? }

local VFXService = {}

local builders: { [string]: EffectBuilder } = {}
local pools: { [string]: Pool.PoolObject } = {}

local function effectsFolder(): Instance
	local f = Workspace:FindFirstChild("Effects")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Effects"
		f.Parent = Workspace
	end
	return f
end

local function makeHolder(name: string, build: EffectBuilder): Part
	local holder = Instance.new("Part")
	holder.Name = `VFX_{name}`
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	build(holder)
	return holder
end

-- ── Registry ──

function VFXService.Register(name: string, build: EffectBuilder): ()
	builders[name] = build
	pools[name] = Pool.new(function()
		return makeHolder(name, build)
	end, function(holder: Part)
		holder.Parent = nil
	end)
end

function VFXService.PreWarm(name: string, n: number): ()
	local pool = pools[name]
	if pool then
		pool.PreWarm(n)
	end
end

function VFXService.GetPoolSize(name: string): number
	local pool = pools[name]
	return pool and pool.Size() or 0
end

-- ── One-shot ──

-- `where` is a world position (Vector3) or a full CFrame.
function VFXService.PlayAt(name: string, where: Vector3 | CFrame, opts: PlayOpts?): boolean
	local pool = pools[name]
	if not pool then
		warn(`[VFX] no effect '{name}'`)
		return false
	end
	local o: PlayOpts = opts or {}
	local holder: Part = pool.Get()
	holder.CFrame = if typeof(where) == "CFrame" then where else CFrame.new(where)
	holder.Parent = effectsFolder()

	for _, child in ipairs(holder:GetDescendants()) do
		if child:IsA("ParticleEmitter") then
			child.Enabled = true
			child:Emit(o.EmitCount or 20)
		elseif child:IsA("Beam") or child:IsA("Trail") or child:IsA("Highlight") then
			child.Enabled = true
		end
	end

	task.delay(o.Duration or 2, function()
		for _, child in ipairs(holder:GetDescendants()) do
			if child:IsA("ParticleEmitter") or child:IsA("Beam") or child:IsA("Trail") or child:IsA("Highlight") then
				child.Enabled = false
			end
		end
		pool.Return(holder)
	end)
	return true
end

-- ── Continuous attach ──

-- Pins effect `name` onto `host`; returns a stop function.
function VFXService.Attach(name: string, host: BasePart, opts: PlayOpts?): () -> ()
	local build = builders[name]
	if not build then
		warn(`[VFX] no effect '{name}'`)
		return function() end
	end
	local att = Instance.new("Attachment")
	att.Name = `VFX_{name}`
	build(att)
	att.Parent = host
	for _, child in ipairs(att:GetDescendants()) do
		if child:IsA("ParticleEmitter") or child:IsA("Beam") or child:IsA("Trail") then
			child.Enabled = true
		end
	end
	return function()
		att:Destroy()
	end
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(VFXService, {
	Name = "VFX",
	Needs = {},
})

return VFXService
