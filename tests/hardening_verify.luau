--!strict
-- Read-only SOURCE-SYNC smoke. Run in a privileged source-readable context.
-- Marker presence is NOT integration coverage or proof of correct behavior,
-- nor a byte-for-byte comparison against the checkout. No production requires,
-- module replacement, remote registration/deletion, flags, or config changes.
-- Encoder behavior is tested separately by remote_obfuscator.unit.luau through
-- scripts/test-hardening-local.py (no Studio, players, or cloud services).
-- Not covered: live RPC handlers/encode fallback, lifecycle races, detector
-- execution, enforcement decisions, /ac reset behavior, or Guild persistence.

local passed = 0
local failures: { string } = {}

local function check(condition: boolean, message: string): ()
	if condition then
		passed += 1
	else
		table.insert(failures, message)
		warn(`[SOURCE_SYNC] FAIL: {message}`)
	end
end

-- Paths contain strings only. Missing nodes fail synchronously instead of
-- yielding forever in WaitForChild. Source permission errors fail explicitly.
local function moduleSource(path: { string }): string?
	local node: Instance = game
	for _, name in ipairs(path) do
		local child = node:FindFirstChild(name)
		if child == nil then
			check(false, `missing source path: {table.concat(path, ".")}`)
			return nil
		end
		node = child
	end
	if not node:IsA("ModuleScript") then
		check(false, `not a ModuleScript: {table.concat(path, ".")}`)
		return nil
	end
	local ok, source = pcall(function(): string
		return (node :: ModuleScript).Source
	end)
	if not ok then
		check(false, `cannot read Source: {table.concat(path, ".")}: {source}`)
		return nil
	end
	check(true, `source readable: {table.concat(path, ".")}`)
	return source
end

local function markers(path: { string }, expected: { string }): ()
	local source = moduleSource(path)
	if source == nil then
		return
	end
	for _, marker in ipairs(expected) do
		check(
			string.find(source, marker, 1, true) ~= nil,
			`{table.concat(path, ".")} source contains {marker}`
		)
	end
end

markers({ "ReplicatedStorage", "Gaxia_Packages", "Shared", "NetService" }, {
	"player.Parent ~= Players",
	"state.active or player.Parent ~= Players",
})
markers({ "ReplicatedStorage", "Gaxia_Packages", "Shared", "RemoteObfuscator" }, {
	'if valueType == "function" or valueType == "thread" then',
	"cannot be sent through NetService",
})
markers({ "ServerStorage", "Gaxia_Packages_Server", "AntiCheat" }, {
	"script:GetChildren()",
	'EConfig.Clear("AntiCheat.Enforcement.Mode")',
	'evidenceSource ~= "server"',
	'and evidenceSource ~= "transport"',
	'and evidenceSource ~= "trap"',
})
markers({ "ServerStorage", "Gaxia_Packages_Server", "Lib", "GuildService" }, {
	"local function freshMembership(",
	"local function loadVaultFresh(",
	"local function validateCurrentGuild(",
})

print(`[SOURCE_SYNC] {passed} passed, {#failures} failed (source markers only; NOT integration)`)
if #failures > 0 then
	error("[SOURCE_SYNC] FAIL\n" .. table.concat(failures, "\n"), 0)
end
print("[SOURCE_SYNC]" .. " PASS")
