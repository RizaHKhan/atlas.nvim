---@class AtlasNotificationsState
---@field notifications AtlasNotification[]
---@field unread_count integer
---@field is_loading boolean
---@field error string|nil

local M = {}

---@type table<string, AtlasNotificationsState>
local by_provider = {}

---@param provider_id string
---@return AtlasNotificationsState
function M.get(provider_id)
	by_provider[provider_id] = by_provider[provider_id]
		or { notifications = {}, unread_count = 0, is_loading = false, error = nil }
	return by_provider[provider_id]
end

---@param provider_id string
---@param notifications AtlasNotification[]|nil
function M.set_notifications(provider_id, notifications)
	local record = M.get(provider_id)
	record.notifications = notifications or {}
	local unread = 0
	for _, n in ipairs(record.notifications) do
		if n.unread then
			unread = unread + 1
		end
	end
	record.unread_count = unread
end

---@param provider_id string
---@param id string
function M.mark_local_read(provider_id, id)
	local record = M.get(provider_id)
	for _, n in ipairs(record.notifications) do
		if n.id == id and n.unread then
			n.unread = false
			record.unread_count = math.max(0, record.unread_count - 1)
			return
		end
	end
end

---@param provider_id string
---@param id string
function M.remove_local(provider_id, id)
	local record = M.get(provider_id)
	for i, n in ipairs(record.notifications) do
		if n.id == id then
			if n.unread then
				record.unread_count = math.max(0, record.unread_count - 1)
			end
			table.remove(record.notifications, i)
			return
		end
	end
end

return M
