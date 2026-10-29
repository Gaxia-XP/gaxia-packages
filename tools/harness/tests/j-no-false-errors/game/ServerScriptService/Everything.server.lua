-- Common Roblox APIs used correctly: none of this may produce an error.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = require(ReplicatedStorage.Shared)
Shared.counter += 1
assert(Shared.loadedOn == "server")

local store = DataStoreService:GetDataStore("Saves")
local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = ReplicatedStorage
local getCoins = Instance.new("RemoteFunction")
getCoins.Name = "GetCoins"
getCoins.Parent = remotes
local notify = Instance.new("RemoteEvent")
notify.Name = "Notify"
notify.Parent = remotes

local coins: { [number]: number } = {}

Players.PlayerAdded:Connect(function(player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local value = Instance.new("IntValue")
	value.Name = "Coins"
	value.Parent = leaderstats
	leaderstats.Parent = player

	local ok, saved = pcall(function()
		return store:GetAsync("p_" .. player.UserId)
	end)
	coins[player.UserId] = if ok and saved then saved.coins else 50
	value.Value = coins[player.UserId]
	player:SetAttribute("Level", 3)

	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		local root = character:WaitForChild("HumanoidRootPart") :: BasePart
		humanoid.WalkSpeed = 20
		root.CFrame = root.CFrame + Vector3.new(0, 1, 0)
		CollectionService:AddTag(character, "Fighter")
		notify:FireClient(player, "welcome", { coins = value.Value, list = { 1, 2, 3 } })
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	store:UpdateAsync("p_" .. player.UserId, function(old)
		old = old or {}
		old.coins = coins[player.UserId]
		return old
	end)
	coins[player.UserId] = nil
end)

game:BindToClose(function()
	task.wait(1)
	print("closing")
end)

getCoins.OnServerInvoke = function(player)
	return coins[player.UserId]
end

-- parts, tweens, attributes, tags
local pad = Instance.new("Part")
pad.Name = "Pad"
pad.Anchored = true
pad.Size = Vector3.new(8, 1, 8)
pad.Position = Vector3.new(0, 0.5, 20)
pad.BrickColor = BrickColor.new("Bright green")
pad.Color = Color3.fromRGB(0, 200, 0)
pad.Material = Enum.Material.Neon
pad.Parent = workspace
pad:SetAttribute("Bonus", 2)
pad.Touched:Connect(function() end)
CollectionService:AddTag(pad, "Pad")
assert(#CollectionService:GetTagged("Pad") == 1)
local tween = TweenService:Create(pad, TweenInfo.new(1, Enum.EasingStyle.Sine), { Transparency = 0.5, Position = Vector3.new(0, 2, 20) })
tween:Play()
tween.Completed:Wait()
assert(pad.Transparency == 0.5)

local spark = Instance.new("Part")
spark.Parent = workspace
Debris:AddItem(spark, 2)

local encoded = HttpService:JSONEncode({ a = 1, b = { 1, 2 } })
assert(HttpService:JSONDecode(encoded).a == 1)
assert(#HttpService:GenerateGUID(false) == 36)

local beat = 0
local conn
conn = RunService.Heartbeat:Connect(function(dt)
	beat += dt
	if beat > 1 then
		conn:Disconnect()
	end
end)

local bindable = Instance.new("BindableEvent")
bindable.Event:Connect(function(t)
	assert(t.x == 1)
end)
bindable:Fire({ x = 1 })

local ok = pcall(function()
	return MarketplaceService:UserOwnsGamePassAsync(1, 123)
end)
assert(ok)

local r = Random.new(42)
assert(r:NextInteger(1, 6) >= 1)
print("server ok", os.time() > 0, DateTime.now().UnixTimestamp > 0)
