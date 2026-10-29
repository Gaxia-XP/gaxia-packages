-- An error inside a task.spawn thread in a LocalScript: the script itself goes on.
local function explode(n: number)
	task.wait(1)
	error("client boom " .. n)
end

task.spawn(function()
	explode(7)
end)
print("the LocalScript keeps running")
