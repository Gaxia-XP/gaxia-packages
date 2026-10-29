--!strict
--[[
	Module : AnimationGuard
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.AnimationGuard
	Purpose : Whitelist of legal AnimationIds. Listens for AnimationPlayed on
	          each player's Humanoid and flags ids that are not in the
	          whitelist. The whitelist is seeded from ServerStorage.Assets and
	          ReplicatedStorage.Assets (every Animation instance contributes its
	          AnimationId). Add more via AnimationGuard.Allow(id).
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

-- ── Dependencies ──
local Trove  = require(ReplicatedStorage.Gaxia_Packages.Shared.Trove)
local Types  = require(script.Parent.Parent.Types)
local Config = require(script.Parent.Parent.Config)

-- ── Types ──
type DetectorHost = Types.DetectorHost

local AnimationGuard = {}
AnimationGuard.Name = "Animation"

-- AnimationId (rbxassetid://N) → true. Anything outside this set fires a flag.
local whitelistedIds: { [string]: boolean } = {}
local orchestratorRef: DetectorHost? = nil
local playerTroves: { [Player]: typeof(Trove.new()) } = {}

-- Roblox sometimes returns Animation ids in different formats; normalise to
-- the rbxassetid://N canonical form (numeric tail with full scheme).
local function normaliseId(id: string): string
	if id:match("^rbxassetid://") then return id end
	if id:match("^https?://") then
		local n = id:match("(%d+)$")
		if n then return `rbxassetid://{n}` end
	end
	if tonumber(id) then return `rbxassetid://{id}` end
	return id
end

function AnimationGuard.Allow(id: string)
	whitelistedIds[normaliseId(id)] = true
end

-- Seed whitelist with every Animation found under Assets folders. Devs can add
-- extras via AnimationGuard.Allow.
local function seedFromAssets()
	for _, root in ipairs({ ServerStorage:FindFirstChild("Assets"), ReplicatedStorage:FindFirstChild("Assets") }) do
		if root then
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("Animation") and d.AnimationId ~= "" then
					AnimationGuard.Allow(d.AnimationId)
				end
			end
		end
	end
end

-- Opt-in: AnimationGuard stays inert until at least one id is whitelisted.
-- This prevents Roblox-provided default animations (idle / walk / run / jump
-- baked into the Animate LocalScript) from being flagged in a fresh project
-- where ServerStorage.Assets / ReplicatedStorage.Assets contain no Animation
-- instances yet. To enable enforcement, call AnimationGuard.Allow(id) for
-- every legal animation id before / at game start.
local function isWhitelistActive(): boolean
	for _ in pairs(whitelistedIds) do
		return true
	end
	return false
end

local function attachHumanoid(player: Player, humanoid: Humanoid)
	local trove = playerTroves[player]
	if not trove then return end
	trove:Add(humanoid.AnimationPlayed:Connect(function(track: AnimationTrack)
		-- Skip enforcement entirely while the whitelist is empty. This is the
		-- only safe default — otherwise EVERY animation is "unknown" and a
		-- freshly-spawned R15 character racks up flags from idle/walk/run.
		if not isWhitelistActive() then return end
		local anim = track.Animation
		if not anim then return end
		local id = normaliseId(anim.AnimationId)
		if not whitelistedIds[id] then
			if orchestratorRef then
				-- "soft" because Roblox plays default animations whose ids may
				-- not be in user assets; threshold accumulation catches real abuse.
				orchestratorRef.Flag(player, "Animation", Config.AntiCheat.Animation.Severity)
			end
		end
	end))
end

local function attachPlayer(player: Player)
	if playerTroves[player] then return end
	local trove = Trove.new()
	playerTroves[player] = trove

	local function hookCharacter(character: Model)
		local hum = character:WaitForChild("Humanoid", 5) :: Humanoid?
		if hum then attachHumanoid(player, hum) end
	end

	if player.Character then hookCharacter(player.Character) end
	trove:Add(player.CharacterAdded:Connect(hookCharacter))
end

local function detachPlayer(player: Player)
	local trove = playerTroves[player]
	if trove then
		trove:Clean()
		playerTroves[player] = nil
	end
end

function AnimationGuard.Init(orchestrator: DetectorHost): ()
	orchestratorRef = orchestrator
	seedFromAssets()
	-- Re-seed when new animations are added at runtime (dev workflows).
	for _, root in ipairs({ ServerStorage:FindFirstChild("Assets"), ReplicatedStorage:FindFirstChild("Assets") }) do
		if root then
			root.DescendantAdded:Connect(function(d)
				if d:IsA("Animation") and d.AnimationId ~= "" then
					AnimationGuard.Allow(d.AnimationId)
				end
			end)
		end
	end

	for _, p in ipairs(Players:GetPlayers()) do attachPlayer(p) end
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(detachPlayer)
end

return AnimationGuard
