-- A LocalScript waits for a remote the server never makes. The player's client
-- ends when the player leaves; the wait is reported as a hang of that client.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local remote = ReplicatedStorage:WaitForChild("ShopRemote")
print("never printed", remote)
