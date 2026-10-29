local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
task.wait(2)
local coins = Gaxia.Net.InvokeServer("GetCoins")
print("[AskCoins] coins:", coins)
