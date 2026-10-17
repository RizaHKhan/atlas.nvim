local resolver = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local discussions = require("atlas.providers.github.discussions")
local panel = require("atlas.providers.github.ui.repository.pages.discussions.panel")
local renderer = require("atlas.providers.github.ui.repository.pages.discussions.renderer")
local spinner = require("atlas.ui.components.spinner")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local emojis = require("atlas.ui.shared.emojis")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryDiscussions
---@field buf integer
---@field win integer
---@field sidebar_buf integer
---@field repo AtlasRepositoryDetails
---@field statusline AtlasStatusline
---@field discussions GitHubDiscussion[]|"loading"|string
---@field filter "open"|"closed"
---@field counts { open: integer, closed: integer }
---@field category GitHubDiscussionCategory|nil
---@field categories GitHubDiscussionCategory[]
---@field page integer
---@field cursors table<integer, string>
---@field next_cursor string|nil
---@field line_map table<integer, GitHubDiscussion>
---@field panel GitHubDiscussionPanel|nil
---@field requests AtlasRequestScope
---@field spinner SpinnerInstance
---@field group integer
---@field keymaps table<integer, table<string, AtlasHelpKeyItem[]>>

local M = { key = "discussions", label = "Discussions", icon = icons.get("conversation") }
local namespace = vim.api.nvim_create_namespace("atlas.repository.discussions")
---@type table<integer, RepositoryDiscussions>
local states = {}

---@param state RepositoryDiscussions
---@return GitHubDiscussion|nil
local function current(state)
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

---@param state RepositoryDiscussions
local function render(state)
	if not utils.buffer.valid(state.buf) or not utils.window.valid(state.win) then
		return
	end

	state.line_map = {}
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)

	local items = state.discussions
	if type(items) == "string" then
		local message = items == "loading" and state.spinner:text("Loading discussions...") or items
		utils.buffer.center_message(state.buf, state.win, message)
		vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
			end_row = vim.api.nvim_buf_line_count(state.buf),
			line_hl_group = items == "loading" and "Normal" or "AtlasLogError",
		})

		return
	end

	local lines, line_map, spans = renderer.render(state, vim.api.nvim_win_get_width(state.win))
	state.line_map = line_map
	if #items == 0 then
		utils.buffer.center_message(state.buf, state.win, "No " .. state.filter .. " discussions found", lines)
	else
		vim.bo[state.buf].modifiable = true
		vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
		vim.bo[state.buf].modifiable = false
	end

	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, span.line, span.start_col or 0, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

---@param state RepositoryDiscussions
local function load(state)
	state.requests.cancel()
	state.requests = requests.new()
	state.discussions = "loading"
	state.next_cursor = nil
	state.spinner:start()
	state.statusline:notify("loading", "Loading discussions...")
	render(state)

	state.requests.run(function(done)
		return discussions.fetch(state.repo, {
			state = state.filter,
			category = state.category and state.category.id,
			cursor = state.cursors[state.page],
		}, done)
	end, function(page, err)
		state.spinner:stop()
		state.statusline:clear_notice()
		if not page then
			state.discussions = err or "Unable to load discussions"
			render(state)
			return
		end

		state.discussions = page.items
		state.counts = page.counts
		state.categories = page.categories
		state.next_cursor = page.next_cursor
		render(state)
		if #page.items > 0 and utils.window.valid(state.win) then
			vim.api.nvim_win_set_cursor(state.win, { 3, 0 })
		end
	end)
end

---@param state RepositoryDiscussions
local function select_category(state)
	if #state.categories == 0 then
		return
	end

	local all = { name = "All categories" }
	local items, selected = { all }, 1
	for index, category in ipairs(state.categories) do
		table.insert(items, category)
		if state.category and state.category.id == category.id then
			selected = index + 1
		end
	end

	picker.select({
		title = "Discussion categories",
		items = items,
		initial_index = selected,
		format_item = function(category)
			if category == all then
				return icons.get("conversation") .. "  " .. all.name
			end

			return emojis.get(category.emoji) .. "  " .. category.name
		end,
		on_select = function(category)
			if not category or states[state.buf] ~= state then
				return
			end

			state.category = nil
			if category ~= all then
				state.category = category
			end

			state.page, state.cursors = 1, {}
			load(state)
		end,
	})
end

---@param state RepositoryDiscussions
---@param number integer
local function open_panel(state, number)
	state.panel = panel.open(state.panel, {
		anchor = state.win,
		repo = state.repo,
		statusline = state.statusline,
		number = number,
	})
end

---@param state RepositoryDiscussions
local function setup_keymaps(state)
	local actions = {
		{
			key = resolver.resolve("ui.refresh"),
			desc = "Refresh discussions",
			callback = function()
				state.page, state.cursors = 1, {}
				load(state)
			end,
			index = 80,
		},
		{
			key = { "t" },
			desc = "Toggle open/closed discussions",
			group = "Filters",
			callback = function()
				state.filter = state.filter == "open" and "closed" or "open"
				state.page, state.cursors = 1, {}
				load(state)
			end,
			index = 10,
		},
		{
			key = { "c" },
			desc = "Filter by category",
			group = "Filters",
			callback = function()
				select_category(state)
			end,
			index = 11,
		},
		{
			key = resolver.resolve("ui.next_page"),
			desc = "Next discussions",
			callback = function()
				if state.discussions == "loading" or not state.next_cursor then
					return
				end

				state.page = state.page + 1
				state.cursors[state.page] = state.next_cursor
				load(state)
			end,
			index = 16,
		},
		{
			key = resolver.resolve("ui.previous_page"),
			desc = "Previous discussions",
			callback = function()
				if state.discussions ~= "loading" and state.page > 1 then
					state.page = state.page - 1
					load(state)
				end
			end,
			index = 15,
		},
	}

	---@param buf integer
	local function register(buf)
		local groups = { General = {}, Filters = {} }
		for _, action in ipairs(actions) do
			if action.key and #action.key > 0 then
				table.insert(groups[action.group or "General"], {
					key = action.key,
					desc = action.desc,
					index = action.index,
					callback = action.callback,
					opts = { silent = true, nowait = true },
				})
			end
		end

		state.keymaps[buf] = groups
		help.register("General", groups.General, { buffer = buf, index = 1 })
		help.register("Filters", groups.Filters, { buffer = buf, index = 2 })
	end

	register(state.sidebar_buf)

	table.insert(actions, {
		key = vim.list_extend(resolver.resolve("ui.select") or {}, resolver.resolve("ui.toggle_panel") or {}),
		desc = "Open discussion",
		callback = function()
			local discussion = current(state)
			if discussion then
				open_panel(state, discussion.number)
			end
		end,
		index = 1,
	})

	table.insert(actions, {
		key = resolver.resolve("ui.open_in_browser"),
		desc = "Open discussion in browser",
		callback = function()
			local discussion = current(state)
			if discussion and discussion.url ~= "" then
				vim.ui.open(discussion.url)
			end
		end,
		index = 4,
	})

	table.insert(actions, {
		key = resolver.resolve("ui.copy_url"),
		desc = "Copy discussion URL",
		callback = function()
			local discussion = current(state)
			if discussion and discussion.url ~= "" then
				vim.fn.setreg("+", discussion.url)
				notify.success("Copied URL")
			end
		end,
		index = 9,
	})

	register(state.buf)
end

---@param opts { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline, ctx: { number?: integer } }
function M.open(opts)
	---@type RepositoryDiscussions
	local state = {
		buf = opts.buf,
		win = opts.win,
		sidebar_buf = opts.sidebar_buf,
		repo = opts.repo,
		statusline = opts.statusline,
		discussions = "loading",
		filter = "open",
		counts = { open = 0, closed = 0 },
		categories = {},
		page = 1,
		cursors = {},
		line_map = {},
		requests = requests.new(),
		spinner = spinner.create(),
		group = vim.api.nvim_create_augroup("AtlasRepositoryDiscussions" .. opts.buf, { clear = true }),
		keymaps = {},
	}

	states[state.buf] = state
	state.spinner.on_tick = function()
		if state.spinner:is_running() then
			render(state)
		end
	end

	vim.wo[state.win].cursorline = true
	vim.wo[state.win].wrap = false

	setup_keymaps(state)

	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = state.group,
		callback = function(event)
			if event.event == "VimResized" or vim.tbl_contains(vim.v.event.windows, state.win) then
				render(state)
			end
		end,
	})

	load(state)
	if opts.ctx.number then
		open_panel(state, opts.ctx.number)
	end
end

---@param buf integer
function M.close(buf)
	local state = states[buf]
	if not state then
		return
	end

	states[buf] = nil
	panel.close(state.panel)
	state.requests.cancel()
	state.spinner:stop()
	state.statusline:clear_notice()
	vim.api.nvim_del_augroup_by_id(state.group)
	for buffer, groups in pairs(state.keymaps) do
		for group, items in pairs(groups) do
			help.remove(group, items, { buffer = buffer })
		end
	end

	if utils.window.valid(state.win) then
		vim.wo[state.win].cursorline = false
	end

	if utils.buffer.valid(state.buf) then
		vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	end
end

return M
