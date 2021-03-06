-- nvim-lspfuzzy
-- By Olivier Roques
-- github.com/ojroques

-------------------- VARIABLES -----------------------------
local api, cmd, fn, g, vim = vim.api, vim.cmd, vim.fn, vim.g, vim
local lsp = require 'vim.lsp'
local current_actions = {}  -- hold all currently available code actions

-------------------- OPTIONS -------------------------------
local opts = {
  methods = 'all',         -- either 'all' or a list of LSP methods
  fzf_preview = {          -- arguments to the FZF '--preview-window' option
    'right:+{2}-/2'          -- preview on the right and centered on entry
  },
  fzf_action = {           -- FZF actions
    ['ctrl-t'] = 'tabedit',  -- go to location in a new tab
    ['ctrl-v'] = 'vsplit',   -- go to location in a vertical split
    ['ctrl-x'] = 'split',    -- go to location in a horizontal split
  },
  fzf_modifier = ':~:.',   -- format FZF entries, see |filename-modifiers|
  fzf_trim = true,         -- trim FZF entries
}

-------------------- HELPERS -------------------------------
local function echo(hlgroup, msg)
  cmd(string.format('echohl %s', hlgroup))
  cmd(string.format('echo "[lspfuzzy] %s"', msg))
  cmd('echohl None')
end

local function lsp_to_fzf(item)
  local filename = fn.fnamemodify(item.filename, opts.fzf_modifier)
  local text = opts.fzf_trim and vim.trim(item.text) or item.text
  return string.format('%s:%s:%s: %s', filename, item.lnum, item.col, text)
end

local function fzf_to_lsp(entry)
  local split = vim.split(entry, ':')
  local uri = vim.uri_from_fname(fn.fnamemodify(split[1], ':p'))
  local line = tonumber(split[2]) - 1
  local column = tonumber(split[3]) - 1
  local position = {line = line, character = column}
  local range = {start = position, ['end'] = position}
  return {uri = uri, range = range}
end

-------------------- FZF FUNCTIONS -------------------------
local function jump(entries)
  if not entries or #entries < 2 then return end
  local key = table.remove(entries, 1)
  local locations = vim.tbl_map(fzf_to_lsp, entries)
  -- A FZF action was used
  if opts.fzf_action[key] then
    cmd(opts.fzf_action[key])
  end
  -- Use the quickfix list to store remaining locations
  if #locations > 1 then
    lsp.util.set_qflist(lsp.util.locations_to_items(locations))
    cmd 'copen'
    cmd 'wincmd p'
  end
  lsp.util.jump_to_location(locations[1])
end

local function apply_action(entries)
  if not entries or #entries < 2 then return end
  local action = current_actions[entries[2]]
  if action.edit then
    lsp.util.apply_workspace_edit(action.edit)
  elseif type(action.command) == "table" then
    lsp.buf.execute_command(action.command)
  else
    lsp.buf.execute_command(action)
  end
end

local function build_fzf_opts(preview, multi)
  local fzf_opts = {'--ansi', '--delimiter', ':'}
  -- Enable multi-selection
  if multi then
    vim.list_extend(fzf_opts, {
      '--bind', 'ctrl-a:select-all,ctrl-d:deselect-all',
      '--multi',
    })
  end
  -- Enable FZF actions
  if opts.fzf_action and not vim.tbl_isempty(opts.fzf_action) then
    vim.list_extend(fzf_opts, {
      '--expect', table.concat(vim.tbl_keys(opts.fzf_action), ',')
    })
  end
  -- Enable preview with fzf.vim
  if g.loaded_fzf_vim and preview and opts.fzf_preview then
    local args = fn['fzf#vim#with_preview'](unpack(opts.fzf_preview)).options
    vim.list_extend(fzf_opts, args)
  end
  return fzf_opts
end

local function fzf(source, sink, preview, multi)
  if not g.loaded_fzf then
    echo('WarningMsg', 'FZF is not loaded!')
    return
  end
  local fzf_opts = build_fzf_opts(preview, multi)
  local fzf_opts_wrap = fn['fzf#wrap']({source = source, options = fzf_opts})
  fzf_opts_wrap['sink*'] = sink  -- 'sink*' needs to be defined outside wrap()
  fn['fzf#run'](fzf_opts_wrap)
end

-------------------- LSP HANDLERS --------------------------
local function symbol_handler(_, _, result, _, bufnr)
  if not result or vim.tbl_isempty(result) then
    echo('None', 'No symbol found.')
    return
  end
  local items = lsp.util.symbols_to_items(result, bufnr)
  local source = vim.tbl_map(lsp_to_fzf, items)
  fzf(source, jump, true, true)
end

local function location_handler(_, _, result)
  if not result or vim.tbl_isempty(result) then
    echo('None', 'No reference found.')
    return
  end
  -- Jump immediately if not a list
  if not vim.tbl_islist(result) then
    lsp.util.jump_to_location(result)
    return
  end
  -- Jump immediately if there is only one location
  if #result == 1 then
    lsp.util.jump_to_location(result[1])
    return
  end
  local items = lsp.util.locations_to_items(result)
  local source = vim.tbl_map(lsp_to_fzf, items)
  fzf(source, jump, true, true)
end

local function make_call_hierarchy_handler(direction)
  return function(_, _, result)
    if not result or vim.tbl_isempty(result) then
      echo('None', 'No call found.')
      return
    end
    local items = {}
    for _, call_hierarchy_call in pairs(result) do
      local call_hierarchy_item = call_hierarchy_call[direction]
      for _, range in pairs(call_hierarchy_call.fromRanges) do
        table.insert(items, {
          filename = vim.uri_to_fname(call_hierarchy_item.uri),
          text = call_hierarchy_item.name,
          lnum = range.start.line + 1,
          col = range.start.character + 1,
        })
      end
    end
    local source = vim.tbl_map(lsp_to_fzf, items)
    fzf(source, jump, true, true)
  end
end

local function code_action_handler(_, _, actions)
  if not actions or vim.tbl_isempty(actions) then
    echo('None', 'No code action available.')
    return
  end
  local choices = {}
  current_actions = {}
  for i, action in ipairs(actions) do
    local text = string.format("%d. %s", i, action.title)
    table.insert(choices, text)
    current_actions[text] = action
  end
  fzf(choices, apply_action, false, false)
end

-------------------- COMMANDS ------------------------------
local function diagnostics_cmd(diagnostics)
  local items = {}
  for bufnr, diags in pairs(diagnostics) do
    for _, diag in ipairs(diags) do
      table.insert(items, {
        filename = api.nvim_buf_get_name(bufnr),
        text = diag.message,
        lnum = diag.range.start.line + 1,
        col = diag.range.start.character + 1,
      })
    end
  end
  if vim.tbl_isempty(items) then
    echo('None', 'No diagnostic found.')
    return
  end
  local source = vim.tbl_map(lsp_to_fzf, items)
  fzf(source, jump, true, true)
end

-------------------- SETUP ---------------------------------
local handlers = {
  ['callHierarchy/incomingCalls'] = make_call_hierarchy_handler('from'),
  ['callHierarchy/outgoingCalls'] = make_call_hierarchy_handler('to'),
  ['textDocument/codeAction'] = code_action_handler,
  ['textDocument/declaration'] = location_handler,
  ['textDocument/definition'] = location_handler,
  ['textDocument/documentSymbol'] = symbol_handler,
  ['textDocument/implementation'] = location_handler,
  ['textDocument/references'] = location_handler,
  ['textDocument/typeDefinition'] = location_handler,
  ['workspace/symbol'] = symbol_handler,
}

local function load_fzf_opts()
  local fzf_opts = {}
  fzf_opts.fzf_action = g.fzf_action
  fzf_opts.fzf_preview = g.fzf_preview_window
  if type(fzf_opts.fzf_preview) == 'string' then
    fzf_opts.fzf_preview = {fzf_opts.fzf_preview}
  end
  return fzf_opts
end

local function setup(user_opts)
  -- Load FZF and user settings
  opts = vim.tbl_extend('keep', load_fzf_opts(), opts)
  opts = vim.tbl_extend('keep', user_opts, opts)
  -- Set LSP handlers
  if opts.methods == 'all' then opts.methods = vim.tbl_keys(handlers) end
  for _, m in ipairs(opts.methods) do lsp.handlers[m] = handlers[m] end
end

------------------------------------------------------------
return {
  diagnostics = function(bufnr)
    bufnr = tonumber(bufnr)
    diagnostics_cmd({[bufnr] = lsp.diagnostic.get(bufnr)})
  end,
  diagnostics_all = function()
    diagnostics_cmd(lsp.diagnostic.get_all())
  end,
  setup = setup,
}
