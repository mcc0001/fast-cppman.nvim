local uv = vim.loop

local M = {}
local U = {}

-- Default configuration
M.config = {
	max_prefetch_options = 20,
	max_width = 80,
	max_height = 20,
	min_height = 5,
	input_width = 20,
	enable_async = true,
	max_async_jobs = 5,
	history_mode = "unified",
	position = "cursor", -- Can be "cursor" or "center"
	fallback_to_lsp_hover = true,
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

local function clear_navigation()
	state.stack = {}
	state.forward_stack = {}
	state.current_page = nil
	state.current_selection_number = nil
end

local function generate_cache_key(selection, selection_number, columns)
	return string.format("%s:%s:%s", selection, selection_number or "0", columns or "0")
end

local function generate_buffer_name(selection)
	state.buffer_counter = state.buffer_counter + 1
	return string.format("cppman:%s:%d", selection, state.buffer_counter)
end

-- Window and geometry calculations
local function calculate_window_size_and_position(content_lines, max_width, max_height, min_height)
	local ui = vim.api.nvim_list_uis()[1] or { width = vim.o.columns, height = vim.o.lines }

	if M.config.position == "center" then
		-- Center the window on screen
		local content_height = #content_lines
		local border_height = 2
		local inner_height = math.min(max_height, math.max(min_height, content_height))
		local total_height = inner_height + border_height

		local max_line_length = 0
		for _, line in ipairs(content_lines) do
			max_line_length = math.max(max_line_length, #line)
		end

		local inner_width = math.min(max_width, math.max(20, max_line_length))
		local border_width = 2
		local total_width = inner_width + border_width

		return {
			row = math.floor((ui.height - total_height) / 2),
			col = math.floor((ui.width - total_width) / 2),
			width = inner_width,
			height = inner_height,
			total_width = total_width,
			total_height = total_height,
		}
	else
		-- Cursor-relative positioning
		local abs_row = state.initial_cursor.row
		local abs_col = state.initial_cursor.col

		-- Calculate content dimensions
		local content_height = #content_lines
		local border_height = 2
		local inner_height = math.min(max_height, math.max(min_height, content_height))
		local total_height = inner_height + border_height

		-- Determine available space and position
		local space_below = ui.height - (abs_row + 1) -- +1 to account for current line
		local space_above = abs_row -- No -1 here to eliminate the gap

		local position_below = space_below >= total_height or (space_below >= space_above and space_below >= min_height)
		local row

		if position_below then
			-- Position below the current line
			row = abs_row + 1 -- Start right below the cursor
			if space_below < total_height then
				inner_height = math.min(max_height, math.max(min_height, space_below - border_height))
			end
		else
			-- Position above the current line
			row = abs_row - total_height -- Position directly above the cursor
			if space_above < total_height then
				inner_height = math.min(max_height, math.max(min_height, space_above - border_height))
				row = math.max(0, abs_row - (inner_height + border_height))
			end
		end

		-- Calculate width
		local max_line_length = 0
		for _, line in ipairs(content_lines) do
			max_line_length = math.max(max_line_length, #line)
		end
		local inner_width = math.min(max_width, math.max(20, max_line_length))
		local total_width = inner_width + 2 -- account for borders

		-- Calculate column position
		local col
		if abs_col + total_width <= ui.width then
			-- If there's space to the right, align with cursor
			col = abs_col
		else
			-- If not enough space, align with right edge of screen
			col = ui.width - total_width
		end

		-- Ensure the window doesn't go off the edges
		col = math.max(0, col)
		row = math.max(0, row)

		return {
			row = row,
			col = col,
			width = inner_width,
			height = inner_height,
			total_width = total_width,
			total_height = total_height,
		}
	end
end

local function calculate_optimal_columns(window_width)
	return math.max(40, window_width - 8)
end

-- Reusable window options generator
local function get_win_opts(geometry, opts)
	opts = opts or {}
	local base_opts = {
		relative = "editor",
		row = geometry.row,
		col = geometry.col,
		width = geometry.width,
		height = geometry.height,
		style = "minimal",
		border = "rounded",
		zindex = 200,
	}
	return vim.tbl_extend("force", base_opts, opts)
end

-- Cppman execution functions
local function process_cppman_output(output)
	local lines = vim.split(output, "\n", { trimempty = true })
	local filtered_lines = {}

	local firstLineInserted = false
	for _, line in ipairs(lines) do
		if line:find("Please enter the selection:") then
			filtered_lines = {}
			firstLineInserted = false
		else
			if not (line:match("^%s*$") and not firstLineInserted) then
				firstLineInserted = true
				table.insert(filtered_lines, line)
			end
		end
	end

	return filtered_lines
end

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

	local filtered_lines = process_cppman_output(result)

	if #filtered_lines > 0 then
		state.cache[cache_key] = filtered_lines
	end

	return #filtered_lines > 0 and filtered_lines or { "No output from cppman" }
end

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
		local filtered_lines = process_cppman_output(full_output)

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

-- Option parsing and prefetching
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

	if #options == 0 and result:find("error") then
		return -1
	end

	state.cache[cache_key] = options
	return options
end

local function prefetch_top_options(word_to_search, options, columns, callback)
	if #options == 0 or not M.config.enable_async then
		return
	end

	local limit = math.min(M.config.max_prefetch_options, #options)

	for i = 1, limit do
		local option = options[i]
		local cache_key = generate_cache_key(word_to_search, option.num, columns)

		if not state.cache[cache_key] then
			execute_cppman_async(word_to_search, option.num, columns, function(content)
				if callback then
					callback(option.num)
				end
			end)
		elseif callback then
			callback(option.num)
		end
	end
end

-- Navigation history management
local function push_to_history(stack, page, selection_number)
	table.insert(stack, {
		page = page,
		selection_number = selection_number,
	})
end

local function pop_from_history(stack)
	if #stack > 0 then
		return table.remove(stack)
	end
	return nil
end

-- Window and buffer creation
local function create_cppman_buffer(selection, selection_number)
	local max_width = math.min(M.config.max_width, vim.o.columns)
	local max_height = math.min(M.config.max_height, vim.o.lines)
	local min_height = M.config.min_height
	local optimal_columns = calculate_optimal_columns(max_width)

	-- Check if content is already cached
	local cache_key = generate_cache_key(selection, selection_number, optimal_columns)
	local cached_content = state.cache[cache_key]

	local buf = vim.api.nvim_create_buf(false, true)
	state.current_buf = buf

	-- Use unique buffer name
	vim.api.nvim_buf_set_name(buf, generate_buffer_name(selection))
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true

	-- Create temporary window with minimal size to get proper positioning
	local temp_lines = cached_content or { "Loading cppman content..." }
	local temp_geometry = calculate_window_size_and_position(temp_lines, max_width, max_height, min_height)

	local win = vim.api.nvim_open_win(buf, true, get_win_opts(temp_geometry))
	state.current_win = win

	vim.api.nvim_win_set_option(win, "wrap", true)
	vim.api.nvim_win_set_option(win, "number", false)
	vim.api.nvim_win_set_option(win, "relativenumber", false)
	vim.api.nvim_win_set_option(win, "cursorline", true)

	-- If content is cached, use it immediately
	if cached_content then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, cached_content)
		vim.bo[buf].modifiable = false
		vim.bo[buf].readonly = true
		vim.bo[buf].filetype = "c"

		-- Resize window to fit content
		local geometry = calculate_window_size_and_position(cached_content, max_width, max_height, min_height)
		vim.api.nvim_win_set_config(win, {
			relative = "editor",
			row = geometry.row,
			col = geometry.col,
			width = geometry.width,
			height = geometry.height,
		})
	else
		-- Set loading message and fetch content asynchronously
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading cppman content..." })

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
	end

	-- Key mappings setup
	local opts = { silent = true, buffer = buf }

	local function navigate_to_word()
		local word = vim.fn.expand("<cword>")
		if word and word ~= "" then
			if state.current_page then
				push_to_history(state.stack, state.current_page, state.current_selection_number)
				state.forward_stack = {}
			end
			state.current_page = word
			state.current_selection_number = nil
			safe_win_close(win)
			safe_close(buf)
			U.search_cppman(word)
		end
	end

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

	vim.keymap.set("n", "K", navigate_to_word, opts)
	vim.keymap.set("n", "<C-]>", navigate_to_word, opts)

	vim.keymap.set("n", "<C-o>", function()
		local prev = pop_from_history(state.stack)
		if prev then
			safe_win_close(win)
			safe_close(buf)
			push_to_history(state.forward_stack, state.current_page, state.current_selection_number)
			state.current_page = prev.page
			state.current_selection_number = prev.selection_number

			if prev.selection_number then
				create_cppman_buffer(prev.page, prev.selection_number)
			else
				U.search_cppman(prev.page)
			end
		else
			vim.notify("No previous page to go back to", vim.log.levels.INFO)
		end
	end, opts)

	vim.keymap.set("n", "<C-i>", function()
		local next_item = pop_from_history(state.forward_stack)
		if next_item then
			safe_win_close(win)
			safe_close(buf)
			push_to_history(state.stack, state.current_page, state.current_selection_number)
			state.current_page = next_item.page
			state.current_selection_number = next_item.selection_number

			if next_item.selection_number then
				create_cppman_buffer(next_item.page, next_item.selection_number)
			else
				U.search_cppman(next_item.page)
			end
		else
			vim.notify("No forward page available", vim.log.levels.INFO)
		end
	end, opts)

	return win, buf
end

local function show_selection_window(word_to_search, options)
	-- Prefetch (async) based on configured limit
	local max_width = math.min(M.config.max_width, vim.o.columns)
	local optimal_columns = calculate_optimal_columns(max_width)

	-- Create selection window first
	local buf = vim.api.nvim_create_buf(false, true)
	local lines = {}

	-- Initialize status for each option
	local option_status = {}
	for _, opt in ipairs(options) do
		local cache_key = generate_cache_key(word_to_search, opt.num, optimal_columns)
		option_status[opt.num] = state.cache[cache_key] and "✓" or "⏳"
		table.insert(lines, string.format("%s %2d. %s", option_status[opt.num], opt.num, opt.text))
	end
	table.insert(lines, "")
	table.insert(lines, "Enter selection number (1-" .. #options .. "):")

	-- Calculate window size and position based on content
	local geometry = calculate_window_size_and_position(lines, 60, 20, 5)

	local win = vim.api.nvim_open_win(buf, true, get_win_opts(geometry))
	state.current_win = win

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"

	vim.api.nvim_buf_set_option(buf, "syntax", "off")
	for i = 1, #options do
		vim.api.nvim_buf_add_highlight(buf, -1, "Number", i - 1, 2, 4)
		vim.api.nvim_buf_add_highlight(buf, -1, "Identifier", i - 1, 6, -1)
	end

	vim.api.nvim_win_set_option(win, "cursorline", true)
	vim.api.nvim_win_set_option(win, "cursorlineopt", "line")

	-- Function to update the status of an option
	local function update_option_status(option_num, status)
		if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
			return
		end

		option_status[option_num] = status
		local new_lines = {}
		for i, opt in ipairs(options) do
			table.insert(new_lines, string.format("%s %2d. %s", option_status[opt.num], opt.num, opt.text))
		end
		table.insert(new_lines, "")
		table.insert(new_lines, "Enter selection number (1-" .. #options .. "):")

		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
		vim.bo[buf].modifiable = false

		-- Reapply highlighting
		for i = 1, #options do
			vim.api.nvim_buf_add_highlight(buf, -1, "Number", i - 1, 2, 4)
			vim.api.nvim_buf_add_highlight(buf, -1, "Identifier", i - 1, 6, -1)
		end
	end

	-- Prefetch with callback to update status
	prefetch_top_options(word_to_search, options, optimal_columns, function(option_num)
		update_option_status(option_num, "✓")
	end)

	-- Key mappings setup
	local opts = { silent = true, buffer = buf }

	vim.keymap.set("n", "<CR>", function()
		local line = vim.api.nvim_get_current_line()
		local selection_num = tonumber(line:match("%d+"))

		if selection_num and selection_num >= 1 and selection_num <= #options then
			if state.current_page and M.config.history_mode == "unified" then
				push_to_history(state.stack, state.current_page, state.current_selection_number)
				state.forward_stack = {}
			end

			-- Check if this content is already cached
			local cache_key = generate_cache_key(word_to_search, selection_num, optimal_columns)
			if state.cache[cache_key] then
				-- Use cached content immediately
				vim.api.nvim_win_close(win, true)
				safe_close(buf)
				create_cppman_buffer(word_to_search, selection_num)
			else
				-- Show loading message and fetch content
				update_option_status(selection_num, "🔄")
				execute_cppman(word_to_search, selection_num, optimal_columns, function(content)
					if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_win_close(win, true)
						safe_close(buf)
						create_cppman_buffer(word_to_search, selection_num)
					end
				end)
			end

			state.current_page = word_to_search
			state.current_selection_number = selection_num
		else
			vim.notify("Invalid selection", vim.log.levels.ERROR)
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

	local function navigate_history(direction_stack, opposite_stack)
		if #direction_stack > 0 then
			vim.api.nvim_win_close(win, true)
			safe_close(buf)
			local item = pop_from_history(direction_stack)

			push_to_history(opposite_stack, state.current_page, state.current_selection_number)

			state.current_page = item.page
			state.current_selection_number = item.selection_number

			if item.selection_number then
				create_cppman_buffer(item.page, item.selection_number)
			else
				U.search_cppman(item.page)
			end
		else
			vim.notify("No page available in that direction", vim.log.levels.INFO)
		end
	end

	vim.keymap.set("n", "<C-o>", function()
		navigate_history(state.stack, state.forward_stack)
	end, opts)

	vim.keymap.set("n", "<C-i>", function()
		navigate_history(state.forward_stack, state.stack)
	end, opts)

	-- Navigation keys
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

-- Input window creation
local function create_input_window()
	local buf = vim.api.nvim_create_buf(false, true)
	local width = M.config.input_width
	local height = 1

	-- Get current cursor position
	local win = vim.api.nvim_get_current_win()
	local cursor_pos = vim.api.nvim_win_get_cursor(win)
	local screen_pos = vim.fn.screenpos(win, cursor_pos[1], cursor_pos[2])

	local ui = vim.api.nvim_list_uis()[1]
	local geometry

	if M.config.position == "center" then
		-- Center the window
		geometry = {
			row = math.floor((ui.height - height) / 2),
			col = math.floor((ui.width - width) / 2),
			width = width,
			height = height,
		}
	else
		-- Position relative to cursor
		local abs_row = screen_pos.row - 1 -- Convert to 0-based
		local abs_col = screen_pos.col - 1 -- Convert to 0-based

		local space_below = ui.height - (abs_row + 1)
		local space_above = abs_row

		local row
		if space_below >= height then
			row = abs_row + 1
		else
			row = abs_row - height
		end

		-- Adjust column to not go off-screen
		local col = abs_col
		if abs_col + width > ui.width then
			col = ui.width - width
		end

		geometry = {
			row = row,
			col = col,
			width = width,
			height = height,
		}
	end

	local win_opts = get_win_opts(geometry, {
		title = "Search cppman",
		title_pos = "center",
	})

	local input_win = vim.api.nvim_open_win(buf, true, win_opts)
	state.current_win = input_win

	vim.bo[buf].buftype = "prompt"
	vim.bo[buf].bufhidden = "wipe"
	vim.fn.prompt_setprompt(buf, "> ")

	local function on_submit(value)
		if value and #value > 0 then
			vim.api.nvim_win_close(input_win, true)
			safe_close(buf)
			M.open_cppman_for(value)
		else
			vim.api.nvim_win_close(input_win, true)
			safe_close(buf)
		end
	end

	vim.fn.prompt_setcallback(buf, on_submit)

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(input_win, true)
		safe_close(buf)
	end, { buffer = buf })

	vim.keymap.set("n", "<ESC>", function()
		vim.api.nvim_win_close(input_win, true)
		safe_close(buf)
	end, { buffer = buf })

	vim.cmd("startinsert")

	return {
		unmount = function()
			if vim.api.nvim_win_is_valid(input_win) then
				vim.api.nvim_win_close(input_win, true)
			end
			safe_close(buf)
		end,
	}
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
	create_input_window()
end

U.search_cppman = function(word_to_search)
	-- Parse options synchronously
	local options = parse_cppman_options(word_to_search)
	-- number
	if type(options) == "number" and options == -1 then
		cleanup()
		-- Only fall back to LSP if configured to do so
		if M.config.fallback_to_lsp_hover then
			vim.lsp.buf.hover()
		else
			vim.notify("No cppman entry found for: " .. word_to_search, vim.log.levels.ERROR)
		end
	-- table
	elseif #options == 0 then
		create_cppman_buffer(word_to_search)
		state.current_page = word_to_search
		state.current_selection_number = nil
	else
		state.current_page = word_to_search
		show_selection_window(word_to_search, options)
	end
end

M.open_cppman_for = function(word_to_search)
	cleanup()

	-- Clear navigation history when starting a new search
	clear_navigation()

	-- Get current cursor screen position instead of buffer position
	local win = vim.api.nvim_get_current_win()
	local cursor_pos = vim.api.nvim_win_get_cursor(win)
	local screen_pos = vim.fn.screenpos(win, cursor_pos[1], cursor_pos[2])

	state.initial_cursor = {
		row = screen_pos.row - 1, -- Convert to 0-based indexing
		col = screen_pos.col - 1,
	}

	U.search_cppman(word_to_search)
end

return M
