local M = {}

local config = require("atlas.config")

-- Eventually I'd like to just use vim.ui.input, snacks already overrides it when its input is enabled.
-- Could not get the completion working there yet tho, so for now snacks is checked directly and everything else uses the cmdline below.
---@return table|nil
local function snacks_input()
	local picker = config.options.ui.picker or "auto"
	if picker ~= "auto" and picker ~= "snacks" then
		return nil
	end
	local ok, Snacks = pcall(require, "snacks")
	if not ok or not (Snacks.config.input and Snacks.config.input.enabled) then
		return nil
	end
	return Snacks
end

-- I couldn not get completion to work without a real user command, but I also didn not want every providers prompt command showing up under `:Atlas<Tab>`.
-- This registers the command, feeds the cmdline to it, and deletes it once the cmdline closes.
---@param opts { name: string, prompt: string, complete: (fun(arglead: string, cmdline: string, cursorpos: integer): string[]), on_submit: (fun(query: string)), default: string|nil }
function M.open(opts)
	local Snacks = snacks_input()
	if Snacks then
		Snacks.input({
			prompt = opts.prompt,
			default = opts.default or "",
		}, function(query)
			if query then
				opts.on_submit(query)
			end
		end)
		return
	end

	local cmd_name = opts.name
	pcall(vim.api.nvim_del_user_command, cmd_name)

	local cleaned = false
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		pcall(vim.api.nvim_del_user_command, cmd_name)
	end

	vim.api.nvim_create_user_command(cmd_name, function(cmd_opts)
		cleanup()
		opts.on_submit(cmd_opts.args)
	end, {
		nargs = "*",
		complete = opts.complete,
	})

	vim.api.nvim_create_autocmd("CmdlineLeave", {
		once = true,
		callback = function()
			vim.schedule(cleanup)
		end,
	})

	local default = opts.default and tostring(opts.default) or ""
	local keys = vim.api.nvim_replace_termcodes(":" .. cmd_name .. " " .. default, true, false, true)
	vim.schedule(function()
		vim.api.nvim_feedkeys(keys, "n", false)
	end)
end

return M
