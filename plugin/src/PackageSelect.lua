--!strict
-- ─────────────────────────────────────────────────────────────
-- PackageSelect.lua
-- Location: plugin/src/PackageSelect
-- Purpose : The Companion's side of Packages.lua (the package catalogue in
--           Gaxia_Packages_Server): resolve a pick to the packages it installs
--           (the pick + everything it Requires + Core), and prune a cloned
--           package root down to them.
--
--           Mirrors tools/packages.mjs (closure / keptPaths / pruneTypeLines),
--           which does the same for Rojo projects — keep the two in step.
-- ─────────────────────────────────────────────────────────────

local PackageSelect = {}

-- Attribute recording the pick on both package roots; the server loader boots
-- the picked services plus every installed package that has Boot = true.
PackageSelect.ATTRIBUTE = "GaxiaPackages"

export type Spec = {
	Name: string,
	Category: string,
	Description: string,
	Boot: boolean?,
	Server: { string }?,
	Replicated: { string }?,
	Requires: { string },
}
export type Manifest = {
	Core: { Server: { string }, Replicated: { string } },
	Presets: { [string]: { string } },
	Packages: { Spec },
}
export type Side = "Server" | "Replicated"
export type Kept = { Server: { string }, Replicated: { string } }

-- The catalogue bundled in the plugin's Payload (nil + reason when unusable).
function PackageSelect.loadManifest(payload: Instance): (Manifest?, string?)
	local server = payload:FindFirstChild("Gaxia_Packages_Server")
	local mod = server and server:FindFirstChild("Packages")
	if not (mod and mod:IsA("ModuleScript")) then
		return nil, "the bundled Gaxia has no Packages catalogue (rebuild the plugin)"
	end
	local ok, result = pcall(require, mod)
	if not ok or type(result) ~= "table" or type(result.Packages) ~= "table" then
		return nil, "could not read Packages: " .. tostring(result)
	end
	return result :: Manifest, nil
end

-- The packages a pick installs, in catalogue order, plus any unknown names.
function PackageSelect.closure(manifest: Manifest, picked: { string }): ({ string }, { string })
	local byName: { [string]: Spec } = {}
	for _, spec in ipairs(manifest.Packages) do
		byName[spec.Name] = spec
	end
	local seen: { [string]: boolean } = {}
	local unknown: { string } = {}
	local stack: { string } = {}
	for _, name in ipairs(picked) do
		if byName[name] then
			table.insert(stack, name)
		else
			table.insert(unknown, name)
		end
	end
	while #stack > 0 do
		local name = table.remove(stack) :: string
		if not seen[name] then
			seen[name] = true
			for _, dep in ipairs(byName[name].Requires) do
				table.insert(stack, dep)
			end
		end
	end
	local installed: { string } = {}
	for _, spec in ipairs(manifest.Packages) do
		if seen[spec.Name] then
			table.insert(installed, spec.Name)
		end
	end
	return installed, unknown
end

-- Module paths (per package root) an install keeps: Core + every installed package.
function PackageSelect.keptPaths(manifest: Manifest, installed: { string }): Kept
	local kept: Kept = { Server = table.clone(manifest.Core.Server), Replicated = table.clone(manifest.Core.Replicated) }
	local set: { [string]: boolean } = {}
	for _, name in ipairs(installed) do
		set[name] = true
	end
	for _, spec in ipairs(manifest.Packages) do
		if set[spec.Name] then
			for _, p in ipairs(spec.Server or {}) do
				table.insert(kept.Server, p)
			end
			for _, p in ipairs(spec.Replicated or {}) do
				table.insert(kept.Replicated, p)
			end
		end
	end
	return kept
end

local function isKept(kept: { string }, path: string): boolean
	for _, k in ipairs(kept) do
		if path == k or string.sub(path, 1, #k + 1) == k .. "/" then
			return true
		end
	end
	return false
end

-- Drop each `typeof(require(script.X.Y))` type line whose module is not installed,
-- so the loader's autocomplete type lists only installed modules (and does not
-- reference missing ones).
function PackageSelect.pruneTypeLines(source: string, kept: { string }): string
	local out: { string } = {}
	for _, line in ipairs(string.split(source, "\n")) do
		local target = string.match(line, "typeof%(require%(script%.([%w_%.]+)%)%)")
		if target == nil or isKept(kept, (string.gsub(target, "%.", "/"))) then
			table.insert(out, line)
		end
	end
	return table.concat(out, "\n")
end

-- True when `path` under `root` is a module, or a folder holding modules (prune
-- keeps folders, so an empty one means the package is not installed).
local function hasPath(root: Instance, path: string): boolean
	local node: Instance? = root
	for _, part in ipairs(string.split(path, "/")) do
		node = if node then node:FindFirstChild(part) else nil
	end
	if node == nil then
		return false
	end
	return node:IsA("ModuleScript") or node:FindFirstChildWhichIsA("ModuleScript", true) ~= nil
end

-- The packages whose modules are all present under the given package roots (what
-- a place has installed, whether or not a pick was recorded).
function PackageSelect.installedIn(manifest: Manifest, serverRoot: Instance?, replicatedRoot: Instance?): { string }
	local out: { string } = {}
	for _, spec in ipairs(manifest.Packages) do
		local present = true
		for _, p in ipairs(spec.Server or {}) do
			present = present and serverRoot ~= nil and hasPath(serverRoot, p)
		end
		for _, p in ipairs(spec.Replicated or {}) do
			present = present and replicatedRoot ~= nil and hasPath(replicatedRoot, p)
		end
		if present then
			table.insert(out, spec.Name)
		end
	end
	return out
end

-- Destroy every ModuleScript under `root` whose path is not kept (a kept module
-- keeps its children). Folders stay, so the loaders find Lib / Shared / Client /
-- Client.UI even when nothing in them is installed. Returns the number removed.
function PackageSelect.prune(root: Instance, kept: { string }): number
	local removed = 0
	local function visit(parent: Instance, prefix: string)
		for _, child in ipairs(parent:GetChildren()) do
			local path = if prefix == "" then child.Name else prefix .. "/" .. child.Name
			if child:IsA("ModuleScript") then
				if isKept(kept, path) then
					continue -- kept with everything under it
				end
				child:Destroy()
				removed += 1
			else
				visit(child, path)
			end
		end
	end
	visit(root, "")
	return removed
end

return PackageSelect
