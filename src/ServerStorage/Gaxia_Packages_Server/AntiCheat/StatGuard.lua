--!strict
--[[
	Module : StatGuard
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.StatGuard
	Purpose : Watches leaderstats IntValue/NumberValue changes and flags any
	          increase that did NOT originate from EconomyService. Event-driven
	          via :GetPropertyChangedSignal("Value") — zero idle cost.

	The mechanism: when EconomyService writes a balance, it briefly marks the
	stat as "expected" (via attribute set to the new value). Any other change
	whose new value does not match the expected attribute is a violation.
]]


local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Trove     = SharedPkg.Trove

-- ── Config (server-side, see ServerStorage/Gaxia_Packages_Server/Config) ──
-- FindFirstChild (not WaitForChild): detectors are required THROUGH the server
-- loader's no-yield __index metamethod; WaitForChild would yield across that
-- boundary. Config's body is a pure table (no yields), so require is safe.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any

local EXPECTED_ATTR : string = SharedPkg.Constants.STAT_EXPECTED_ATTRIBUTE
local LEADERSTATS_NAME : string = "leaderstats"
local NUMERIC_TYPES: { [string]: boolean } = {
	IntValue    = true,
	NumberValue = true,
}

local StatGuard = {}
StatGuard.Name = "Stat"

local orchestratorRef: any = nil
local playerTroves: { [Player]: any } = {}

-- Hook one ValueObject: any change away from the EXPECTED_ATTR cached value
-- is a violation, except increases of <= 0 (set/spend lowers balance freely).
local function hookValue(player: Player, stat: Instance)
	if not NUMERIC_TYPES[stat.ClassName] then return end
	local s = stat :: any
	-- Seed the expected attribute with the current value so the first legit
	-- write does not trip the guard.
	stat:SetAttribute(EXPECTED_ATTR, s.Value)

	local trove = playerTroves[player]
	trove:Add(stat:GetPropertyChangedSignal("Value"):Connect(function()
		local expected = stat:GetAttribute(EXPECTED_ATTR)
		if typeof(expected) == "number" and s.Value == expected then
			-- Matches what EconomyService (or whoever) just wrote — pass.
			return
		end
		-- Mismatch: someone wrote the stat without going through the expected
		-- pathway. Even decreases are flagged because the only legitimate
		-- writers should always update EXPECTED_ATTR first.
		if orchestratorRef then
			orchestratorRef.Flag(player, "StatTamper", Config.AntiCheat.Stat.Severity)
		end
		-- Re-sync to current so the player keeps moving forward; the flag is
		-- what the orchestrator acts on, not the stat itself.
		stat:SetAttribute(EXPECTED_ATTR, s.Value)
	end))
end

local function attachPlayer(player: Player)
	if playerTroves[player] then return end
	local trove = Trove.new()
	playerTroves[player] = trove

	-- Hook current leaderstats children, and any added later.
	local function hookFolder(folder: Folder)
		for _, child in ipairs(folder:GetChildren()) do
			hookValue(player, child)
		end
		trove:Add(folder.ChildAdded:Connect(function(child)
			hookValue(player, child)
		end))
	end

	local existing = player:FindFirstChild(LEADERSTATS_NAME)
	if existing then hookFolder(existing :: Folder) end

	-- leaderstats may not yet exist at PlayerAdded; watch for it.
	trove:Add(player.ChildAdded:Connect(function(child)
		if child.Name == LEADERSTATS_NAME and child:IsA("Folder") then
			hookFolder(child :: Folder)
		end
	end))
end

local function detachPlayer(player: Player)
	local trove = playerTroves[player]
	if trove then
		trove:Clean()
		playerTroves[player] = nil
	end
end

-- Public helper for EconomyService to "announce" a legitimate write so the
-- guard does not flag the same change as foreign.
function StatGuard.Expect(player: Player, statName: string, newValue: number)
	local folder = player:FindFirstChild(LEADERSTATS_NAME)
	if not folder then return end
	local stat = folder:FindFirstChild(statName)
	if stat then
		stat:SetAttribute(EXPECTED_ATTR, newValue)
	end
end

function StatGuard.Init(orchestrator: any): ()
	orchestratorRef = orchestrator
	for _, p in ipairs(Players:GetPlayers()) do
		attachPlayer(p)
	end
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(detachPlayer)
end

return StatGuard
