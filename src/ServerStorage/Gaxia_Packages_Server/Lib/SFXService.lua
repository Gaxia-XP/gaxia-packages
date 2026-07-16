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
--           when they end. Category volumes pair with SettingsService for a
--           player audio-options menu.
--
-- Access  : Gaxia.SFX  (server)
--   Gaxia.SFX.Register("Explosion", { SoundId = "rbxassetid://12222200", PitchVariation = 0.2, Category = "SFX" })
--   Gaxia.SFX.PlayAt("Explosion", hrp.Position)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local Workspace = game:GetService("Workspace")

local FALLBACK_LIFETIME : number = 10 -- destroy holder after this if Ended never fires

export type SoundDef = {
	SoundId: string,
	Volume: number?,
	Pitch: number?,
	PitchVariation: number?,
	Category: string?,
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

function SFXService.SetCategoryVolume(category: string, volume: number): ()
	categoryVolume[category] = math.max(0, volume)
end

function SFXService.GetCategoryVolume(category: string): number
	local v = categoryVolume[category]
	return v ~= nil and v or 1
end

-- Temporarily scale a category by `factor` for `duration`, then restore.
function SFXService.Duck(category: string, factor: number, duration: number): ()
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
	task.delay(FALLBACK_LIFETIME, destroy)
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

return SFXService
