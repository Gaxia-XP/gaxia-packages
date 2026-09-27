--!strict
-- Config/init.lua
-- Location : ServerStorage/Gaxia_Packages_Server/Config
-- Purpose  : Aggregates per-API config children into one table.
--
-- Access   : require(ServerStorage.Gaxia_Packages_Server).Config
--            e.g. Gaxia.Config.Data.StoreName
--                 Gaxia.Config.AntiCheat.Teleport.MaxDelta
--
-- To edit a section, open the child module that owns it:
--   Data · AntiCheat · Admin · Economy · Raid · Idle · Daily
--   Vault · Mail · Party · Cooldown · Leaderboard · Level
--   Inventory · Pets · Teleport · CrossServer · Event
--   Interaction · Social · Webhook · Runtime · Player
--   Features (which services boot)

return {
	Data        = require(script.Data),
	AntiCheat   = require(script.AntiCheat),
	Admin       = require(script.Admin),
	Economy     = require(script.Economy),
	Raid        = require(script.Raid),
	Idle        = require(script.Idle),
	Daily       = require(script.Daily),
	Vault       = require(script.Vault),
	Mail        = require(script.Mail),
	Party       = require(script.Party),
	Cooldown    = require(script.Cooldown),
	Leaderboard = require(script.Leaderboard),
	Level       = require(script.Level),
	Inventory   = require(script.Inventory),
	Pets        = require(script.Pets),
	Teleport    = require(script.Teleport),
	CrossServer = require(script.CrossServer),
	Event       = require(script.Event),
	Interaction = require(script.Interaction),
	Social      = require(script.Social),
	Webhook     = require(script.Webhook),
	Runtime     = require(script.Runtime),
	Player      = require(script.Player),
	Features    = require(script.Features),
}
