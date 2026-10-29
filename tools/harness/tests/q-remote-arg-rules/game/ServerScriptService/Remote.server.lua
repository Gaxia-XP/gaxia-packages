local RS = game:GetService("ReplicatedStorage")
local re = Instance.new("RemoteEvent")
re.Name = "Args"
re.Parent = RS
re.OnServerEvent:Connect(function(plr, ...)
	print("server got", select("#", ...), ...)
end)
local rf = Instance.new("RemoteFunction")
rf.Name = "Fn"
rf.Parent = RS
rf.OnServerInvoke = function(plr, a, b)
	print("invoke got", typeof(plr), a, b)
	return true
end
local tbl = Instance.new("RemoteEvent")
tbl.Name = "Tbl"
tbl.Parent = RS
game:GetService("Players").PlayerAdded:Connect(function(p)
	tbl:FireClient(p, { a = 1, 2, 3 }, { [workspace] = "ws" }, { [true] = 1 })
end)
