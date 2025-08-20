 # fast-cppman.nvim
 A NeoVim plugin with a simple interface for the [cppman](https://github.com/ryanmjacobs/cppman) CLI tool,inspiring and fork from [cppman.nvim](https://github.com/madskjeldgaard/cppman.nvim)
] allowing you to easily search cplusplus.com and cppreference.com without ever leaving neovim.
 ## Installation
 Install using your favorite package manager. For example, with [Packer.nvim](https://github.com/wbthomason/packer.nvim):
 ```lua
 use {
   'mcc0001/fast-cppman.nvim',
   requires = {
     { 'MunifTanjim/nui.nvim' }
   }
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
 })
 ```
 ## Usage
 The plugin provides the following commands:
 - `:cppman [term]` - Open cppman for the given term, or prompt for a term if none provided.
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
 ## Navigation
 Once the cppman buffer is open, you can use the following keybindings:
 - `K`, `<C-]>`, and double-click (`<2-LeftMouse>`): Follow the word under the cursor (open its documentation).
 - `<C-o>`: Go back to the previous page.
 - `q` or `<ESC>`: Close the cppman window.
 ## Features
 - Asynchronous execution for non-blocking UI.
 - Caching of results for faster subsequent lookups.
 - Prefetching of top N options when multiple matches are found.
 - Scrollable buffer with syntax highlighting.
 Note: This plugin requires the `cppman` CLI tool to be installed and available in your PATH.
 Let me know if you need any further adjustments.
