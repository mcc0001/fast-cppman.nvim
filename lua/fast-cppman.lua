local Input = require("nui.input")
local event = require("nui.utils.autocmd").event
local Popup = require("nui.popup")
local uv = vim.loop

local M = {}

-- Default configuration
M.config = {
	max_prefetch_options = 10,
	max_width = 100,
	max_height = 30,
	min_height = 5,
	input_width = 20,
	enable_async = true,
	max_async_jobs = 5,
	history_mode = "manpage",
	position = "cursor",
}

local state = {
	stack = {},
	forward_stack = {},
	current_page = nil,
	current_buf = nil,
	current_win = nil,
	cache = {},
	async_jobs = {},
	async_queue = {},
	buffer_counter = 0,
	initial_cursor = {
		top = 0,
		left = 0,
		row = 0,
		col = 0,
	},
}

-- Calculate optimal window size and position
local function calculate_window_size_and_position(content_lines, max_width, max_height, min_height)
	local ui = vim.api.nvim_list_uis()[1] or { width = vim.o.columns, height = vim.o.lines }
	-- Use stored initial cursor position
	local top = state.initial_cursor.top
	local left = state.initial_cursor.left
	local cur_row = state.initial_cursor.row
	local cur_col = state.initial_cursor.col

	-- Convert to 0-based editor grid coordinates
	local abs_row = (top - 1) + (cur_row - 1)
	local abs_col = (left - 1) + cur_col
	-- Calculate content height
	local content_height = #content_lines
	local border_height = 2 -- top and bottom border
	local inner_height = math.min(max_height, math.max(min_height, content_height))
	local total_height = inner_height + border_height

	-- Calculate available space below and above cursor
	local space_below = ui.height - (abs_row + 1)
	local space_above = abs_row

	-- Determine position (below or above cursor)
	local position_below = space_below >= total_height or space_below >= space_above
	local row

	if position_below then
		row = abs_row + 1
		-- Adjust height if not enough space below
		if space_below < total_height then
			inner_height = math.min(max_height, math.max(min_height, space_below - border_height))
		end
	else
		row = abs_row - total_height
		-- Adjust height if not enough space above
		if space_above < total_height then
			inner_height = math.min(max_height, math.max(min_height, space_above - border_height))
			row = abs_row - (inner_height + border_height)
		end
		-- Ensure row doesn't go off-screen
		row = math.max(0, row)
	end

	-- Calculate width
	local max_line_length = 0
	for _, line in ipairs(content_lines) do
		max_line_length = math.max(max_line_length, #line)
	end

	local inner_width = math.min(max_width, math.max(20, max_line_length))
	local border_width = 2 -- left and right border
	local total_width = inner_width + border_width

	-- Calculate horizontal position
	local col = abs_col - math.floor(total_width / 2)
	if col + total_width > ui.width then
		col = ui.width - total_width
	end
	col = math.max(0, col)

	return {
		row = row,
		col = col,
		width = inner_width,
		height = inner_height,
		total_width = total_width,
		total_height = total_height,
	}
end

-- Utility functions
local function safe_close(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

local function safe_win_close(win_id)
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		pcall(vim.api.nvim_win_close, win_id, true)
	end
end

local function cleanup()
	safe_close(state.current_buf)
	safe_win_close(state.current_win)

	for _, job in ipairs(state.async_jobs) do
		if job and job.handle and not job.handle:is_closing() then
			job.handle:close()
		end
	end
	state.async_jobs = {}
	state.async_queue = {}
end

-- Generate cache key efficiently
local function generate_cache_key(selection, selection_number, columns)
	return string.format("%s:%s:%s", selection, selection_number or "0", columns or "0")
end

-- Generate unique buffer name
local function generate_buffer_name(selection)
	state.buffer_counter = state.buffer_counter + 1
	return string.format("cppman:%s:%d", selection, state.buffer_counter)
end

-- Async execute cppman using libuv
local function execute_cppman_async(selection, selection_number, columns, callback)
	local cache_key = generate_cache_key(selection, selection_number, columns)
	if state.cache[cache_key] then
		vim.schedule(function()
			callback(state.cache[cache_key])
		end)
		return
	end

	-- Check if we've reached the max async jobs limit
	if #state.async_jobs >= M.config.max_async_jobs then
		table.insert(state.async_queue, {
			selection = selection,
			selection_number = selection_number,
			columns = columns,
			callback = callback,
		})
		return
	end

	local cmd = "cppman"
	if columns then
		cmd = cmd .. " --force-columns=" .. columns
	end
	cmd = cmd .. " '" .. selection:gsub("'", "'\\''") .. "' 2>&1"

	if selection_number then
		cmd = string.format("echo %d | %s", selection_number, cmd)
	end

	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)
	local handle, pid
	local output = {}

	local function on_exit(code)
		-- Remove this job from active jobs
		for i, job in ipairs(state.async_jobs) do
			if job.pid == pid then
				table.remove(state.async_jobs, i)
				break
			end
		end

		-- Process next job in queue if any
		if #state.async_queue > 0 then
			local next_job = table.remove(state.async_queue, 1)
			execute_cppman_async(next_job.selection, next_job.selection_number, next_job.columns, next_job.callback)
		end

		if code ~= 0 then
			vim.schedule(function()
				callback({ "Error running cppman (exit code: " .. code .. ")", "Command: " .. cmd })
			end)
			return
		end

		local full_output = table.concat(output, "")
		local lines = vim.split(full_output, "\n", { trimempty = true })
		local filtered_lines = {}
		for _, line in ipairs(lines) do
			if line:find("Please enter the selection:") then
				filtered_lines = {}
			else
				table.insert(filtered_lines, line)
			end
		end

		if #filtered_lines > 0 then
			state.cache[cache_key] = filtered_lines
		end

		vim.schedule(function()
			callback(#filtered_lines > 0 and filtered_lines or { "No output from cppman" })
		end)
	end

	local function on_read(err, data)
		if err then
			return
		end
		if data then
			table.insert(output, data)
		end
	end

	handle, pid = uv.spawn("sh", {
		args = { "-c", cmd },
		stdio = { nil, stdout, stderr },
	}, function(code, signal)
		stdout:read_stop()
		stderr:read_stop()
		stdout:close()
		stderr:close()
		if handle then
			handle:close()
		end
		on_exit(code)
	end)

	if not handle then
		vim.schedule(function()
			callback({ "Failed to start cppman process" })
		end)
		return
	end

	-- Add to active jobs
	table.insert(state.async_jobs, { handle = handle, pid = pid })

	uv.read_start(stdout, on_read)
	uv.read_start(stderr, on_read)
end

-- Synchronous execute cppman (fallback)
local function execute_cppman_sync(selection, selection_number, columns)
	local cache_key = generate_cache_key(selection, selection_number, columns)
	if state.cache[cache_key] then
		return state.cache[cache_key]
	end

	local cmd = "cppman"
	if columns then
		cmd = cmd .. " --force-columns=" .. columns
	end
	cmd = cmd .. " '" .. selection:gsub("'", "'\\''") .. "' 2>&1"

	if selection_number then
		cmd = string.format("echo %d | %s", selection_number, cmd)
	end

	local result = vim.fn.system(cmd)
	local exit_code = vim.v.shell_error

	if exit_code ~= 0 then
		return { "Error running cppman (exit code: " .. exit_code .. ")", "Command: " .. cmd }
	end

	local lines = vim.split(result, "\n", { trimempty = true })
	local filtered_lines = {}
	for _, line in ipairs(lines) do
		if not line:find("Please enter the selection:") then
			table.insert(filtered_lines, line)
		end
	end

	if #filtered_lines > 0 then
		state.cache[cache_key] = filtered_lines
	end

	return #filtered_lines > 0 and filtered_lines or { "No output from cppman" }
end

-- Wrapper function to choose between async and sync execution
local function execute_cppman(selection, selection_number, columns, callback)
	if M.config.enable_async and callback then
		execute_cppman_async(selection, selection_number, columns, callback)
	else
		local result = execute_cppman_sync(selection, selection_number, columns)
		if callback then
			vim.schedule(function()
				callback(result)
			end)
		end
		return result
	end
end

-- Calculate optimal columns based on window width
local function calculate_optimal_columns(window_width)
	return math.max(40, window_width - 8)
end

-- Prefetch content for configurable number of options
local function prefetch_top_options(word_to_search, options, columns)
	if #options == 0 or not M.config.enable_async then
		return
	end

	-- Use configured limit
	local limit = math.min(M.config.max_prefetch_options, #options)

	for i = 1, limit do
		local option = options[i]
		local cache_key = generate_cache_key(word_to_search, option.num, columns)

		if not state.cache[cache_key] then
			-- Prefetch asynchronously without callback (fire and forget)
			execute_cppman_async(word_to_search, option.num, columns, function() end)
		end
	end
end

-- Parse options synchronously
local function parse_cppman_options(word_to_search)
	local cache_key = "options_" .. word_to_search
	if state.cache[cache_key] then
		return state.cache[cache_key]
	end

	local result = vim.fn.system("cppman '" .. word_to_search:gsub("'", "'\\''") .. "' 2>&1")
	local exit_code = vim.v.shell_error

	if exit_code ~= 0 then
		return {}
	end

	local options = {}
	for line in result:gmatch("[^\r\n]+") do
		if line:match("^%d+%.") then
			local num, desc = line:match("^(%d+)%.%s*(.*)")
			table.insert(options, {
				num = tonumber(num),
				text = desc,
				value = desc:match("^[^ ]+") or desc,
			})
		end
	end

	state.cache[cache_key] = options
	return options
end

-- Create a scrollable buffer with cppman content
local function create_cppman_buffer(selection, selection_number)
	local max_width = math.min(M.config.max_width, vim.o.columns)
	local max_height = math.min(M.config.max_height, vim.o.lines)
	local min_height = M.config.min_height
	-- local optimal_columns = calculate_optimal_columns(max_width)
	local optimal_columns = 80

	local buf = vim.api.nvim_create_buf(false, true)
	state.current_buf = buf

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading cppman content..." })

	-- Use unique buffer name
	vim.api.nvim_buf_set_name(buf, generate_buffer_name(selection))
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true

	-- Create temporary window with minimal size to get proper positioning
	local temp_geometry = calculate_window_size_and_position({ "Loading..." }, max_width, max_height, min_height)

	local win_opts = {
		relative = "editor",
		width = temp_geometry.width,
		height = temp_geometry.height,
		style = "minimal",
		border = "double",
		title = "cppman: " .. selection,
		title_pos = "center",
		zindex = 200,
		row = temp_geometry.row,
		col = temp_geometry.col,
	}

	local win = vim.api.nvim_open_win(buf, true, win_opts)
	state.current_win = win

	vim.api.nvim_win_set_option(win, "wrap", true)
	vim.api.nvim_win_set_option(win, "number", false)
	vim.api.nvim_win_set_option(win, "relativenumber", false)
	vim.api.nvim_win_set_option(win, "cursorline", true)

	local opts = { silent = true, buffer = buf }

	vim.keymap.set("n", "q", function()
		safe_win_close(win)
		safe_close(buf)
		cleanup()
	end, opts)

	vim.keymap.set("n", "<ESC>", function()
		safe_win_close(win)
		safe_close(buf)
		cleanup()
	end, opts)

	vim.keymap.set("n", "K", function()
		local word = vim.fn.expand("<cword>")
		if word and word ~= "" then
			if state.current_page then
				table.insert(state.stack, {
					page = state.current_page,
					selection_number = state.current_selection_number,
				})
				state.forward_stack = {}
			end
			state.current_page = word
			state.current_selection_number = nil
			safe_win_close(win)
			safe_close(buf)
			M.open_cppman_for(word)
		end
	end, opts)

	vim.keymap.set("n", "<C-]>", function()
		local word = vim.fn.expand("<cword>")
		if word and word ~= "" then
			if state.current_page then
				table.insert(state.stack, {
					page = state.current_page,
					selection_number = state.current_selection_number,
				})
				state.forward_stack = {}
			end
			state.current_page = word
			state.current_selection_number = nil
			safe_win_close(win)
			safe_close(buf)
			M.open_cppman_for(word)
		end
	end, opts)

	vim.keymap.set("n", "<C-o>", function()
		if #state.stack > 0 then
			safe_win_close(win)
			safe_close(buf)
			local prev = table.remove(state.stack)

			table.insert(state.forward_stack, {
				page = state.current_page,
				selection_number = state.current_selection_number,
			})

			state.current_page = prev.page
			state.current_selection_number = prev.selection_number

			if prev.selection_number then
				create_cppman_buffer(prev.page, prev.selection_number)
			else
				M.open_cppman_for(prev.page)
			end
		else
			vim.notify("No previous page to go back to", vim.log.levels.INFO)
		end
	end, opts)

	vim.keymap.set("n", "<C-i>", function()
		if #state.forward_stack > 0 then
			safe_win_close(win)
			safe_close(buf)
			local next_item = table.remove(state.forward_stack)

			table.insert(state.stack, {
				page = state.current_page,
				selection_number = state.current_selection_number,
			})

			state.current_page = next_item.page
			state.current_selection_number = next_item.selection_number

			if next_item.selection_number then
				create_cppman_buffer(next_item.page, next_item.selection_number)
			else
				M.open_cppman_for(next_item.page)
			end
		else
			vim.notify("No forward page available", vim.log.levels.INFO)
		end
	end, opts)

	-- Load content asynchronously with cache validation
	execute_cppman(selection, selection_number, optimal_columns, function(lines)
		if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
			return
		end

		if #lines == 0 or (lines[1] and lines[1]:find("No output from cppman")) then
			if selection_number then
				local fallback_cache_key = generate_cache_key(selection, nil, optimal_columns)
				if state.cache[fallback_cache_key] then
					lines = state.cache[fallback_cache_key]
				end
			end

			if #lines == 0 then
				lines = { "No content available", "Press C-o to go back" }
			end
		end

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		vim.bo[buf].readonly = true
		vim.bo[buf].filetype = "c"

		-- Resize and reposition window based on content
		local geometry = calculate_window_size_and_position(lines, max_width, max_height, min_height)
		vim.api.nvim_win_set_config(win, {
			relative = "editor",
			row = geometry.row,
			col = geometry.col,
			width = geometry.width,
			height = geometry.height,
		})
	end)

	return win, buf
end

-- Show selection window for multiple options
local function show_selection_window(word_to_search, options)
	-- Prefetch (async) based on configured limit
	local max_width = math.min(M.config.max_width, vim.o.columns - 10)
	local optimal_columns = calculate_optimal_columns(max_width)
	prefetch_top_options(word_to_search, options, optimal_columns)

	-- Create selection window
	local buf = vim.api.nvim_create_buf(false, true)

	local lines = {}
	for _, opt in ipairs(options) do
		table.insert(lines, string.format("%2d. %s", opt.num, opt.text))
	end
	table.insert(lines, "")
	table.insert(lines, "Enter selection number (1-" .. #options .. "):")

	-- Calculate window size and position based on content
	local geometry = calculate_window_size_and_position(lines, 60, 20, 5)

	local win_opts = {
		relative = "editor",
		row = geometry.row,
		col = geometry.col,
		width = geometry.width,
		height = geometry.height,
		style = "minimal",
		border = "double",
		title = "Select cppman entry",
		title_pos = "center",
		zindex = 200,
	}

	local win = vim.api.nvim_open_win(buf, true, win_opts)

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"

	vim.api.nvim_buf_set_option(buf, "syntax", "off")
	for i = 1, #options do
		vim.api.nvim_buf_add_highlight(buf, -1, "Number", i - 1, 0, 2)
		vim.api.nvim_buf_add_highlight(buf, -1, "Identifier", i - 1, 3, -1)
	end

	vim.api.nvim_win_set_option(win, "cursorline", true)
	vim.api.nvim_win_set_option(win, "cursorlineopt", "line")

	local opts = { silent = true, buffer = buf }

	vim.keymap.set("n", "<CR>", function()
		local line = vim.api.nvim_get_current_line()
		local selection_num = tonumber(line:match("%d+"))

		if selection_num and selection_num >= 1 and selection_num <= #options then
			if state.current_page and M.config.history_mode == "unified" then
				table.insert(state.stack, {
					page = state.current_page,
					selection_number = state.current_selection_number,
				})
				state.forward_stack = {}
			end
			vim.api.nvim_win_close(win, true)
			safe_close(buf)
			create_cppman_buffer(word_to_search, selection_num)
			state.current_page = word_to_search
			state.current_selection_number = selection_num
		else
			vim.notify("Invalid selection", vim.log.levels.ERROR)
		end
	end, opts)

	vim.keymap.set("n", "<C-o>", function()
		if #state.stack > 0 then
			vim.api.nvim_win_close(win, true)
			safe_close(buf)
			local prev = table.remove(state.stack)

			table.insert(state.forward_stack, {
				page = state.current_page,
				selection_number = state.current_selection_number,
			})

			state.current_page = prev.page
			state.current_selection_number = prev.selection_number

			if prev.selection_number then
				create_cppman_buffer(prev.page, prev.selection_number)
			else
				M.open_cppman_for(prev.page)
			end
		else
			vim.notify("No previous page to go back to", vim.log.levels.INFO)
		end
	end, opts)

	vim.keymap.set("n", "<C-i>", function()
		if #state.forward_stack > 0 then
			vim.api.nvim_win_close(win, true)
			safe_close(buf)
			local next_item = table.remove(state.forward_stack)

			table.insert(state.stack, {
				page = state.current_page,
				selection_number = state.current_selection_number,
			})

			state.current_page = next_item.page
			state.current_selection_number = next_item.selection_number

			if next_item.selection_number then
				create_cppman_buffer(next_item.page, next_item.selection_number)
			else
				M.open_cppman_for(next_item.page)
			end
		else
			vim.notify("No forward page available", vim.log.levels.INFO)
		end
	end, opts)

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
		safe_close(buf)
		cleanup()
	end, opts)

	vim.keymap.set("n", "<ESC>", function()
		vim.api.nvim_win_close(win, true)
		safe_close(buf)
		cleanup()
	end, opts)

	vim.keymap.set("n", "j", function()
		local current_line = vim.api.nvim_win_get_cursor(win)[1]
		if current_line < #options then
			vim.api.nvim_win_set_cursor(win, { current_line + 1, 0 })
		end
	end, opts)

	vim.keymap.set("n", "k", function()
		local current_line = vim.api.nvim_win_get_cursor(win)[1]
		if current_line > 1 then
			vim.api.nvim_win_set_cursor(win, { current_line - 1, 0 })
		end
	end, opts)

	vim.keymap.set("n", "gg", function()
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
	end, opts)

	vim.keymap.set("n", "G", function()
		vim.api.nvim_win_set_cursor(win, { #options, 0 })
	end, opts)

	vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

-- Public API
M.setup = function(opts)
	-- Merge user configuration with defaults
	opts = opts or {}
	M.config = vim.tbl_deep_extend("force", M.config, opts)
	vim.api.nvim_create_user_command("Fastcppman", function(args)
		if args.args and #args.args > 1 then
			M.open_cppman_for(args.args)
		else
			M.input()
		end
	end, { nargs = "?" })
end

M.input = function()
	local input = Input({
		position = "50%",
		size = { width = M.config.input_width },
		border = {
			style = "double",
			text = { top = "[Search cppman]", top_align = "center" },
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:Normal",
		},
	}, {
		prompt = "> ",
		default_value = "",
		on_submit = function(value)
			M.open_cppman_for(value)
		end,
	})

	input:mount()
	input:on(event.BufLeave, function()
		input:unmount()
	end)

	vim.keymap.set("n", "q", function()
		input:unmount()
	end, { silent = true, buffer = true })
	vim.keymap.set("n", "<ESC>", function()
		input:unmount()
	end, { silent = true, buffer = true })
end

M.open_cppman_for = function(word_to_search)
	cleanup()

	-- Store initial cursor position before creating any windows
	local win = vim.api.nvim_get_current_win()
	local top, left = unpack(vim.fn.win_screenpos(win))
	local cur = vim.api.nvim_win_get_cursor(win)
	state.initial_cursor = {
		top = top,
		left = left,
		row = cur[1],
		col = cur[2],
	}

	-- Parse options synchronously
	local options = parse_cppman_options(word_to_search)

	if #options == 0 then
		create_cppman_buffer(word_to_search)
		state.current_page = word_to_search
		state.current_selection_number = nil
	else
		show_selection_window(word_to_search, options)
	end
end

return M
