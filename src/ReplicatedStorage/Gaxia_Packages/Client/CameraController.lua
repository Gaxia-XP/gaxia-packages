--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   CameraController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/CameraController
-- Purpose:  Camera effects helper — perlin-based screen shake and
--           tweened FOV. Owns ONE RenderStepped connection that
--           applies a per-frame offset additively to the live
--           camera CFrame, so it composes with default Roblox
--           camera controllers (Classic, OrbitalCamera, etc.)
--           instead of fighting them.
-- ─────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")

-- ── Types ──

export type CameraControllerType = {
	Shake          : (intensity: number, duration: number) -> (),
	SetFOV         : (fov: number, duration: number?) -> (),
	ResetFOV       : (duration: number?) -> (),
	GetCamera      : () -> Camera,
	OnShakeStarted : any, -- Signal — fires (intensity, duration)
	OnShakeEnded   : any, -- Signal — fires ()
}

-- Client-only: shake/FOV are meaningless on the server. Return a typed empty
-- shell so server-side typeof(require(...)) still resolves.
if not RunService:IsClient() then
	return ({} :: any) :: CameraControllerType
end

-- ── Shared deps ──
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal    = SharedPkg.Signal

-- ── Constants ──
local DEFAULT_FOV       : number = 70    -- matches Roblox Camera default
local DEFAULT_FOV_TIME  : number = 0.3   -- seconds; snappy but not jarring
local SHAKE_FREQUENCY   : number = 18    -- perlin sample rate; higher = jitter, lower = sway
local SHAKE_SEED_X      : number = 1009  -- decoupled prime seeds keep X/Y orthogonal
local SHAKE_SEED_Y      : number = 2087  -- (avoids "diagonal-only" shake artifacts)

-- ── State ──
-- Shake is a single global event — stacking shakes would feel chaotic, so a
-- new Shake() supersedes any in-flight shake instead of compositing.
local shakeIntensity : number = 0
local shakeRemaining : number = 0
local shakeStartedAt : number = 0
local shakeDuration  : number = 0
local activeShakeFOVTween: Tween? = nil

local OnShakeStarted = Signal.new()
local OnShakeEnded   = Signal.new()

local CameraController = {}
-- Attach Signal fields via `any` cast — same pattern UI controllers use.
local self = CameraController :: any
self.OnShakeStarted = OnShakeStarted
self.OnShakeEnded   = OnShakeEnded

-- ── Internal helpers ──

-- Resolve workspace.CurrentCamera lazily. Camera can re-spawn on respawn /
-- workspace reset, so we don't cache the reference between calls.
local function getCamera(): Camera
	return Workspace.CurrentCamera :: Camera
end

-- ── GetCamera ──
function CameraController.GetCamera(): Camera
	return getCamera()
end

-- ── Shake ──
-- intensity is in studs (XY rotational offset); duration in seconds. Shake
-- decays LINEARLY toward zero — most action games use linear or quadratic
-- falloff, linear gives the cleanest "punch then settle" feel.
function CameraController.Shake(intensity: number, duration: number): ()
	if intensity <= 0 or duration <= 0 then return end
	-- If already shaking, swap parameters but keep the per-frame loop running.
	-- The OnShakeEnded fires once when the *current* shake ends, so consumers
	-- get one signal per logical end-of-shake.
	shakeIntensity = intensity
	shakeRemaining = duration
	shakeDuration  = duration
	shakeStartedAt = os.clock()
	OnShakeStarted:Fire(intensity, duration)
end

-- ── SetFOV ──
-- Tween-based FOV change. Cancels any prior in-flight tween so a fast pair of
-- calls (e.g. ADS in → ADS out) doesn't blend at half-way and look mushy.
function CameraController.SetFOV(fov: number, duration: number?): ()
	local cam = getCamera()
	if activeShakeFOVTween then
		activeShakeFOVTween:Cancel()
		activeShakeFOVTween = nil
	end
	local t = TweenService:Create(
		cam,
		TweenInfo.new(duration or DEFAULT_FOV_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FieldOfView = fov }
	)
	activeShakeFOVTween = t
	t:Play()
end

-- ── ResetFOV ──
-- Convenience wrapper; same tween path so it cancels in-flight changes cleanly.
function CameraController.ResetFOV(duration: number?): ()
	CameraController.SetFOV(DEFAULT_FOV, duration)
end

-- ── Per-frame offset ──
-- We multiply the camera's existing CFrame by a tiny rotation offset every
-- RenderStepped. This is non-destructive — when shakeRemaining hits 0 we stop
-- multiplying and the camera returns to whatever the default controller put
-- it at. We use math.noise (perlin) instead of math.random so successive
-- frames are SMOOTHLY varying (random would alias as flicker at 60Hz).
RunService.RenderStepped:Connect(function(dt: number): ()
	if shakeRemaining <= 0 then
		return
	end
	shakeRemaining -= dt
	if shakeRemaining <= 0 then
		shakeRemaining = 0
		shakeIntensity = 0
		OnShakeEnded:Fire()
		return
	end

	-- Linear decay from full intensity at start to 0 at end.
	local decay  : number = shakeRemaining / shakeDuration
	local amp    : number = shakeIntensity * decay
	local now    : number = os.clock()
	-- math.noise returns [-1, 1] roughly — multiply by amp to get the offset.
	local offX   : number = math.noise(SHAKE_SEED_X, now * SHAKE_FREQUENCY) * amp
	local offY   : number = math.noise(SHAKE_SEED_Y, now * SHAKE_FREQUENCY) * amp

	local cam = getCamera()
	-- Apply as a small rotation about local X/Y. Multiplying CFrames composes,
	-- so this rides on top of whatever the player / scripted camera did this
	-- frame — never replacing it.
	cam.CFrame = cam.CFrame * CFrame.Angles(math.rad(offY), math.rad(offX), 0)
end)

return CameraController :: CameraControllerType
