 # fast-cppman.nvim
 A NeoVim plugin with a simple interface for the [cppman](https://github.com/ryanmjacobs/cppman) CLI tool,inspiring and fork from [cppman.nvim](https://github.com/madskjeldgaard/cppman.nvim)
] allowing you to easily search cplusplus.com and cppreference.com without ever leaving neovim.
 ## Installation
 Install using your favorite package manager. For example,
##  with [LazyVim](https://www.lazyvim.org/configuration/lazy.nvim):
 ```lua
return {
  "mcc0001/fast-cppman.nvim",
  ft = { "c", "cpp" },

  dependencies = {
    { "MunifTanjim/nui.nvim" },
  },

  opts = {

    max_prefetch_options = 10,
    max_width = 100,
    max_height = 30,
    input_width = 20,
    enable_async = true, -- Enable async operations
    max_async_jobs = 5, -- Maximum concurrent async jobs
    history_mode = "unified", -- "manpage" | "unified"
  },
  keys = {
    {
      "<leader>cp",
      function()
        require("cppman").open_cppman_for(vim.fn.expand("<cword>"))
      end,
      desc = "Search current function from cppman",
    },
    {
      "<leader>cP",
      function()
        require("cppman").input()
      end,
      desc = "open cppman search box",
    },
  },
}
 ```
 ## Configuration
 You can setup the plugin with the following code:
 ```lua
 require("fast-cppman").setup({
   max_prefetch_options = 10,   -- Prefetch the top N options when multiple matches are found
   max_width = 100,             -- Maximum width of the cppman window
   max_height = 30,             -- Maximum height of the cppman window
   input_width = 20,            -- Width of the input popup
   enable_async = true,         -- Enable async operations (recommended)
   max_async_jobs = 5,          -- Maximum number of concurrent async jobs
   history_mode = "unified",    -- "manpage"  C-o / C-i only work in man page windows. |  "unified" → C-o / C-i work in both man page and popup.
 })
 ```
 ## Usage
The plugin provides the following commands:

`:Fastcppman [term]` - Open cppman for the given term, or prompt for a term if none provided.so call the functions directly:

You can also call the functions directly:
 ```lua
 local cppman = require("fast-cppman")
 -- Open the search input
 cppman.input()
 -- Open cppman for a specific term
 cppman.open_cppman_for("std::vector")
 ```
 ### Keymaps
 The user's example configuration sets up two keymaps:
 ```lua
 vim.keymap.set("n", "<leader>cp", function()
   cppman.open_cppman_for(vim.fn.expand("<cword>"))
 end)
 vim.keymap.set("n", "<leader>cP", function()
   cppman.input()
 end)
 ```
 ## Navigation Inside cppman Buffer
 Once the cppman buffer is open, you can use the following keybindings:
- `K` or `<C-]>`: Follow the word under the cursor (open its documentation).
- `<C-o>`: Go back to the previous page.
- `<C-i>`: Go forward to the next page.
- q or `<ESC>`: Close the cppman window.
- `j/k`, `gg/G`: Navigate lines in selection windows.
 ## Features
 - Asynchronous execution for non-blocking UI.
 - Caching of results for faster subsequent lookups.
 - Prefetching of top N options when multiple matches are found.
 - Scrollable buffer with syntax highlighting.
 ## Note:
- Requires the cppman CLI tool installed and available in your PATH.
- The plugin handles multi-page navigation, forward/back stacks, and unique buffer naming to allow multiple lookups in the same session.

## Example Workflow
1. Press `<leader>cP` to open the input popup.
2. Type `std::vector` and press <Enter>.
3. If multiple matches exist, select the correct entry.
4. Navigate using `K` or `<C-]>`.
5. Use `<C-o>` and `<C-i>` to navigate backward/forward between visited pages.
6. Press `q` or `<ESC>` to close the window.
