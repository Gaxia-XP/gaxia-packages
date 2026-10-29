-- Server side of a RemoteFunction round trip.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local remote = Instance.new("RemoteFunction")
remote.Name = "Double"
remote.OnServerInvoke = function(player: Player, n: number, payload: { [string]: any })
	assert(typeof(player) == "Instance" and player:IsA("Player"), "first argument is the player")
	assert(payload.fn == nil, "functions are not sent")
	assert(getmetatable(payload) == nil, "metatables are not sent")
	return n * 2, { from = player.Name }
end
remote.Parent = ReplicatedStorage

local event = Instance.new("RemoteEvent")
event.Name = "Ping"
event.Parent = ReplicatedStorage
event.OnServerEvent:Connect(function(player, text)
	event:FireClient(player, "pong:" .. text)
end)
