-- Counts how often /ping runs. Roblox asks TextChannel.ShouldDeliverCallback once
-- per recipient; a chat command must still run once per typed message.
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

local runs = 0
GaxiaServer.Chat.Register("ping", { help = "Count runs" }, function(_caller: Player, _args: { string }): string?
	runs += 1
	return "pong"
end)

task.delay(9, function()
	print(`[PingCount] runs={runs};`)
end)
