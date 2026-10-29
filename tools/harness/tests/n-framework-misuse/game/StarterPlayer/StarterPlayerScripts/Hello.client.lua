local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

task.spawn(function()
	task.wait(1)
	Gaxia.UI.Toast.Show("Welcome!") -- BUG: Show takes a table { Text = ... }
end)
