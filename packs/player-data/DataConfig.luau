--!strict
--[[
	Module  : DataConfig
	Location: ServerStorage.GaxiaPackages.PlayerData.DataConfig
	Purpose : The game's own settings for DataManager (packs/player-data): the DataStore name, the key prefix,
	          the save template and the resilience tunables. This is the one file of the pack a game edits.

	Template: every field a player's save starts with. A save that lacks a field gets it from here when it loads
	          (ProfileStore's Reconcile), so adding a field is safe. Keep values to numbers, strings, booleans and
	          tables of them: no Instances, Vector3, Color3, CFrame or functions. Keep __version = 1 until the game
	          registers a migration with DataMigration.

	The defaults below are GaxiaPackages' own (Config/Data.lua and DataManager's template).
]]

return {
	StoreName             = "GaxiaPlayerData",
	KeyPrefix             = "Player_",
	WaitForDefaultTimeout = 30,
	ShutdownFlushDeadline = 25,
	Write = {
		MaxAttempts    = 4,
		BaseBackoff    = 1,
		BudgetWaitStep = 0.5,
		BudgetMaxWait  = 10,
	},
	Backup = {
		Enabled   = false,
		StoreName = "GaxiaPlayerData_Backup",
	},
	Template = {
		Coins      = 0,
		Gems       = 0,
		Level      = 1,
		Experience = 0,
		Inventory  = {},
		Settings   = { Music = true, SFX = true },
		PlayTime   = 0,
		LastLogin  = 0,
		__version  = 1,
	},
}
