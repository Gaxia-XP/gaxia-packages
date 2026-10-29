-- Client side: InvokeServer returns the server's value; FireServer/FireClient round trip.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local remote = ReplicatedStorage:WaitForChild("Double") :: RemoteFunction
local payload = setmetatable({ fn = function() end, x = 1 }, {})
local result, info = remote:InvokeServer(21, payload)
print("got", result, "from", info.from)

local ping = ReplicatedStorage:WaitForChild("Ping") :: RemoteEvent
ping.OnClientEvent:Connect(function(reply)
	print("client heard", reply)
end)
ping:FireServer("hi")
