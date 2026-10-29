<p align="center">
  <img src="assets/logo.png" alt="nuntio.nvim logo" width="180" />
</p>

<h1 align="center">nuntio.nvim</h1>

<p align="center">
  A fast, fully open-source, pure Lua HTTP client for Neovim.
</p>

<p align="center">
  <a href="https://github.com/ericklima-ca/nuntio.nvim/actions"><img src="https://github.com/ericklima-ca/nuntio.nvim/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://neovim.io"><img src="https://img.shields.io/badge/Neovim-%E2%89%A5%200.10-green.svg" alt="Neovim >= 0.10" /></a>
</p>

Powered by native `curl`, `tree-sitter-http`, and Neovim's async system API.

---

## ✨ Features

- **Standard `.http` / `.rest` Syntax**: Compatible with JetBrains HTTP Client, VS Code REST Client, and Kulala files.
- **Pure Lua & cURL**: Only requires standard `curl` and Neovim $\ge$ 0.10. No external proprietary daemon or license servers.
- **In-Process Language Server (LSP)**: Pure Lua `vim.lsp.start` client with zero binary dependencies:
  - **Autocompletion**: HTTP methods, standard RFC headers, MIME types, dynamic `$vars`, active environment variables, directives (`# @name`, `# @curl-*`), and chained response fields.
  - **Hover Tooltips**: Live variable inspection displaying resolved values, source environment files (`http-client.env.json`, `.env.local`), and RFC header documentation.
  - **Real-time Diagnostics**: Flags missing external body files (`< ./missing.json`), undefined variables, and empty request URLs.
  - **Document Symbols & Outline**: Outlines all request blocks and document variables natively in Telescope, Snacks, and aerial.
  - **Code Actions**: Quick triggers to run requests, copy as cURL, switch environments, and inspect cookies.
  - **Document Formatter (`textDocument/formatting`)**: Format `.http` files with `gq` or `:Nuntio format`—uppercases methods, aligns headers, formats JSON bodies, and safely preserves embedded template variables (`{{vars}}`).
- **Response Assertions (`# @assert`)**: Turn `.http` files into API tests with checks on status, headers, JSON body fields (JSONPath), and latency. Results appear inline (`✔ 201 (45ms) · 5/5 passed`), in a dedicated **Tests** tab, and in the `:Nuntio run_all` summary. Malformed assertions are flagged by the LSP.
- **Live Response Filter (`F` / JQ / JSONPath)**: Press `F` or `f` in the response window to live-filter large JSON responses in real-time with JQ or JSONPath syntax. Copy the query directly to your clipboard with `<C-y>` for chaining.
- **Advanced Fuzzy Request Picker (`:Nuntio find` / `<leader>rf`)**:
  - Search requests across the **current buffer** or the entire **workspace** (`**/*.http`).
  - Seamless adapters for **Telescope**, **Snacks.picker**, **FZF-Lua**, or a **Built-in Dual-Pane Floating Window** with live preview and `<C-r>` immediate execution.
  - Press `<Tab>` inside the picker to toggle dynamically between buffer and workspace search.
- **Request Chaining & Dependency Graphs**: Reference previous responses via `{{auth.response.body.$.token}}` or dynamic session variables (`# @env-json-key`). Prerequisite requests are automatically resolved and executed.
- **Multi-Tier Environment Management**: Discovers and merges `http-client.env.json`, `http-client.private.env.json`, `.env`, `.env.local`, and OS environment variables up the directory hierarchy. Switch environments on the fly with `:Nuntio env`.
- **Dynamic Variables**: Built-in support for `{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, `{{$date}}`, and `{{$randomInt}}`.
- **Simplified Multipart Form-Data**: Clean zero-boundary syntax (`title = val`, `file = < ./path; type=...`) with semantic syntax highlighting.
- **cURL Interoperability**:
  - `Copy as cURL` (`:Nuntio curl`): copies any request under your cursor as an executable `curl` command.
  - `Paste from cURL` (`:Nuntio from_curl`): converts clipboard curl commands into `.http` format.
- **Clean Response UI**:
  - Split or floating window.
  - Winbar tabs: `Body`, `Headers`, `All`, `Chain`, `Stats`, `Raw`.
  - Automatic JSON/HTML/XML syntax formatting.
  - Inline extmark icons and latency timings on request lines (`⏳ Sending...`, `✔ 200 (45ms)`).

---

## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ericklima-ca/nuntio.nvim",
  ft = { "http", "rest" },
  opts = {
    default_env = "dev",
    ui = {
      display_mode = "split",    -- "split" or "float"
      split_direction = "right", -- "right" or "below"
      width = 0.45,
      winbar = true,
      picker = "auto",           -- "auto", "telescope", "snacks", "fzf_lua", "builtin", "ui_select"
      find_scope = "buffer",     -- "buffer" or "workspace"
    },
  },
  keys = {
    { "<leader>rr", "<cmd>Nuntio run<cr>", desc = "Run HTTP Request" },
    { "<leader>ra", "<cmd>Nuntio run_all<cr>", desc = "Run All Requests" },
    { "<leader>rp", "<cmd>Nuntio replay<cr>", desc = "Replay Last Request" },
    { "<leader>ri", "<cmd>Nuntio inspect<cr>", desc = "Inspect Request" },
    { "<leader>rc", "<cmd>Nuntio curl<cr>", desc = "Copy as cURL" },
    { "<leader>rC", "<cmd>Nuntio from_curl<cr>", desc = "Paste from cURL" },
    { "<leader>re", "<cmd>Nuntio env<cr>", desc = "Select Environment" },
    { "<leader>rf", "<cmd>Nuntio find<cr>", desc = "Find / Browse Requests" },
    { "<leader>rF", "<cmd>Nuntio format<cr>", desc = "Format HTTP Document" },
    { "<leader>rj", "<cmd>Nuntio cookies<cr>", desc = "Manage Cookie Jar" },
    { "<leader>rh", "<cmd>Nuntio history<cr>", desc = "Response History" },
    { "<leader>rd", "<cmd>Nuntio diff<cr>", desc = "Diff Previous Response" },
    { "<leader>rq", "<cmd>Nuntio close<cr>", desc = "Close Response View" },
    { "<leader>rs", "<cmd>Nuntio scratchpad<cr>", desc = "HTTP Scratchpad" },
    { "]r", "<cmd>Nuntio next<cr>", desc = "Next HTTP Request" },
    { "[r", "<cmd>Nuntio prev<cr>", desc = "Previous HTTP Request" },
  },
}
```

Make sure the Tree-sitter `http` grammar is installed for syntax highlighting:

```vim
:TSInstall http
```

---

## ⚙️ Configuration

All configuration options with their defaults:

```lua
require("nuntio").setup({
  -- Default environment when none selected
  default_env = "dev",

  -- Environment selection scope: "b" (per-buffer) or "g" (global)
  environment_scope = "b",

  -- Path to curl binary (defaults to system curl)
  curl_path = "curl",

  -- Request timeout in milliseconds
  timeout = 60000,

  -- Automatically execute unexecuted prerequisite requests in chains
  auto_run_dependencies = true,

  -- Inline execution icons on method lines
  inlay_icons = true,
  icons = {
    loading = "⏳",
    done = "✔",
    error = "✘",
  },

  -- Visible section dividers in .http buffers
  dividers = {
    enabled = true,
    icon = "󰖟",         -- Icon on standard request divider rules
    shared_icon = "󰒘",  -- Icon on ### Shared divider rules
    hint = true,        -- Display [▶ <CR>] run badge
    style = "above",    -- "above" (header rule), "eol" (inline extension), or "both"
  },

  -- Built-in zero-binary Language Server (LSP)
  lsp = {
    enable = true,           -- Enable in-process LSP client (vim.lsp.start)
    diagnostics = true,      -- Flag missing files (< ./file) and undefined variables
    completion = true,       -- Auto-complete headers, MIME types, env vars, methods
    hover = true,            -- Inspect variable values, sources, and RFC header docs
    document_symbols = true, -- Outline request blocks in Telescope, Snacks, and aerial
  },

  -- Response view UI
  ui = {
    display_mode = "split",    -- "split" or "float"
    split_direction = "right", -- "right" or "below"
    width = 0.45,
    height = 0.45,
    default_view = "body",     -- "body", "headers", "headers_body", "chain", "stats", "verbose"
    winbar = true,             -- Responsive clickable tab bar with live metrics
    max_response_size = 1048576, -- 1MB limit before truncating large responses
    picker = "auto",           -- "auto", "telescope", "snacks", "fzf_lua", "builtin", "ui_select"
    find_scope = "buffer",     -- Default search scope: "buffer" or "workspace"
  },
})
```

---

## 🔍 Interactive Fuzzy Request Picker

Search, preview, and run HTTP requests across your project:

- **Buffer Scope**: `:Nuntio find buffer` (searches current file)
- **Workspace Scope**: `:Nuntio find workspace` (scans all `*.http` and `*.rest` files in project)
- **Toggle Scopes**: Press `<Tab>` inside the picker to switch dynamically between buffer and workspace.
- **Instant Execution**: Press `<C-r>` or `<C-e>` to **execute the request immediately** directly from the picker without jumping.

Supports **Telescope**, **Snacks.picker**, **FZF-Lua**, and includes a **Built-in Dual-Pane Floating Window** with live syntax-highlighted request preview.

---

## ⚡ Live Response Filter (JQ / JSONPath)

When inspecting large JSON payloads:

1. Press `F` or `f` in the response window (or `:Nuntio filter`).
2. Type any JSONPath (`$.users[0].name`) or JQ expression (`.items[] | {id, title}`).
3. The response window live-evaluates and displays matching items in real time.
4. Press `<C-y>` to copy the filter path to your clipboard for easy request chaining.
5. Press `X` (or `:Nuntio filter_clear`) to restore the full response body.

---

## 🧹 Document Formatter

`nuntio.nvim` implements a built-in LSP document formatter (`textDocument/formatting`):

- Format buffer with `gq` or `:Nuntio format` / `:NuntioFormat`.
- Uppercases HTTP methods (`get` $\rightarrow$ `GET`).
- Standardizes header colon spacing (`Content-Type: application/json`).
- 2-space indents JSON request bodies.
- **Safely preserves embedded template variables** (`{{$uuid}}`, `{{token}}`) inside JSON payloads without escaping or corruption.
- Standardizes clean spacing around `###` request boundary headers.

---

## 🔐 Environments & Secrets

`nuntio.nvim` automatically discovers and merges environment files up the directory tree to the workspace root.

### Supported Formats

| Format                           | File Pattern                                     | Typical Use Case                                                         |
| :------------------------------- | :----------------------------------------------- | :----------------------------------------------------------------------- |
| **JetBrains Public JSON**        | `http-client.env.json`                           | Committed to Git; public URLs, environments (`dev`, `staging`, `prod`)   |
| **JetBrains Private JSON**       | `http-client.private.env.json`                   | Gitignored; secret API keys, client credentials, tokens                  |
| **Standard Dotenv**              | `.env`, `.env.<env>`                             | Team-wide defaults (`.env`) or per-env targets (`.env.dev`, `.env.prod`) |
| **Private Dotenv Overrides**     | `.env.local`, `.env.<env>.local`, `.env.private` | Local gitignored developer secrets (Vite / Next.js style)                |
| **OS Environment Variables**     | `export KEY=val`                                 | System credentials and shell-exported tokens                             |
| **Interactive In-Editor Secret** | `# @secret <name>`                               | Zero-disk masked prompt; never touches filesystem                        |

### Variable Precedence (Lowest to Highest)

When the same variable exists across sources, `nuntio.nvim` resolves conflicts in this strict hierarchy:

1. **OS Environment Variables** (`vim.fn.environ()`)
2. **Base Dotenv** (`.env`)
3. **Environment Dotenv** (`.env.<current_env>`)
4. **Private Dotenv Overrides** (`.env.local`, `.env.<current_env>.local`, `.env.private`)
5. **Shared & Public JSON** (`http-client.env.json`)
6. **Private JSON Overrides** (`http-client.private.env.json`)
7. **Document In-File Variables** (`@var = value` at the top of the file)
8. **Interactive Request Prompts** (`# @prompt`, `# @secret`)

---

## 🛠 Commands & Keymaps

### User Commands

| Command                 | Action                                                       |
| ----------------------- | ------------------------------------------------------------ |
| `:Nuntio run`           | Run request under cursor (or visual selection)               |
| `:Nuntio run_all`       | Run all requests in the buffer sequentially                  |
| `:Nuntio replay`        | Re-run the last executed request from any buffer             |
| `:Nuntio inspect`       | Preview resolved request and curl command without sending    |
| `:Nuntio curl`          | Copy request under cursor as an executable curl command      |
| `:Nuntio from_curl`     | Convert clipboard or pasted curl command to `.http` format   |
| `:Nuntio env`           | Open environment switcher (`vim.ui.select`)                  |
| `:Nuntio find [scope]`  | Fuzzy search requests (`buffer` or `workspace`)              |
| `:Nuntio format`        | Format current document with LSP formatter                   |
| `:NuntioFormat`         | Alias to format current document                             |
| `:Nuntio filter`        | Open interactive live response filter prompt (JQ / JSONPath) |
| `:Nuntio filter_clear`  | Clear response filter and restore full payload               |
| `:Nuntio next` / `prev` | Jump cursor to next / previous request block                 |
| `:Nuntio scratchpad`    | Open scratchpad buffer with sample HTTP requests             |
| `:Nuntio cookies`       | Inspect and manage active session cookie jar                 |
| `:Nuntio history`       | Open interactive response history picker                     |
| `:Nuntio diff`          | Open side-by-side diff comparing last two responses          |
| `:Nuntio close`         | Close the response view window                               |
| `:Nuntio clear_history` | Clear stored response history                                |
| `:Nuntio lsp_restart`   | Restart in-process language server sessions                  |

### Response Window Keymaps

Inside the response view buffer:

- `]` / `[`: Quick switch to **Next / Previous View Tab**
- `<Tab>` / `<S-Tab>`: Cycle forward / backward through available tabs
- `b` / `B`: Jump directly to **Body** (pure payload at line 1)
- `h` / `H`: Jump directly to **Headers**
- `a` / `A`: Jump directly to **All** (Headers + Body)
- `c` / `C`: Jump directly to **Chain** (Execution timeline & variable flow)
- `t`: Jump directly to **Tests** (`# @assert` results with expected vs actual values)
- `s` / `S`: Jump directly to **Stats** (Detailed latency & transfer breakdown)
- `v` / `V`: Jump directly to **Raw** (Raw cURL trace)
- `F` / `f`: Open interactive **Live Filter** (JQ / JSONPath)
- `X`: Clear active response filter
- `H`: Open interactive **History Picker** with timestamps and status badges
- `D`: Open side-by-side **Vimdiff** comparing current response against previous
- `r`: Replay current request
- `y`: Yank response body to system clipboard
- `q` / `<Esc>`: Close response window

---

## 📝 Syntax Cheatsheet

### 1. Global Shared Defaults (`### Shared`)

Headers and variables declared under `### Shared` are automatically merged into every request in the file:

```http
### Shared
User-Agent: nuntio.nvim/1.0
Authorization: Bearer {{SECRET_API_TOKEN}}
X-Environment: {{ENV_NAME}}
```

### 2. Variables & Built-in Dynamic Generators

```http
@baseUrl = https://api.example.com
@apiVersion = v1

POST {{baseUrl}}/{{apiVersion}}/orders
Content-Type: application/json

{
  "order_id": "{{$uuid}}",
  "created_at": "{{$isoTimestamp}}",
  "nonce": {{$randomInt 1000 9999}}
}
```

### 3. Request Chaining & Dependency Graphs

`nuntio.nvim` automatically builds execution chains and runs unexecuted prerequisites.

```http
### Login
# @name auth
POST {{baseUrl}}/login
Content-Type: application/json

{ "username": "admin", "password": "{{admin_pass}}" }

### Fetch Protected Profile (Auto-runs 'auth' first if not yet run)
GET {{baseUrl}}/profile
Authorization: Bearer {{auth.response.body.$.access_token}}
```

### 4. Simplified Multipart Form-Data (Zero Boundary Clutter)

Skip manual MIME boundaries and CRLF hyphens:

```http
POST {{baseUrl}}/upload
Content-Type: multipart/form-data

title = Quarterly Financial Report
author = Finance Team
file = < ./data/report.pdf; type=application/pdf
```

### 5. Custom cURL Flags

Pass low-level curl flags directly on any request block:

```http
# @curl-location
# @curl-connect-timeout 10
# @curl-insecure
# @no-cookie-jar
GET https://self-signed.local/data
```

### 6. Response Assertions (`# @assert`)

Declare checks above the request line. They run when the response arrives:

```http
### Create user
# @assert status == 201
# @assert header Content-Type contains application/json
# @assert body $.id exists
# @assert body $.name == "{{userName}}"
# @assert body $.tags contains admin
# @assert duration < 500
POST {{baseUrl}}/users
Content-Type: application/json

{ "name": "{{userName}}", "tags": ["admin"] }
```

Syntax: `# @assert <subject> [arg] <operator> [value]`

| Subject | Argument | Actual value |
|---|---|---|
| `status` | — | HTTP status code |
| `header` | header name (case-insensitive) | header value |
| `body` | optional JSONPath (`$.items[0].id`) | JSON field, or the raw body when omitted |
| `duration` | — | total request time in ms |

Operators: `==`, `!=`, `>`, `<`, `>=`, `<=`, `contains`, `!contains`, `matches` (Lua pattern), `exists`, `!exists`.

- Values are typed: `42`, `true`, `null`, `"quoted text"` or bare text. `{{variables}}` are interpolated.
- `contains` checks substrings, or membership when the value is a JSON array.
- Assertions under `### Shared` apply to every request in the file (e.g. `# @assert status < 500`).
- When a request has assertions, they decide pass/fail instead of the status code, so `# @assert status == 404` makes a 404 a passing test.
- Assertions see the original response, before any `# @jq` transformation.

---

## 🧪 Testing

To run the automated unit test suite locally:

```bash
nvim --clean -u NONE -l tests/run_tests.lua
```

---

## 📄 License

MIT License. Copyright (c) 2026 Erick Amorim.
