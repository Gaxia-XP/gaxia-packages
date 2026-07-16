--!strict
-- ─────────────────────────────────────────────────────────────
-- Serializer.lua
-- Location: plugin/src/Serializer
-- Purpose : Walk a selection of GUI instances and produce themed,
--           imperative Luau that rebuilds them. Property values come
--           from Reflection.diff (non-default only). Color3 values
--           run through ThemeBridge for token substitution. Output
--           is either a reusable ModuleScript (returning a build
--           function) or a bare statement block.
-- ─────────────────────────────────────────────────────────────

local Reflection  = require(script.Parent:WaitForChild("Reflection"))   :: any
local LuauWriter  = require(script.Parent:WaitForChild("LuauWriter"))   :: any
local ThemeBridge = require(script.Parent:WaitForChild("ThemeBridge"))  :: any

local Serializer = {}

-- ── Identifier helpers ──────────────────────────────────────

local KEYWORDS: { [string]: boolean } = {
	["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true, ["elseif"]=true,
	["end"]=true, ["false"]=true, ["for"]=true, ["function"]=true, ["if"]=true,
	["in"]=true, ["local"]=true, ["nil"]=true, ["not"]=true, ["or"]=true,
	["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true, ["until"]=true,
	["while"]=true, ["continue"]=true,
}

local function sanitizeIdent(name: string, classFallback: string): string
	local clean = name:gsub("[^%w_]", "")
	if clean == "" or tonumber(clean:sub(1, 1)) ~= nil or KEYWORDS[clean] then
		clean = classFallback .. (clean ~= "" and "_" .. clean or "")
	end
	return clean
end

local function isUIClass(class: string): boolean
	if Reflection.isKnown(class) then return true end
	if class:sub(1, 2) == "UI" then return true end
	return false
end

-- Script classes are serialised with their .Source (not GUI props). They are
-- emitted only when NOT in the skip-set (see Opts.skip); by default they ARE
-- skipped, matching the "freeze UI, not behaviour" intent.
local SCRIPT_CLASSES: { [string]: boolean } = {
	LocalScript = true, ModuleScript = true, Script = true,
}

-- A class the Serializer knows how to reproduce (before the skip-set is applied).
local function isHandled(class: string): boolean
	return isUIClass(class) or SCRIPT_CLASSES[class] == true
end

-- ── Per-instance emit ───────────────────────────────────────

local function emitInstance(w: any, inst: Instance, varName: string, parentVar: string?, ctx: any): ()
	local class = inst.ClassName
	w:line(string.format("local %s = Instance.new(\"%s\")", varName, class))

	if SCRIPT_CLASSES[class] then
		-- Scripts: Name (if non-default) + Source. The GUI property diff does not apply.
		if inst.Name ~= class then
			w:line(string.format("%s.Name = %s", varName, LuauWriter.value(inst.Name)))
		end
		local ok, src = pcall(function() return (inst :: any).Source end)
		if ok and typeof(src) == "string" and #src > 0 then
			w:line(string.format("%s.Source = %s", varName, LuauWriter.longString(src)))
		end
	else
		for _, entry in ipairs(Reflection.diff(inst)) do
			local valueLit: string
			if ctx.useTokens and typeof(entry.value) == "Color3" then
				local token = ctx.themed:match(entry.value)
				if token then
					valueLit = string.format("Theme.Color(\"%s\")", token)
				else
					valueLit = LuauWriter.value(entry.value)
				end
			else
				valueLit = LuauWriter.value(entry.value)
			end
			w:line(string.format("%s.%s = %s", varName, entry.name, valueLit))
		end
	end

	for _, attr in ipairs(Reflection.attributes(inst)) do
		w:line(string.format("%s:SetAttribute(\"%s\", %s)",
			varName, attr.name, LuauWriter.value(attr.value)))
	end
	if parentVar then
		w:line(string.format("%s.Parent = %s", varName, parentVar))
	end
end

-- ── DFS ─────────────────────────────────────────────────────

type WalkCtx = {
	used: { [string]: number },
	themed: any,
	useTokens: boolean,
	skip: { [string]: boolean },
}

local function uniqueVar(ctx: WalkCtx, baseName: string, classFallback: string): string
	local clean = sanitizeIdent(baseName, classFallback)
	local count = ctx.used[clean]
	if count then
		ctx.used[clean] = count + 1
		return clean .. tostring(count + 1)
	end
	ctx.used[clean] = 1
	return clean
end

local function walk(w: any, inst: Instance, parentVar: string?, ctx: WalkCtx): string?
	local class = inst.ClassName
	-- Skip when the user opted to skip this class, or when we don't know how to
	-- reproduce it. Skipped nodes are NOT recursed into.
	if ctx.skip[class] or not isHandled(class) then
		w:line(string.format("-- skipped: %s (%s)", inst.Name, class))
		return nil
	end
	local varName = uniqueVar(ctx, inst.Name, class)
	emitInstance(w, inst, varName, parentVar, ctx)
	for _, child in ipairs(inst:GetChildren()) do
		walk(w, child, varName, ctx)
	end
	return varName
end

-- ── Public ──────────────────────────────────────────────────

export type Opts = { tokens: boolean?, asModule: boolean?, skip: { [string]: boolean }? }

function Serializer.toScript(roots: { Instance }, opts: Opts?): string
	opts = opts or {}
	local useTokens = opts.tokens ~= false   -- default true
	local asModule  = opts.asModule ~= false -- default true

	local themed = ThemeBridge.new()
	local body = LuauWriter.new()
	local ctx: WalkCtx = { used = {}, themed = themed, useTokens = useTokens, skip = opts.skip or {} }

	if asModule then
		body:indent()
	end
	for _, root in ipairs(roots) do
		walk(body, root, "parent", ctx)
	end
	if asModule then
		body:dedent()
	end

	-- Header: Theme require if tokens were actually used.
	local header = LuauWriter.new()
	if useTokens and #themed:tokensUsed() > 0 then
		header:line("local RS = game:GetService(\"ReplicatedStorage\")")
		header:line(
			"local Theme = require(RS:WaitForChild(\"Gaxia_Packages\"):WaitForChild(\"Shared\"):WaitForChild(\"Theme\"))"
		)
		header:line("")
	end

	if asModule then
		local final = LuauWriter.new()
		final:line("--!strict")
		final:line(header:tostring())
		final:line("return function(parent)")
		final:line(body:tostring())
		final:line("end")
		return final:tostring()
	end
	return header:tostring() .. (header:tostring() ~= "" and "\n" or "") .. body:tostring()
end

return Serializer
