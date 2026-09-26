--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   SoundController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/SoundController
-- Purpose:  Pooled sound playback with a 3-bus mixer
--           (music / sfx / ui). Pools reusable Sound instances per
--           category so rapid-fire SFX (footsteps, gunshots) don't
--           thrash the GC by allocating a fresh Sound each play.
--           Music slot crossfades on swap so transitions never
--           hard-cut.
-- ─────────────────────────────────────────────────────────────

local ContentProvider   = game:GetService("ContentProvider")
local RunService        = game:GetService("RunService")
local SoundService      = game:GetService("SoundService")
local TweenService      = game:GetService("TweenService")

-- ── Types ──

export type Category = "music" | "sfx" | "ui"

-- Play / PlayOnce options: any Sound property by name (Looped, PlaybackSpeed,
-- RollOffMaxDistance, ...) plus two special keys:
--   category — mixer bus ("music" | "sfx" | "ui", case-insensitive; default "sfx")
--   volume / Volume — intrinsic volume before the category mix (default 1)
export type SoundProps = {
	category: (Category | string)?,
	volume: number?,
	[string]: any,
}

export type SoundControllerType = {
	Preload            : (soundIds: { string }) -> (),
	Play               : (soundId: string, props: SoundProps?) -> Sound,
	PlayOnce           : (soundId: string, props: SoundProps?) -> (),
	SetCategoryVolume  : (category: Category, volume: number) -> (),
	GetCategoryVolume  : (category: Category) -> number,
	StopAll            : (category: Category?) -> (),
	PlayMusic          : (soundId: string, fadeIn: number?) -> Sound,
	StopMusic          : (fadeOut: number?) -> (),
}

-- Client-only: SoundService output is irrelevant on the server.
if not RunService:IsClient() then
	return ({} :: any) :: SoundControllerType
end

-- ── Constants ──
local POOL_FOLDER_NAME : string = "Gaxia_SoundPool"
local DEFAULT_FADE     : number = 0.5    -- seconds; common crossfade length
local MAX_POOL_PER_CAT : number = 16     -- cap to bound memory; over-cap = destroy

-- ── State ──

-- Hidden parent under SoundService keeps pooled sounds out of Workspace and
-- makes them obvious when inspecting in the Explorer (one tidy folder).
local function ensurePoolFolder(): Folder
	local existing = SoundService:FindFirstChild(POOL_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = POOL_FOLDER_NAME
	f.Parent = SoundService
	return f
end

local poolFolder : Folder = ensurePoolFolder()

-- Per-category volume multipliers — applied at PLAY time, not stored on the
-- Sound itself, so SetCategoryVolume affects already-playing sounds via the
-- volume-poke loop below.
local categoryVolume : { [Category]: number } = {
	music = 1.0,
	sfx   = 1.0,
	ui    = 1.0,
}

-- Each Sound tagged with its category + its "intrinsic" volume (what the
-- caller asked for, before category-mix applied). We store on the instance
-- via attributes so we can recompute final volume on the fly.
local INTRINSIC_VOL_ATTR : string = "GaxiaIntrinsicVolume"
local CATEGORY_ATTR      : string = "GaxiaCategory"

-- Per-category pools.
type Pool = {
	available : { Sound },
	active    : { [Sound]: boolean },
}
local pools : { [Category]: Pool } = {
	music = { available = {}, active = {} },
	sfx   = { available = {}, active = {} },
	ui    = { available = {}, active = {} },
}

-- Currently-playing music slot — at most one. Crossfade target lives here
-- between PlayMusic() and the fade completing.
local currentMusic : Sound? = nil

local SoundController = {}

-- ── Helpers ──

-- Default category for Play() — we use sfx unless caller overrides via props.
local function categoryFromProps(props: SoundProps?): Category
	if props and props.category then
		local c = tostring(props.category):lower()
		if c == "music" or c == "sfx" or c == "ui" then
			return c :: Category
		end
	end
	return "sfx"
end

-- Acquire a Sound from the pool or fabricate one. We reset critical props on
-- acquire so a previously-used Sound starts in a clean state.
local function acquire(category: Category): Sound
	local pool = pools[category]
	local sound : Sound
	local recycled : Sound? = table.remove(pool.available)
	if recycled then
		sound = recycled
	else
		sound = Instance.new("Sound")
		sound.Parent = poolFolder
	end
	pool.active[sound] = true
	sound:SetAttribute(CATEGORY_ATTR, category)
	-- Reset state so a recycled Sound doesn't leak prior config.
	sound.Looped = false
	sound.PlaybackSpeed = 1
	sound.TimePosition = 0
	return sound
end

-- Return a Sound to its pool (or destroy if over capacity).
local function release(sound: Sound): ()
	local cat = sound:GetAttribute(CATEGORY_ATTR)
	if typeof(cat) ~= "string" then
		sound:Destroy()
		return
	end
	local pool = pools[cat :: Category]
	if not pool then
		sound:Destroy()
		return
	end
	pool.active[sound] = nil
	if #pool.available >= MAX_POOL_PER_CAT then
		sound:Destroy()
		return
	end
	-- Best-effort silence; future acquire() resets these too but pause now
	-- ensures the sound doesn't keep ticking in the pool.
	pcall(function()
		sound:Stop()
	end)
	table.insert(pool.available, sound)
end

-- Apply category mix to an intrinsic volume.
local function mix(category: Category, intrinsic: number): number
	return intrinsic * (categoryVolume[category] or 1)
end

-- Apply caller-supplied props to a Sound. The `category` and `volume` keys are
-- special-cased; everything else passes through.
local function applyProps(sound: Sound, soundId: string, category: Category, props: SoundProps?): ()
	sound.SoundId = soundId
	local intrinsic : number = 1
	if props then
		for k, v in pairs(props) do
			if k == "category" then
				-- already consumed
			elseif k == "volume" or k == "Volume" then
				intrinsic = tonumber(v) or 1
			else
				-- pcall to ignore properties that don't exist on Sound (e.g.
				-- caller passes a typo) without crashing the whole play call.
				-- rawset-style assign via local alias avoids the "ambiguous
				-- syntax" Luau warning that fires when a line opens with `(`.
				local target : any = sound
				pcall(function()
					target[k] = v
				end)
			end
		end
	end
	sound:SetAttribute(INTRINSIC_VOL_ATTR, intrinsic)
	sound.Volume = mix(category, intrinsic)
end

-- ── Preload ──
-- Wrap ContentProvider:PreloadAsync in pcall — it yields and can fail on
-- bad asset IDs; we don't want bad IDs to take down the calling thread.
function SoundController.Preload(soundIds: { string }): ()
	local placeholders : { Sound } = {}
	for _, id in ipairs(soundIds) do
		local s = Instance.new("Sound")
		s.SoundId = id
		s.Parent = poolFolder
		table.insert(placeholders, s)
	end
	pcall(function()
		ContentProvider:PreloadAsync(placeholders)
	end)
	-- Placeholders are throw-away — Roblox caches the underlying asset blob,
	-- so destroying the Sound objects doesn't lose the prefetch benefit.
	for _, s in ipairs(placeholders) do
		s:Destroy()
	end
end

-- ── Play ──
-- Pool-backed playback; returns the Sound so callers can stop / inspect it.
-- Caller is responsible for calling :Stop or letting it finish (PlayOnce
-- handles auto-release).
function SoundController.Play(soundId: string, props: SoundProps?): Sound
	local category: Category = categoryFromProps(props)
	local sound = acquire(category)
	applyProps(sound, soundId, category, props)
	sound:Play()
	return sound
end

-- ── PlayOnce ──
-- Fire-and-forget convenience. Sound auto-releases back to pool on Ended.
-- WHY a separate API: callers that don't need the Sound handle shouldn't
-- have to manage release themselves — easy to leak otherwise.
function SoundController.PlayOnce(soundId: string, props: SoundProps?): ()
	local sound = SoundController.Play(soundId, props)
	local conn : RBXScriptConnection? = nil
	conn = sound.Ended:Connect(function()
		if conn then conn:Disconnect() end
		release(sound)
	end)
end

-- ── Category volume ──
function SoundController.SetCategoryVolume(category: Category, volume: number): ()
	local v = math.clamp(volume, 0, 1)
	categoryVolume[category] = v
	-- Re-mix every active sound in this category so the change is immediate
	-- (not only for sounds played AFTER the call).
	local pool = pools[category]
	if not pool then return end
	for sound, _ in pairs(pool.active) do
		local intrinsic = sound:GetAttribute(INTRINSIC_VOL_ATTR)
		if typeof(intrinsic) == "number" then
			sound.Volume = mix(category, intrinsic)
		end
	end
end

function SoundController.GetCategoryVolume(category: Category): number
	return categoryVolume[category] or 1
end

-- ── StopAll ──
-- Stop+release everything in a category, or all categories if nil.
function SoundController.StopAll(category: Category?): ()
	local function stopCat(cat: Category): ()
		local pool = pools[cat]
		if not pool then return end
		-- Snapshot to avoid mutating during iteration.
		local snapshot : { Sound } = {}
		for s, _ in pairs(pool.active) do
			table.insert(snapshot, s)
		end
		for _, s in ipairs(snapshot) do
			pcall(function() s:Stop() end)
			release(s)
		end
		if cat == "music" then
			currentMusic = nil
		end
	end

	if category then
		stopCat(category)
	else
		stopCat("music")
		stopCat("sfx")
		stopCat("ui")
	end
end

-- ── PlayMusic ──
-- Crossfades old track out while new track fades in. Returns the new music
-- Sound so callers can hook .Ended for chaining.
function SoundController.PlayMusic(soundId: string, fadeIn: number?): Sound
	local fade = fadeIn or DEFAULT_FADE
	-- Acquire from music pool so volume mixing/category attribute attach correctly.
	local newSound = acquire("music")
	applyProps(newSound, soundId, "music", { volume = 1, Looped = true })
	-- Start at 0 volume so the fade-in actually does something — applyProps
	-- already set the mix-target; we cache it to ramp back up.
	local target : number = newSound.Volume
	newSound.Volume = 0
	newSound:Play()
	if fade > 0 then
		TweenService:Create(newSound, TweenInfo.new(fade, Enum.EasingStyle.Linear), {
			Volume = target,
		}):Play()
	else
		newSound.Volume = target
	end

	-- Fade out + release any existing track concurrently with the fade-in.
	local prev = currentMusic
	currentMusic = newSound
	if prev and prev ~= newSound then
		local fadeOutTween = TweenService:Create(prev, TweenInfo.new(fade, Enum.EasingStyle.Linear), {
			Volume = 0,
		})
		fadeOutTween.Completed:Connect(function()
			pcall(function() prev:Stop() end)
			release(prev)
		end)
		fadeOutTween:Play()
	end

	return newSound
end

-- ── StopMusic ──
function SoundController.StopMusic(fadeOut: number?): ()
	local prev = currentMusic
	if not prev then return end
	currentMusic = nil
	local fade = fadeOut or DEFAULT_FADE
	if fade <= 0 then
		pcall(function() prev:Stop() end)
		release(prev)
		return
	end
	local t = TweenService:Create(prev, TweenInfo.new(fade, Enum.EasingStyle.Linear), {
		Volume = 0,
	})
	t.Completed:Connect(function()
		pcall(function() prev:Stop() end)
		release(prev)
	end)
	t:Play()
end

return SoundController :: SoundControllerType
