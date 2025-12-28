local utils = require("auto-dark-mode.utils")

-- Install helper script for OSC11 detection (SSH/remote sessions)
local function install_helper_script()
	local target = vim.fn.expand("~/.local/bin/query-terminal-bg")
	local target_dir = vim.fn.expand("~/.local/bin")

	-- Skip if already installed
	if vim.fn.executable(target) == 1 then
		return
	end

	-- Find the script in the plugin directory
	local source = debug.getinfo(1, "S").source:sub(2)
	local plugin_dir = vim.fn.fnamemodify(source, ":h:h:h")
	local script = plugin_dir .. "/scripts/query-terminal-bg"

	if vim.fn.filereadable(script) ~= 1 then
		return
	end

	-- Create target directory if needed
	if vim.fn.isdirectory(target_dir) == 0 then
		vim.fn.mkdir(target_dir, "p")
	end

	-- Copy and make executable
	vim.fn.system({ "cp", script, target })
	vim.fn.system({ "chmod", "+x", target })
end

---@type number
local timer_id
---@type boolean
local is_currently_dark_mode

---@type fun(): nil | nil
local set_dark_mode
---@type fun(): nil | nil
local set_light_mode

---@type number
local update_interval

---@type string
local query_command
---@type "Linux" | "Darwin" | "Windows_NT" | "WSL" | "OSC11"
local system

-- Query terminal background via OSC 11
-- Works over SSH/remote sessions by detecting terminal background color
---@param callback fun(is_dark_mode: boolean)
local function check_osc11_dark_mode(callback)
	-- Use helper script if available, otherwise use inline detection
	local script = vim.fn.expand("~/.local/bin/query-terminal-bg")
	if vim.fn.executable(script) == 1 then
		utils.start_job(script, {
			on_stdout = function(data)
				local response = (data[1] or ""):gsub("%s+", "")
				local is_dark = response == "dark"
				callback(is_dark)
			end,
		})
		return
	end

	-- Fallback: try to detect via terminfo or assume dark
	-- Most modern terminals support OSC 11, but reading response is tricky
	-- without a helper script that can handle TTY I/O properly
	callback(true)
end

-- Parses the query response for each system
---@param res string
---@return boolean
local function parse_query_response(res)
	if system == "LinuxLegacy" then
		-- https://github.com/flatpak/xdg-desktop-portal/blob/c0f0eb103effdcf3701a1bf53f12fe953fbf0b75/data/org.freedesktop.impl.portal.Settings.xml#L32-L46
		-- 0: no preference
		-- 1: dark
		-- 2: light
		return string.match(res, "uint32 1") ~= nil
	elseif system == "Linux" or system == "DockerLinux" or system == "RemoteLinux" then
		return string.match(res, "1") ~= nil
	elseif system == "Darwin" then
		return res == "Dark"
	elseif system == "Windows_NT" or system == "WSL" then
		-- AppsUseLightTheme    REG_DWORD    0x0 : dark
		-- AppsUseLightTheme    REG_DWORD    0x1 : light
		return string.match(res, "1") == nil
	end
	return false
end

---@param callback fun(is_dark_mode: boolean)
local function check_is_dark_mode(callback)
	if system == "OSC11" then
		check_osc11_dark_mode(callback)
	else
		utils.start_job(query_command, {
			on_stdout = function(data)
				-- we only care about the first line of the response
				local is_dark_mode = parse_query_response(data[1])
				callback(is_dark_mode)
			end,
		})
	end
end

---@param is_dark_mode boolean
local function change_theme_if_needed(is_dark_mode)
	if is_dark_mode == is_currently_dark_mode then
		return
	end

	is_currently_dark_mode = is_dark_mode
	if is_currently_dark_mode then
		set_dark_mode()
	else
		set_light_mode()
	end
end

local function start_check_timer()
	timer_id = vim.fn.timer_start(update_interval, function()
		check_is_dark_mode(change_theme_if_needed)
	end, { ["repeat"] = -1 })
end

local function init()
	-- Check for SSH/remote session first - use OSC 11 for terminal bg detection
	if os.getenv("SSH_TTY") or os.getenv("SSH_CONNECTION") then
		system = "OSC11"
		-- Auto-install helper script if needed
		install_helper_script()
	elseif string.match(vim.loop.os_uname().release, "WSL") then
		system = "WSL"
	elseif vim.fn.filereadable("/.dockerenv") == 1 then
		system = "Docker" .. vim.loop.os_uname().sysname
	elseif vim.fn.filereadable(vim.fn.expand("~/.color-scheme")) == 1 then
		-- File-based theme sync fallback
		system = "RemoteLinux"
	else
		system = vim.loop.os_uname().sysname
	end


	if system == "OSC11" then
		-- No external command needed, handled by check_osc11_dark_mode
		query_command = nil
	elseif system == "Darwin" then
		query_command = "defaults read -g AppleInterfaceStyle"
	elseif system == "Linux" then
		query_command = "dconf read /org/gnome/desktop/interface/color-scheme | grep 'prefer-dark' | wc -l"
	elseif system == "DockerLinux" or system == "RemoteLinux" then
		query_command = "cat ~/.color-scheme | grep 'prefer-dark' | wc -l"
	elseif system == "LinuxLegacy" then
		if not vim.fn.executable("dbus-send") then
			error([[
		`dbus-send` is not available. The Linux implementation of
		auto-dark-mode.nvim relies on `dbus-send` being on the `$PATH`.
	  ]])
		end

		query_command = table.concat({
			"dbus-send --session --print-reply=literal --reply-timeout=1000",
			"--dest=org.freedesktop.portal.Desktop",
			"/org/freedesktop/portal/desktop",
			"org.freedesktop.portal.Settings.Read",
			"string:'org.freedesktop.appearance'",
			"string:'color-scheme'",
		}, " ")
	elseif system == "Windows_NT" or system == "WSL" then
		-- Don't swap the quotes; it breaks the code
		query_command =
			'reg.exe Query "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize" /v AppsUseLightTheme | findstr.exe "AppsUseLightTheme"'
	else
		return
	end

	if query_command and vim.fn.has("unix") ~= 0 then
		if vim.loop.getuid() == 0 then
			query_command = "su - $SUDO_USER -c " .. query_command
		end
	end

	if type(set_dark_mode) ~= "function" or type(set_light_mode) ~= "function" then
		error([[

		Call `setup` first:

		require('auto-dark-mode').setup({
			set_dark_mode=function()
				vim.api.nvim_set_option_value('background', 'dark')
				vim.cmd('colorscheme gruvbox')
			end,
			set_light_mode=function()
				vim.api.nvim_set_option_value('background', 'light')
			end,
		})
		]])
	end

	check_is_dark_mode(change_theme_if_needed)
	start_check_timer()
end

local function disable()
	vim.fn.timer_stop(timer_id)
end

---@param options AutoDarkModeOptions
local function setup(options)
	options = options or {}

	---@param background string
	local function set_background(background)
		vim.api.nvim_set_option_value("background", background, {})
	end

	set_dark_mode = options.set_dark_mode or function()
		set_background("dark")
	end
	set_light_mode = options.set_light_mode or function()
		set_background("light")
	end
	update_interval = options.update_interval or 3000

	init()
end

return { setup = setup, init = init, disable = disable }
