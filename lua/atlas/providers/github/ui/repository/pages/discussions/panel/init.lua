local resolver = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local discussions = require("atlas.providers.github.discussions")
local renderer = require("atlas.providers.github.ui.repository.pages.discussions.panel.renderer")
local editor = require("atlas.ui.popups.editor")
local help = require("atlas.ui.popups.help")
local icons = require("atlas.ui.shared.icons")
local reactions = require("atlas.ui.shared.reactions")
local utils = require("atlas.ui.shared.utils")

---@class GitHubDiscussionPanel
---@field win integer
---@field buf integer
---@field anchor integer
---@field repo AtlasRepositoryDetails
---@field statusline AtlasStatusline
---@field number integer
---@field discussion GitHubDiscussionDetails|"loading"|string
---@field expanded table<string, boolean>
---@field line_map table<integer, AtlasThreadLineMap>
---@field requests AtlasRequestScope
---@field group integer

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.repository.discussions.panel")

---@param win integer
local function configure(win)
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].cursorline = true
end

---@param panel GitHubDiscussionPanel
local function render(panel)
	if not utils.buffer.valid(panel.buf) or not utils.window.valid(panel.win) then
		return
	end

	local lines, spans, line_map =
		renderer.render(panel.discussion, panel.expanded, vim.api.nvim_win_get_width(panel.win))
	panel.line_map = line_map
	local winbar = ""
	if type(panel.discussion) == "table" then
		local bell, hl = icons.get("bell_no")
		if panel.discussion.subscribed then
			bell, hl = icons.get("bell"), "AtlasLogInfo"
		end

		winbar = string.format("%%=%%#%s#%s%%* ", hl, bell)
	end

	vim.wo[panel.win].winbar = winbar
	vim.bo[panel.buf].modifiable = true
	vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
	vim.bo[panel.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(panel.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		if span.line_hl_group then
			vim.api.nvim_buf_set_extmark(panel.buf, namespace, span.line, 0, { line_hl_group = span.line_hl_group })
		else
			vim.api.nvim_buf_set_extmark(panel.buf, namespace, span.line, span.start_col, {
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end
end

---@param panel GitHubDiscussionPanel
local function load(panel)
	panel.requests.cancel()
	panel.requests = requests.new()
	panel.discussion = "loading"
	panel.statusline:notify("loading", "Loading discussion...")
	render(panel)

	panel.requests.run(function(done)
		return discussions.fetch_discussion(panel.repo, panel.number, done)
	end, function(discussion, err)
		panel.statusline:clear_notice()
		panel.discussion = discussion or err or "Unable to load discussion"
		render(panel)
	end)
end

---@param panel GitHubDiscussionPanel
---@param root GitHubDiscussionComment|nil Top-level comment to reply to
---@param mention string|nil Author to mention in the reply
local function add_comment(panel, root, mention)
	local discussion = panel.discussion
	if type(discussion) ~= "table" then
		return
	end

	editor.open({
		key = root and ("discussion-comment-reply-" .. root.id) or ("discussion-comment-add-" .. discussion.number),
		completion = { context = { provider = "github", repository = panel.repo.full_name } },
		title = root and " Reply to Comment " or " Add Comment ",
		initial_text = mention and ("@" .. mention .. " "),
		width_ratio = 0.7,
		height_ratio = 0.5,
		on_save = function(text)
			if vim.trim(text) == "" then
				return
			end

			notify.loading(root and "Sending reply..." or "Adding comment...")
			discussions.add_comment(discussion, text, root, function(comment, err)
				if panel.discussion ~= discussion then
					return
				end

				if not comment then
					notify.error((root and "Reply" or "Add comment") .. " failed: " .. tostring(err))
					return
				end

				if root then
					table.insert(root.replies, comment)
					panel.expanded[root.id] = true
				else
					table.insert(discussion.thread, comment)
					discussion.comments = discussion.comments + 1
				end

				notify.success(root and "Reply added" or "Comment added", { timeout = 1200 })
				render(panel)
			end)
		end,
	})
end

---@param panel GitHubDiscussionPanel
---@param comment GitHubDiscussionComment
local function edit_comment(panel, comment)
	local discussion = panel.discussion
	if type(discussion) ~= "table" then
		return
	end

	editor.open({
		key = "discussion-comment-edit-" .. comment.id,
		completion = { context = { provider = "github", repository = panel.repo.full_name } },
		title = comment == discussion.description and " Edit Description " or " Edit Comment ",
		initial_text = comment.body,
		width_ratio = 0.7,
		height_ratio = 0.5,
		on_save = function(text)
			if vim.trim(text) == "" then
				return
			end

			notify.loading("Editing comment...")
			discussions.edit_comment(discussion, comment, text, function(_, err)
				if panel.discussion ~= discussion then
					return
				end

				if err then
					notify.error("Edit failed: " .. err)
					return
				end

				comment.body = text
				notify.success("Comment updated", { timeout = 1200 })
				render(panel)
			end)
		end,
	})
end

---@param list GitHubDiscussionComment[]
---@param comment GitHubDiscussionComment
local function remove(list, comment)
	for index, item in ipairs(list) do
		if item == comment then
			table.remove(list, index)
			return
		end
	end
end

---@param panel GitHubDiscussionPanel
---@param comment GitHubDiscussionComment
---@param root GitHubDiscussionComment Top-level comment of the thread
local function delete_comment(panel, comment, root)
	local discussion = panel.discussion
	if type(discussion) ~= "table" then
		return
	end

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end

		notify.loading("Deleting comment...")
		discussions.delete_comment(comment, function(_, err)
			if panel.discussion ~= discussion then
				return
			end

			if err then
				notify.error("Delete failed: " .. err)
				return
			end

			if comment == root and #root.replies > 0 then
				root.deleted = true
			else
				if comment ~= root then
					remove(root.replies, comment)
				end

				if comment == root or (root.deleted and #root.replies == 0) then
					remove(discussion.thread, root)
					discussion.comments = discussion.comments - 1
				end
			end

			notify.success("Comment deleted", { timeout = 1200 })
			render(panel)
		end)
	end)
end

---@param panel GitHubDiscussionPanel
local function setup_keymaps(panel)
	local items = {
		{
			key = resolver.resolve("ui.close"),
			desc = "Close discussion",
			callback = function()
				M.close(panel)
			end,
			index = 90,
		},
		{
			key = resolver.resolve("ui.toggle_panel"),
			desc = "Toggle discussion panel",
			callback = function()
				M.close(panel)
			end,
			index = 12,
		},
		{
			key = resolver.resolve("ui.toggle_fold"),
			desc = "Expand / collapse replies",
			callback = function()
				local entry = panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
				local root = entry and entry.root
				if root and #root.replies > 0 then
					panel.expanded[root.id] = not panel.expanded[root.id]
					render(panel)
				end
			end,
			index = 10,
		},
		{
			key = resolver.resolve("ui.comments.add"),
			desc = "Add comment",
			callback = function()
				add_comment(panel, nil, nil)
			end,
			index = 20,
		},
		{
			key = resolver.resolve("ui.comments.reply"),
			desc = "Reply to comment",
			callback = function()
				local entry = panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
				if entry and entry.root then
					add_comment(panel, entry.root, entry.subject and entry.subject.author)
				elseif entry and entry.subject then
					add_comment(panel, nil, nil)
				end
			end,
			index = 21,
		},
		{
			key = resolver.resolve("ui.comments.edit"),
			desc = "Edit comment",
			callback = function()
				local entry = panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
				if entry and entry.subject then
					edit_comment(panel, entry.subject)
				end
			end,
			index = 22,
		},
		{
			key = resolver.resolve("ui.delete"),
			desc = "Delete comment",
			callback = function()
				local entry = panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
				if entry and entry.root and entry.subject then
					delete_comment(panel, entry.subject, entry.root)
				end
			end,
			index = 24,
		},
		{
			key = resolver.resolve("ui.comments.react"),
			desc = "Add reaction",
			callback = function()
				local entry = panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
				local discussion = panel.discussion
				if entry and entry.subject and type(discussion) == "table" then
					reactions.pick(discussions.reactions, discussion, entry.subject, function()
						return panel.discussion == discussion
					end, function()
						render(panel)
					end)
				end
			end,
			index = 23,
		},
		{
			key = { "gu" },
			desc = "Toggle upvote",
			callback = function()
				local entry = panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
				local discussion = panel.discussion
				if not (entry and entry.subject and type(discussion) == "table") then
					return
				end

				local subject = entry.subject
				notify.loading(subject.upvoted and "Removing upvote..." or "Upvoting...")
				discussions.toggle_upvote(subject, function(_, err)
					if panel.discussion ~= discussion then
						return
					end

					if err then
						notify.error("Upvote failed: " .. err)
						return
					end

					subject.upvotes = subject.upvotes + (subject.upvoted and -1 or 1)
					subject.upvoted = not subject.upvoted
					notify.success(subject.upvoted and "Upvoted" or "Upvote removed", { timeout = 1200 })
					render(panel)
				end)
			end,
			index = 25,
		},
		{
			key = { "ga" },
			desc = "Mark / unmark answer",
			callback = function()
				local entry = panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
				local discussion = panel.discussion
				if not (entry and entry.subject and entry.subject == entry.root and type(discussion) == "table") then
					return
				end

				if not discussion.category.answerable then
					notify.warn("Answers are only available in answerable categories")
					return
				end

				local comment = entry.subject
				notify.loading(comment.answer and "Unmarking answer..." or "Marking answer...")
				discussions.toggle_answer(comment, function(_, err)
					if panel.discussion ~= discussion then
						return
					end

					if err then
						notify.error("Answer failed: " .. err)
						return
					end

					local answer = not comment.answer
					for _, item in ipairs(discussion.thread) do
						item.answer = false
					end

					comment.answer = answer
					discussion.answered = answer
					notify.success(answer and "Marked as answer" or "Answer unmarked", { timeout = 1200 })
					render(panel)
				end)
			end,
			index = 26,
		},
		{
			key = resolver.resolve("ui.refresh"),
			desc = "Refresh discussion",
			callback = function()
				load(panel)
			end,
			index = 80,
		},
		{
			key = resolver.resolve("ui.open_in_browser"),
			desc = "Open discussion in browser",
			callback = function()
				if type(panel.discussion) == "table" then
					vim.ui.open(panel.discussion.url)
				end
			end,
			index = 4,
		},
		{
			key = resolver.resolve("ui.copy_url"),
			desc = "Copy discussion URL",
			callback = function()
				if type(panel.discussion) == "table" then
					vim.fn.setreg("+", panel.discussion.url)
					notify.success("Copied URL")
				end
			end,
			index = 9,
		},
	}

	for _, item in ipairs(items) do
		item.opts = { silent = true, nowait = true }
	end

	help.register("General", items, { buffer = panel.buf, index = 1 })
end

---@param opts { anchor: integer, repo: AtlasRepositoryDetails, statusline: AtlasStatusline, number: integer }
---@return GitHubDiscussionPanel
local function create(opts)
	local tab = vim.api.nvim_get_current_tabpage()
	local buf = utils.buffer.create("atlas://repository/" .. tab .. "/discussion", "atlas-ui.detail")
	vim.bo[buf].bufhidden = "wipe"
	local win = utils.window.create(opts.anchor, "botright vsplit", buf, configure)
	pcall(vim.api.nvim_win_set_width, win, math.max(math.floor(vim.o.columns * 0.45), 40))
	opts.statusline:attach(win)

	---@type GitHubDiscussionPanel
	local panel = {
		win = win,
		buf = buf,
		anchor = opts.anchor,
		repo = opts.repo,
		statusline = opts.statusline,
		number = opts.number,
		discussion = "loading",
		expanded = {},
		line_map = {},
		requests = requests.new(),
		group = vim.api.nvim_create_augroup("AtlasRepositoryDiscussionPanel" .. buf, { clear = true }),
	}

	setup_keymaps(panel)
	vim.api.nvim_create_autocmd("WinResized", {
		group = panel.group,
		callback = function()
			if vim.tbl_contains(vim.v.event.windows, panel.win) then
				render(panel)
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = panel.group,
		pattern = tostring(win),
		once = true,
		callback = function()
			M.close(panel)
		end,
	})

	return panel
end

---@param panel GitHubDiscussionPanel|nil
---@param opts { anchor: integer, repo: AtlasRepositoryDetails, statusline: AtlasStatusline, number: integer }
---@return GitHubDiscussionPanel
function M.open(panel, opts)
	if panel and utils.window.valid(panel.win) then
		panel.number = opts.number
		panel.expanded = {}
	else
		panel = create(opts)
	end

	vim.api.nvim_set_current_win(panel.win)
	load(panel)
	return panel
end

---@param panel GitHubDiscussionPanel|nil
function M.close(panel)
	if not panel or not panel.group then
		return
	end

	local group = panel.group
	panel.group = nil
	panel.requests.cancel()
	panel.statusline:clear_notice()
	vim.api.nvim_del_augroup_by_id(group)
	if utils.window.valid(panel.win) then
		vim.api.nvim_win_close(panel.win, true)
	end

	if utils.window.valid(panel.anchor) then
		vim.api.nvim_set_current_win(panel.anchor)
	end
end

return M
