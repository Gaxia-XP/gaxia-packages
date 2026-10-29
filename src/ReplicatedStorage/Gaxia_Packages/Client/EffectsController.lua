--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   EffectsController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/EffectsController
-- Purpose:  Spawn-pool for ParticleEmitter / Beam / Trail bursts
--           (EmitParticle: one emitter; EmitBurst: every emitter of a template).
--           Game code typically wants to "play a hit-flash at this
--           CFrame" without thinking about cleanup. This module
--           owns a Trove of every spawned effect so a single
--           ClearAll() (e.g. on respawn / scene transition) can
--           wipe in-flight effects without leaking instances.
-- ─────────────────────────────────────────────────────────────

local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

-- ── Dependencies ──
local Trove = require(script.Parent.Parent.Shared.Trove)

-- ── Types ──

export type EffectType = "Particle" | "Beam" | "Trail"

export type EffectsControllerType = {
	EmitParticle : (template: ParticleEmitter, atCFrame: CFrame, count: number?) -> (),
	EmitBurst    : (template: Instance, atCFrame: CFrame, count: number?) -> number,
	SpawnBeam    : (template: Beam, fromAttachment: Attachment, toAttachment: Attachment, lifetime: number?) -> Beam,
	SpawnTrail   : (template: Trail, parent: BasePart, lifetime: number?) -> Trail,
	ClearAll     : () -> (),
}

-- Client-only: visual effects don't replicate from a server require, and the
-- pool itself lives in the client's workspace tree.
if not RunService:IsClient() then
	return ({} :: any) :: EffectsControllerType
end

-- ── Constants ──
local FX_FOLDER_NAME      : string = "Gaxia_EffectsHost"  -- workspace folder for emitter parts
local DEFAULT_PARTICLE_LIFETIME : number = 2  -- seconds; long enough for most short emit bursts
local DEFAULT_BEAM_LIFETIME     : number = 1
local DEFAULT_TRAIL_LIFETIME    : number = 1
local DEFAULT_EMIT_COUNT        : number = 10

-- ── State ──

-- Host folder for anchored emitter parts. Lives under workspace so Roblox
-- actually renders the particles (parented elsewhere = invisible).
local function ensureHost(): Folder
	local existing = Workspace:FindFirstChild(FX_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = FX_FOLDER_NAME
	f.Parent = Workspace
	return f
end

local hostFolder : Folder = ensureHost()

-- One Trove tracks every effect we spawn — ClearAll() just calls Clean on it.
-- We swap the Trove on ClearAll (rather than reusing) because Trove errors on
-- Add() while it is cleaning.
local fxTrove = Trove.new()

local EffectsController = {}

-- ── Helpers ──

-- Track `inst` in the current Trove and destroy it after `lifetime` seconds. When
-- it expires it is also removed from the Trove, so the Trove only holds live
-- effects (it used to keep every effect ever spawned until ClearAll). If ClearAll
-- swapped the Trove meanwhile, the old Trove already destroyed it.
local function scheduleDestroy(inst: Instance, lifetime: number): ()
	local trove = fxTrove
	trove:Add(inst)
	task.delay(lifetime, function()
		if trove == fxTrove then
			trove:Remove(inst) -- destroys it and forgets it
		else
			inst:Destroy()
		end
	end)
end

-- An invisible anchored Part at `atCFrame` that hosts emitters.
local function makeHost(name: string, atCFrame: CFrame): Part
	local host = Instance.new("Part")
	host.Name         = name
	host.Size         = Vector3.new(0.05, 0.05, 0.05)
	host.Transparency = 1
	host.Anchored     = true
	host.CanCollide   = false
	host.CanQuery     = false
	host.CanTouch     = false
	host.CFrame       = atCFrame
	host.Parent       = hostFolder
	return host
end

-- Longest particle lifetime of `emitter` (DEFAULT_PARTICLE_LIFETIME when unreadable).
local function maxLifetime(emitter: ParticleEmitter): number
	local ok, val = pcall(function()
		return emitter.Lifetime.Max
	end)
	if ok and typeof(val) == "number" then
		return math.max(val, 0.1)
	end
	return DEFAULT_PARTICLE_LIFETIME
end

-- ── EmitParticle ──
-- One burst: clones the emitter template to a tiny anchored Part at the target
-- CFrame, turns the clone's Enabled off (so a template left Enabled in Studio
-- does not keep emitting until cleanup), calls :Emit(count) (default 10), then
-- schedules destruction once the longest-lived particle has had time to die.
-- Anchored = no physics jitter; CanCollide off so it doesn't push players.
function EffectsController.EmitParticle(template: ParticleEmitter, atCFrame: CFrame, count: number?): ()
	local n = count or DEFAULT_EMIT_COUNT
	local host = makeHost(`FX_Particle_{template.Name}`, atCFrame)

	local emitter = template:Clone() :: ParticleEmitter
	emitter.Enabled = false
	emitter.Parent = host
	emitter:Emit(n)

	scheduleDestroy(host, maxLifetime(emitter) + 0.1)
end

-- ── EmitBurst ──
-- A burst of a whole effect: `template` is a ParticleEmitter, or any Instance
-- (Attachment, Part, Model, Folder) holding several emitters (sparks + smoke +
-- flash). Every ParticleEmitter in the clone is turned off and emits once: its
-- "EmitCount" attribute when it has one, else `count` (default 10); an
-- "EmitDelay" attribute (seconds) delays that emitter. Returns the number of
-- emitters that fired. Cleaned up once the slowest particle has died.
function EffectsController.EmitBurst(template: Instance, atCFrame: CFrame, count: number?): number
	if template:IsA("ParticleEmitter") then
		EffectsController.EmitParticle(template, atCFrame, count)
		return 1
	end
	local n = count or DEFAULT_EMIT_COUNT
	local host = makeHost(`FX_Burst_{template.Name}`, atCFrame)
	local clone = template:Clone()
	if clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.Transparency = 1
		clone.CFrame = atCFrame
	elseif clone:IsA("Model") then
		clone:PivotTo(atCFrame)
	end
	clone.Parent = host

	local life = 0.1
	local fired = 0
	for _, d in clone:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = false
			local amount = tonumber(d:GetAttribute("EmitCount")) or n
			local delay = tonumber(d:GetAttribute("EmitDelay")) or 0
			if delay > 0 then
				task.delay(delay, function()
					if d.Parent ~= nil then
						d:Emit(amount)
					end
				end)
			else
				d:Emit(amount)
			end
			fired += 1
			life = math.max(life, delay + maxLifetime(d))
		end
	end
	scheduleDestroy(host, life + 0.1)
	return fired
end

-- ── SpawnBeam ──
-- Clone a beam template between two attachments. We re-parent the clone to
-- the FROM attachment's parent so the Beam shows under a sensible owner; the
-- Attachment0/1 properties point at the user-supplied endpoints. Returns the
-- live Beam so callers can tween or mutate it before it auto-destroys.
function EffectsController.SpawnBeam(
	template       : Beam,
	fromAttachment : Attachment,
	toAttachment   : Attachment,
	lifetime       : number?
): Beam
	local life = lifetime or DEFAULT_BEAM_LIFETIME
	local beam = template:Clone() :: Beam
	beam.Attachment0 = fromAttachment
	beam.Attachment1 = toAttachment
	beam.Enabled     = true
	-- Beams render off any Instance; we host under the from-attachment so the
	-- beam follows that part naturally.
	beam.Parent      = fromAttachment.Parent or hostFolder
	scheduleDestroy(beam, life)
	return beam
end

-- ── SpawnTrail ──
-- Trails need two attachments on a part to render. We assume the template
-- already has them as children (typical authoring); we just parent the clone
-- to the requested host part. If the template has no attachments the trail
-- silently won't render — that's a template config issue, not our problem.
function EffectsController.SpawnTrail(
	template : Trail,
	parent   : BasePart,
	lifetime : number?
): Trail
	local life = lifetime or DEFAULT_TRAIL_LIFETIME
	local trail = template:Clone() :: Trail
	trail.Enabled = true
	trail.Parent  = parent
	scheduleDestroy(trail, life)
	return trail
end

-- ── ClearAll ──
-- Wipe every effect we've spawned. We swap the Trove before calling Clean so
-- new spawns triggered from within cleanup callbacks attach to the FRESH
-- trove instead of erroring on the one being cleaned.
function EffectsController.ClearAll(): ()
	local old = fxTrove
	fxTrove = Trove.new()
	old:Clean()
end

return EffectsController :: EffectsControllerType
