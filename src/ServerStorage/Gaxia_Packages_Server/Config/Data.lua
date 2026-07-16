--!strict
-- Config/Data.lua — Data / persistence (DataManager) tunables
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
}
