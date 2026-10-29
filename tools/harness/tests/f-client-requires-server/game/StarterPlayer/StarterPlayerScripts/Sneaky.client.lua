-- A LocalScript cannot reach ServerStorage: the server package does not exist on the client.
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(ServerStorage.Gaxia_Packages_Server)
print("never printed", GaxiaServer)
