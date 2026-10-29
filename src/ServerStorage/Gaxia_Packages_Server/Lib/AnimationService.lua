--!strict
-- ─────────────────────────────────────────────────────────────
-- AnimationService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/AnimationService
-- Purpose : Named animation playback over Animator. Register clips once; Play
--           loads (and caches) the track on a model's Humanoid/AnimationController
--           Animator and starts it with priority + fade/weight/speed, so combat
--           and emotes blend correctly instead of fighting. Tracks are cached
--           per (model,name) to avoid re-loading; OnMarker wires keyframe event
--           signals (hit frames, footsteps). Played server-side so it replicates.
--
-- Access  : Gaxia.Anim  (server)
--   Gaxia.Anim.Register("Swing", "rbxassetid://123")
--   local track = Gaxia.Anim.Play(npc, "Swing", { Priority = Enum.AnimationPriority.Action, Speed = 1.4 })
--   Gaxia.Anim.OnMarker(track, "Hit", function() applyDamage() end)
-- ─────────────────────────────────────────────────────────────
local Lifecycle = require(script.Parent.ServiceLifecycle)

export type PlayOpts = {
	Priority: Enum.AnimationPriority?,
	FadeTime: number?,
	Weight: number?,
	Speed: number?,
	Looped: boolean?,
}

local AnimationService = {}

local registry: { [string]: string } = {}
local trackCache: { [Instance]: { [string]: AnimationTrack } } = {}

-- ── Registry ──

function AnimationService.Register(name: string, animationId: string): ()
	registry[name] = animationId
end

function AnimationService.RegisterMany(map: { [string]: string }): ()
	for name, id in pairs(map) do
		registry[name] = id
	end
end

-- ── Animator resolution ──

local function getAnimator(model: Instance): Animator?
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		return hum:FindFirstChildOfClass("Animator") or (function()
			local a = Instance.new("Animator")
			a.Parent = hum
			return a
		end)()
	end
	local ac = model:FindFirstChildOfClass("AnimationController")
	if ac then
		return ac:FindFirstChildOfClass("Animator") or (function()
			local a = Instance.new("Animator")
			a.Parent = ac
			return a
		end)()
	end
	return nil
end

-- ── Play / Stop ──

function AnimationService.Play(model: Instance, name: string, opts: PlayOpts?): AnimationTrack?
	local animId = registry[name] or name -- allow a raw id too
	local animator = getAnimator(model)
	if not animator then
		warn(`[Anim] no Animator on {model:GetFullName()}`)
		return nil
	end
	local cache = trackCache[model]
	if not cache then
		cache = {}
		trackCache[model] = cache
	end
	local track = cache[name]
	if not track then
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		track = animator:LoadAnimation(anim)
		cache[name] = track
	end
	local o: PlayOpts = opts or {}
	if o.Priority then
		track.Priority = o.Priority
	end
	if o.Looped ~= nil then
		track.Looped = o.Looped
	end
	track:Play(o.FadeTime or 0.1, o.Weight or 1, o.Speed or 1)
	return track
end

function AnimationService.Stop(model: Instance, name: string, fadeTime: number?): boolean
	local cache = trackCache[model]
	local track = cache and cache[name]
	if not track then
		return false
	end
	track:Stop(fadeTime or 0.1)
	return true
end

function AnimationService.StopAll(model: Instance, fadeTime: number?): ()
	local animator = getAnimator(model)
	if animator then
		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
			track:Stop(fadeTime or 0.1)
		end
	end
end

function AnimationService.IsPlaying(model: Instance, name: string): boolean
	local cache = trackCache[model]
	local track = cache and cache[name]
	return track ~= nil and track.IsPlaying
end

-- ── Keyframe markers ──

-- Connect to a keyframe marker on a track (hit frames, footsteps).
function AnimationService.OnMarker(track: AnimationTrack, markerName: string, fn: (value: string?) -> ()): RBXScriptConnection
	return track:GetMarkerReachedSignal(markerName):Connect(fn)
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(AnimationService, {
	Name = "Anim",
	Needs = {},
})

return AnimationService
