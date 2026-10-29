-- WaitForChild on something that never appears: Roblox warns after 5 s and the thread waits forever.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local remotes = ReplicatedStorage:WaitForChild("RemotesThatNobodyCreates")
print("never printed", remotes)
