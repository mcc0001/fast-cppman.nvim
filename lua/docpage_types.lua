-- ============================================================================
--  Core Domain Classes
-- ============================================================================

---@alias UvHandle userdata Lightweight wrapper for libuv handle types

---@alias HistoryMode "unified"|"separate"
---@alias WindowPosition "cursor"|"center"

---@class DocPageConfig
---@field max_prefetch_options integer Maximum number of options to prefetch
---@field max_width integer Maximum width of documentation window
---@field max_height integer Maximum height of documentation window
---@field min_height integer Minimum height of documentation window
---@field input_width integer Width of input prompt window
---@field enable_async boolean Whether to enable async execution
---@field max_async_jobs integer Maximum number of concurrent async jobs
---@field history_mode HistoryMode Navigation history mode
---@field position WindowPosition Window positioning strategy
---@field auto_select_first_match boolean Auto-select first match in selection lists
---@field adapters table<string, DocPageAdapterConfig> Adapter configurations
---@field filetype_adapters table<string, DocPageFileTypeAdapterConfig> Filetype-specific adapter configs

---@class DocPageAdapterConfig
---@field cmd string Command to execute
---@field args string Command arguments
---@field env table<string, string> Environment variables
---@field process_output fun(output: string): string[] Output processing function
---@field error_patterns string[] Patterns that indicate errors
---@field exit_code_error boolean Whether non-zero exit codes indicate errors
---@field fallback_to_lsp boolean Fall back to LSP on error
---@field supports_selections boolean Whether adapter supports selection lists
---@field parse_options? fun(output: string): DocPageOption[] Function to parse selection options

---@class DocPageFileTypeAdapterConfig
---@field adapter string Adapter name to use
---@field args string Adapter-specific arguments

---@class DocPageOption
---@field num integer Option number
---@field text string Option description text
---@field value string Option value

---@class DocPageGeometry
---@field row number Window row position
---@field col number Window column position
---@field width number Window width
---@field height number Window height
---@field total_width number Total width including borders
---@field total_height number Total height including borders

---@class DocPageState
---@field stack DocPageHistoryEntry[] Back navigation history
---@field forward_stack DocPageHistoryEntry[] Forward navigation history
---@field current_page string? Currently displayed page
---@field current_buf integer? Current buffer ID
---@field current_win integer? Current window ID
---@field cache table<string, string[]> Content cache
---@field async_jobs DocPageJobInfo[] Active async jobs
---@field async_queue DocPageAsyncJobQueue[] Queued async jobs
---@field buffer_counter integer Buffer counter for unique naming
---@field initial_cursor DocPageCursorPosition Initial cursor position
---@field current_adapter_info DocPageAdapterInfo? Current adapter information
---@field current_selection_number integer? Current selection number

---@class DocPageHistoryEntry
---@field page string Page identifier
---@field selection_number integer? Selection number if applicable

---@class DocPageCursorPosition
---@field top integer Top position
---@field left integer Left position
---@field row integer Row position
---@field col integer Column position

---@class DocPageAdapterInfo
---@field name string Adapter name
---@field cmd string Command to execute
---@field args string Command arguments
---@field env table<string, string> Environment variables
---@field process_output fun(output: string): string[] Output processing function
---@field error_patterns string[] Patterns that indicate errors
---@field exit_code_error boolean Whether non-zero exit codes indicate errors
---@field fallback_to_lsp boolean Fall back to LSP on error
---@field supports_selections boolean Whether adapter supports selection lists
---@field parse_options? fun(output: string): DocPageOption[] Function to parse selection options

-- ============================================================================
--  Utility / Internal Classes
-- ============================================================================

---@class DocPageJobInfo
---@field handle UvHandle? Libuv process handle
---@field pid integer? Process ID

---@class DocPageAsyncJobQueue
---@field selection string Selection to search for
---@field selection_number integer? Selection number if applicable
---@field columns integer Terminal columns for formatting
---@field callback fun(result: string[]) Callback function
---@field adapter_info DocPageAdapterInfo Adapter information

---@class DocPageInputWindow
---@field unmount fun() Function to unmount/close the input window

-- ============================================================================
--  Module Shapes
-- ============================================================================

---@class DocPageModule
---@field config DocPageConfig Module configuration
---@field setup fun(opts?: DocPageConfig) Setup function
---@field input fun() Show input prompt
---@field open_docpage_for fun(word_to_search: string) Open documentation for a word

---@class DocPageUtils
---@field search_docpage fun(word_to_search: string) Search documentation

-- ============================================================================
--  Function Signatures
-- ============================================================================

---@alias AsyncCallback fun(result: string[])

---@class DocPageFunctions
---@field safe_close fun(bufnr: integer?) Safely close a buffer
---@field safe_win_close fun(win_id: integer?) Safely close a window
---@field cleanup fun() Clean up resources
---@field clear_navigation fun() Clear navigation history
---@field generate_cache_key fun(selection: string, selection_number: integer?, columns: integer?): string Generate cache key
---@field generate_buffer_name fun(selection: string): string Generate unique buffer name
---@field get_adapter_info fun(): DocPageAdapterInfo Get adapter info for current filetype
---@field calculate_window_size_and_position fun(content_lines: string[], max_width: integer, max_height: integer, min_height: integer): DocPageGeometry Calculate window geometry
---@field calculate_optimal_columns fun(window_width: integer): integer Calculate optimal columns for content
---@field get_win_opts fun(geometry: DocPageGeometry, opts?: table): table Get window options
---@field build_command fun(adapter_info: DocPageAdapterInfo, selection: string, selection_number: integer?, columns: integer): string Build command string
---@field execute_command_sync fun(adapter_info: DocPageAdapterInfo, selection: string, selection_number: integer?, columns: integer): string[] Execute command synchronously
---@field execute_command_async fun(adapter_info: DocPageAdapterInfo, selection: string, selection_number: integer?, columns: integer, callback: AsyncCallback) Execute command asynchronously
---@field execute_command fun(selection: string, selection_number: integer?, columns: integer, callback: AsyncCallback): string[]? Execute command with appropriate method
---@field parse_options fun(word_to_search: string): DocPageOption[]|integer Parse selection options
---@field prefetch_top_options fun(word_to_search: string, options: DocPageOption[], columns: integer, callback: fun(option_num: integer)?) Prefetch top options
---@field push_to_history fun(stack: DocPageHistoryEntry[], page: string, selection_number: integer?) Push to history stack
---@field pop_from_history fun(stack: DocPageHistoryEntry[]): DocPageHistoryEntry? Pop from history stack
---@field create_docpage_buffer fun(selection: string, selection_number: integer?) Create documentation buffer
---@field show_selection_window fun(word_to_search: string, options: DocPageOption[]) Show selection window
---@field create_input_window fun(): DocPageInputWindow Create input window

return {}
