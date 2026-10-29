--!strict
-- ─────────────────────────────────────────────────────────────
-- SFXService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/SFXService
-- Purpose : Sound bank + 3D audio. Register sounds once (id, base volume, pitch
--           + random variation, category); PlayAt spawns a positional Sound at a
--           world point with randomized pitch so repeats don't sound robotic;
--           Play2D for UI/global. Per-category volume (SFX/Music/Ambient) scales
--           every sound in that bus, and Duck() temporarily drops a bus (lower
--           music while a cutscene voice plays) then restores. Sounds auto-clean
--           when they end (or after their own length, or after 10 s when they
--           never load). Category volumes pair with SettingsService for a
--           player audio-options menu.
--
-- Access  : Gaxia.SFX  (server)
--   Gaxia.SFX.Register("Explosion", { SoundId = "rbxassetid://12222200", PitchVariation = 0.2, Category = "SFX" })
--   Gaxia.SFX.PlayAt("Explosion", hrp.Position)
-- ─────────────────────────────────────────────────────────────
local Workspace = game:GetService("Workspace")

local Lifecycle = require(script.Parent.ServiceLifecycle)

local FALLBACK_LIFETIME : number = 10 -- longest wait for a sound to load (Ended never fires if it does not)
local END_MARGIN        : number = 1  -- seconds kept after the sound's own length, before forcing cleanup

-- The built-in buses; any other string is a custom category.
export type SoundCategory = "SFX" | "Music" | "Ambient"

export type SoundDef = {
	SoundId: string,
	Volume: number?,
	Pitch: number?,
	PitchVariation: number?,
	Category: (SoundCategory | string)?,
	RollOffMaxDistance: number?,
}

local SFXService = {}

local bank: { [string]: SoundDef } = {}
local categoryVolume: { [string]: number } = {}
local rng = Random.new()

-- ── PURE: randomized playback speed (unit-testable) ──
function SFXService.ComputePitch(base: number, variation: number, roll01: number): number
	return base + (roll01 * 2 - 1) * variation
end

-- ── Registry + category volume ──

function SFXService.Register(name: string, def: SoundDef): ()
	bank[name] = def
end

function SFXService.SetCategoryVolume(category: SoundCategory | string, volume: number): ()
	categoryVolume[category] = math.max(0, volume)
end

function SFXService.GetCategoryVolume(category: SoundCategory | string): number
	local v = categoryVolume[category]
	return v ~= nil and v or 1
end

-- Temporarily scale a category by `factor` for `duration`, then restore.
function SFXService.Duck(category: SoundCategory | string, factor: number, duration: number): ()
	local original = SFXService.GetCategoryVolume(category)
	SFXService.SetCategoryVolume(category, original * factor)
	task.delay(duration, function()
		SFXService.SetCategoryVolume(category, original)
	end)
end

-- ── Internal ──

local function effectsFolder(): Instance
	local f = Workspace:FindFirstChild("Effects")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Effects"
		f.Parent = Workspace
	end
	return f
end

local function buildSound(def: SoundDef): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = def.SoundId
	sound.Volume = (def.Volume or 0.5) * SFXService.GetCategoryVolume(def.Category or "SFX")
	sound.PlaybackSpeed = SFXService.ComputePitch(def.Pitch or 1, def.PitchVariation or 0, rng:NextNumber())
	if def.RollOffMaxDistance then
		sound.RollOffMaxDistance = def.RollOffMaxDistance
	end
	return sound
end

-- Destroy `holder` when the sound ends. Ended does not fire for a sound that never
-- loads, so a fallback also cleans up: once the sound has loaded, after its own
-- length (TimeLength / PlaybackSpeed, plus a margin); if it has not loaded (or its
-- TimeLength is still 0) within FALLBACK_LIFETIME seconds, then. A sound longer than
-- FALLBACK_LIFETIME (music) is no longer cut off.
local function autoClean(holder: Instance, sound: Sound): ()
	local cleaned = false
	local function destroy()
		if cleaned then
			return
		end
		cleaned = true
		holder:Destroy()
	end
	sound.Ended:Once(destroy)

	local function lengthLeft(): number?
		-- TimeLength is 0 until the asset has loaded.
		if not sound.IsLoaded or sound.TimeLength <= 0 then
			return nil
		end
		local speed = math.max(sound.PlaybackSpeed, 0.01)
		return math.max(0, (sound.TimeLength - sound.TimePosition) / speed) + END_MARGIN
	end
	local function scheduleFromLength(): boolean
		local left = lengthLeft()
		if left == nil then
			return false
		end
		task.delay(left, destroy)
		return true
	end

	if scheduleFromLength() then
		return
	end
	local loadedConn = sound.Loaded:Once(function()
		scheduleFromLength()
	end)
	task.delay(FALLBACK_LIFETIME, function()
		loadedConn:Disconnect()
		if cleaned then
			return
		end
		if not scheduleFromLength() then
			destroy() -- never loaded: Ended will not fire
		end
	end)
end

-- ── Playback ──

function SFXService.PlayAt(name: string, position: Vector3): Sound?
	local def = bank[name]
	if not def then
		warn(`[SFX] no sound '{name}'`)
		return nil
	end
	local holder = Instance.new("Part")
	holder.Name = `SFX_{name}`
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.CFrame = CFrame.new(position)
	local sound = buildSound(def)
	sound.Parent = holder
	holder.Parent = effectsFolder()
	sound:Play()
	autoClean(holder, sound)
	return sound
end

function SFXService.Play2D(name: string): Sound?
	local def = bank[name]
	if not def then
		warn(`[SFX] no sound '{name}'`)
		return nil
	end
	local sound = buildSound(def)
	sound.Parent = effectsFolder()
	sound:Play()
	autoClean(sound, sound)
	return sound
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(SFXService, {
	Name = "SFX",
	Needs = {},
})

return SFXService
