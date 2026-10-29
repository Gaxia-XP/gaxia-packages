-- Mistakes Roblox reports as errors. Each runs in its own thread.
local ServerStorage = game:GetService("ServerStorage")

task.spawn(function()
	local part = Instance.new("Part")
	part.Parent = workspace
	print(workspace.Lava.Position) -- no child named Lava
end)

task.spawn(function()
	local label = Instance.new("TextLabel")
	label.Visible = "yes" -- wrong type
end)

task.spawn(function()
	local folder = Instance.new("Folder")
	folder:FindFirstChild("x", true)
	folder.FindFirstChild("y") -- '.' instead of ':'
end)

task.spawn(function()
	require(ServerStorage.BrokenModule)
end)
