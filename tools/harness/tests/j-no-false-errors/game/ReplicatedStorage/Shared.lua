-- A shared module required by both sides (each side gets its own copy).
local Shared = {}
Shared.loadedOn = if game:GetService("RunService"):IsServer() then "server" else "client"
Shared.counter = 0
return Shared
