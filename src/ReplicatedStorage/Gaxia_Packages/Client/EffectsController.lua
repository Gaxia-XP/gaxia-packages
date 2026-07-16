--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   EffectsController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/EffectsController
-- Purpose:  Spawn-pool for ParticleEmitter / Beam / Trail bursts.
--           Game code typically wants to "play a hit-flash at this
--           CFrame" without thinking about cleanup. This module
--           owns a Maid of every spawned effect so a single
--           ClearAll() (e.g. on respawn / scene transition) can
--           wipe in-flight effects without leaking instances.
-- ─────────────────────────────────────────────────────────────

local Debris            = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

-- ── Types ──

export type EffectType = "Particle" | "Beam" | "Trail"

export type EffectsControllerType = {
	EmitParticle : (template: ParticleEmitter, atCFrame: CFrame, count: number?) -> (),
	SpawnBeam    : (template: Beam, fromAttachment: Attachment, toAttachment: Attachment, lifetime: number?) -> Beam,
	SpawnTrail   : (template: Trail, parent: BasePart, lifetime: number?) -> Trail,
	ClearAll     : () -> (),
}

-- Client-only: visual effects don't replicate from a server require, and the
-- pool itself lives in the client's workspace tree.
if not RunService:IsClient() then
	return ({} :: any) :: EffectsControllerType
end

-- ── Shared deps ──
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Maid      = SharedPkg.Maid

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

-- One Maid tracks every effect we spawn — ClearAll() just calls DoCleaning on
-- it. We swap the Maid on ClearAll (rather than reusing) so any tasks added
-- mid-cleanup don't get silently discarded.
local fxMaid : any = Maid.new()

local EffectsController = {}

-- ── Helpers ──

-- Schedule destruction via Debris so it survives if our Maid is cleared.
-- Returns nothing — the Maid + Debris together cover cleanup paths.
local function scheduleDestroy(inst: Instance, lifetime: number): ()
	Debris:AddItem(inst, lifetime)
	fxMaid:GiveTask(inst)
end

-- ── EmitParticle ──
-- Clones the emitter template to a tiny anchored Part at the target CFrame,
-- calls :Emit(count), then schedules destruction once the longest-lived
-- particle has had time to die. Anchored = no physics jitter; CanCollide off
-- so it doesn't push players. Size near-zero so the Part itself is invisible.
function EffectsController.EmitParticle(template: ParticleEmitter, atCFrame: CFrame, count: number?): ()
	local n = count or DEFAULT_EMIT_COUNT

	local host = Instance.new("Part")
	host.Name         = `FX_Particle_{template.Name}`
	host.Size         = Vector3.new(0.05, 0.05, 0.05)
	host.Transparency = 1
	host.Anchored     = true
	host.CanCollide   = false
	host.CanQuery     = false
	host.CanTouch     = false
	host.CFrame       = atCFrame
	host.Parent       = hostFolder

	local emitter = template:Clone() :: ParticleEmitter
	emitter.Parent = host
	emitter:Emit(n)

	-- Particle lifetime range is on the emitter — we use the MAX so even the
	-- longest-lived particle has expired by destruction time. Fall back to a
	-- safe default if the emitter has no Lifetime NumberRange (e.g. odd
	-- template config).
	local maxLife : number = DEFAULT_PARTICLE_LIFETIME
	local ok, val = pcall(function()
		return emitter.Lifetime.Max
	end)
	if ok and typeof(val) == "number" then
		maxLife = math.max(val, 0.1)
	end

	scheduleDestroy(host, maxLife + 0.1)
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
-- Wipe every effect we've spawned. We swap the Maid before calling
-- DoCleaning so new spawns triggered from within cleanup callbacks attach to
-- the FRESH maid and don't get mid-iteration mutated.
function EffectsController.ClearAll(): ()
	local old = fxMaid
	fxMaid = Maid.new()
	old:DoCleaning()
end

return EffectsController :: EffectsControllerType
