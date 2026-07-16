--!strict
-- ─────────────────────────────────────────────────────────────
-- Gaxia Companion — plugin entry
-- Toolbar + dock widget + wiring for the converter engines.
-- When loaded via the dev-sync mount (plugin == nil), this returns
-- without registering a toolbar so the place is unaffected.
-- ─────────────────────────────────────────────────────────────

if plugin == nil then return end

local Selection = game:GetService("Selection")

local Serializer = require(script:WaitForChild("Serializer")) :: any
local Runner     = require(script:WaitForChild("Runner"))     :: any
local Installer  = require(script:WaitForChild("Installer"))  :: any
local Panel      = require(script:WaitForChild("Panel"))      :: any

-- ── Toolbar + dock widget ──
local toolbar = plugin:CreateToolbar("Gaxia")
local toggle = toolbar:CreateButton("Companion", "Open the Gaxia Companion widget", "")

local info = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float, false, false, 360, 520, 320, 420
)
local widget = plugin:CreateDockWidgetPluginGui("GaxiaCompanion_Widget", info)
widget.Title = "Gaxia Companion"

toggle.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	toggle:SetActive(widget.Enabled)
end)

-- ── Callbacks scaffolding (Panel fills the getters/setters in) ──
local cb: any = {}
local handle = Panel.create(widget, cb)

local function safe(label: string, fn: () -> ()): ()
	local ok, err = pcall(fn)
	if not ok then
		handle.setStatus(string.format("✗ %s error: %s", label, tostring(err)), "err")
	end
end

-- ── Skip settings (persisted per-plugin across sessions) ──
-- Default: keep Folders (they group UI), skip the three script classes
-- (the converter freezes UI, not behaviour). The user flips these in the
-- Settings tab; the choice is remembered via plugin:SetSetting.
local SKIP_DEFAULTS: { [string]: boolean } = {
	Folder = false, LocalScript = true, ModuleScript = true, Script = true,
}
local skipSet: { [string]: boolean } = {}
for class, default in pairs(SKIP_DEFAULTS) do
	local saved = plugin:GetSetting("skip_" .. class)
	local value = if typeof(saved) == "boolean" then saved else default
	skipSet[class] = value
	handle.setSkip(class, value) -- reflect persisted state in the toggle visuals
end

function cb.onSkipToggle(class: string, skip: boolean)
	skipSet[class] = skip
	plugin:SetSetting("skip_" .. class, skip)
	handle.setStatus(string.format("%s will be %s", class, skip and "skipped" or "kept"), "ok")
end

-- ── Convert: Instance → Script ──
function cb.onSelectionToScript()
	safe("Convert", function()
		local sel = Selection:Get()
		if #sel == 0 then
			handle.setStatus("✗ Select one or more GuiObjects first", "err")
			return
		end
		local out = Serializer.toScript(sel, { tokens = true, asModule = true, skip = skipSet })
		cb.setOutputText(out)
		handle.setStatus(string.format("✓ Converted %d root(s)", #sel), "ok")
	end)
end

-- Drop the converted output into the place as a ModuleScript under StarterGui.
function cb.onInsertModule()
	safe("Insert", function()
		local text = cb.getOutputText()
		if text == "" then
			handle.setStatus("✗ Nothing to insert — convert first", "err")
			return
		end
		local m = Instance.new("ModuleScript")
		m.Name = "GaxiaConverted"
		m.Source = text
		m.Parent = game:GetService("StarterGui")
		Selection:Set({m})
		handle.setStatus("✓ Inserted as StarterGui.GaxiaConverted", "ok")
	end)
end

-- ── Build: Script → Instance ──
function cb.onUseSelectedModule()
	safe("Use selected", function()
		local sel = Selection:Get()
		local mod = sel[1]
		if not (mod and mod:IsA("ModuleScript")) then
			handle.setStatus("✗ Select a ModuleScript first", "err")
			return
		end
		cb.setInputText((mod :: ModuleScript).Source)
		handle.setStatus("✓ Loaded source from " .. mod.Name, "ok")
	end)
end

function cb.onScriptToInstance()
	safe("Run", function()
		local src = cb.getInputText()
		if src == "" then
			-- Fall through to the output box (the script we just converted).
			src = cb.getOutputText()
		end
		if src == "" then
			handle.setStatus("✗ No source — paste a UI Script or convert first", "err")
			return
		end
		local target = Selection:Get()[1] or game:GetService("StarterGui")
		local ok, result = Runner.run(src, target)
		if not ok then
			handle.setStatus("✗ Build error: " .. tostring(result), "err")
			return
		end
		if typeof(result) == "Instance" then
			Selection:Set({result})
		end
		handle.setStatus("✓ Built and parented under " .. target:GetFullName(), "ok")
	end)
end

-- ── Install ──
function cb.onInstall()
	safe("Install", function()
		local ok, msg = Installer.install({ confirm = false })
		handle.setStatus((ok and "✓ " or "✗ ") .. tostring(msg), ok and "ok" or "err")
	end)
end

print("[GaxiaCompanion] ready")
