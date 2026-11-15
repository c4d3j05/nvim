" ntree workspace integration -------------------------------------------------
" <leader>ws  Telescope picker: switch nvim's cwd to a workspace (or main)
" <leader>wm  jump back to the main checkout
" <leader>wn  create a new workspace (ntree new <branch> -m <description>) and switch to it
" <leader>wd  set or clear the current workspace's description
" <leader>wt  list the terminals (;tn) with the workspace each is in and its
"             description; pick one to switch to it. Terminal tabs also show
"             the workspace name.

lua << EOF
local function ntree_main_root()
  local lines = vim.fn.systemlist('git worktree list --porcelain')
  if vim.v.shell_error ~= 0 then return nil end
  for _, l in ipairs(lines) do
    local p = l:match('^worktree%s+(.+)$')
    if p then return p end
  end
  return nil
end

-- The workspace nvim's cwd is in, if any: <main>/.ntree/<name>[/...]
local function ntree_current(main_root)
  local prefix = main_root .. '/.ntree/'
  local cwd = vim.fn.getcwd()
  if cwd:sub(1, #prefix) ~= prefix then return nil end
  return cwd:sub(#prefix + 1):match('^[^/]+')
end

-- The workspaces of the repo at main_root: name -> { branch, port, running,
-- desc }. Live status and checked-out branch come from `ntree list` (it
-- verifies pids and asks git); ports and description from state.json.
local function ntree_workspaces(main_root)
  local live = {}
  local cmd = 'cd ' .. vim.fn.shellescape(main_root) .. ' && ntree list 2>/dev/null'
  for _, l in ipairs(vim.fn.systemlist(cmd)) do
    local name, branch = l:match('^(%S+)%s+(%S+)')
    if name and name ~= 'NAME' and name ~= '(root)' then
      live[name] = { branch = branch, running = l:find(' running ', 1, true) ~= nil }
    end
  end

  local result = {}
  local state_path = main_root .. '/.ntree/state.json'
  if vim.fn.filereadable(state_path) == 1 then
    local ok, data = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(state_path), '\n'))
    if ok and data and data.workspaces then
      for name, ws in pairs(data.workspaces) do
        local l = live[name] or {}
        local desc = ws.desc
        if desc == vim.NIL or desc == '' then desc = nil end
        result[name] = {
          branch = l.branch or ws.branch,
          port = type(ws.ports) == 'table' and ws.ports[1] or nil,
          running = l.running,
          desc = desc,
        }
      end
    end
  end
  return result
end

-- A workspace's path is always <main>/.ntree/<name>.
local function ntree_entries()
  local main_root = ntree_main_root()
  if not main_root then return nil end
  local current = ntree_current(main_root)
  local entries = { { name = 'main', branch = '(main checkout)', path = main_root, current = current == nil } }
  local workspaces = ntree_workspaces(main_root)
  local names = vim.tbl_keys(workspaces)
  table.sort(names)
  for _, name in ipairs(names) do
    local ws = workspaces[name]
    table.insert(entries, {
      name = name, branch = ws.branch, port = ws.port, running = ws.running, desc = ws.desc,
      path = main_root .. '/.ntree/' .. name, current = name == current,
    })
  end
  return entries
end

-- The working directory of each terminal's shell (it follows `cd` in the shell;
-- nvim's own idea of the buffer's directory doesn't). One lsof call for all of
-- them on macOS, /proc on Linux. Args: { [tab] = buf }. Returns { [buf] = cwd }.
local function term_cwds(term_bufs)
  local by_pid, pids, out = {}, {}, {}
  for _, buf in pairs(term_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      local ok, pid = pcall(vim.fn.jobpid, vim.bo[buf].channel)
      if ok and pid and pid > 0 then by_pid[pid] = buf; table.insert(pids, pid) end
    end
  end
  if #pids == 0 then return out end
  if vim.fn.has('linux') == 1 then
    for pid, buf in pairs(by_pid) do out[buf] = vim.uv.fs_readlink('/proc/' .. pid .. '/cwd') end
  else
    local pid
    for _, l in ipairs(vim.fn.systemlist({ 'lsof', '-a', '-d', 'cwd', '-p', table.concat(pids, ','), '-Fpn' })) do
      local p = l:match('^p(%d+)')
      if p then pid = tonumber(p) end
      local n = l:match('^n(.+)')
      if n and pid and by_pid[pid] then out[by_pid[pid]] = n end
    end
  end
  return out
end

-- <main root>, <workspace name> when path is inside <main>/.ntree/<name>.
local function workspace_of(path)
  if not path then return nil end
  return path:match('^(.*)/%.ntree/([^/]+)')
end

-- Hook for the terminal manager (maps.vim): name each tab after the workspace
-- its shell is in. Args: { [tab] = buf }. Returns { [tab] = name }.
function TermTabNames(term_bufs)
  local cwds, names = term_cwds(term_bufs), {}
  for tab, buf in pairs(term_bufs) do
    local _, name = workspace_of(cwds[buf])
    names[tab] = name
  end
  return names
end

function NtreeSwitch()
  local entries = ntree_entries()
  if not entries then
    vim.notify('ntree: not inside a git repo', vim.log.levels.ERROR)
    return
  end

  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    vim.notify('ntree: telescope not available', vim.log.levels.ERROR)
    return
  end
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  pickers.new({}, {
    prompt_title = 'ntree workspaces',
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e)
        local mark = e.current and '*' or ' '
        local status = e.running and 'running' or ''
        local port = e.port and (':' .. e.port) or ''
        local display = string.format('%s %-18s %-22s %-6s %-8s %s',
          mark, e.name, e.branch or '', port, status, e.desc or '')
        return {
          value = e,
          display = display,
          ordinal = e.name .. ' ' .. (e.branch or '') .. ' ' .. (e.desc or ''),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection then
          vim.cmd('cd ' .. vim.fn.fnameescape(selection.value.path))
          vim.cmd('echo "ntree: switched to ' .. selection.value.name .. '"')
          if vim.fn.exists(':NERDTreeCWD') == 2 then vim.cmd('silent! NERDTreeCWD') end
        end
      end)
      return true
    end,
  }):find()
end

function NtreeTerminals()
  local terms, current = {}, nil
  if TerminalList then terms, current = TerminalList() end
  local tabs = {}
  for tab, buf in pairs(terms) do
    if vim.api.nvim_buf_is_valid(buf) then table.insert(tabs, tab) end
  end
  table.sort(tabs)
  if #tabs == 0 then
    vim.notify('ntree: no terminals open — ;tn opens one', vim.log.levels.INFO)
    return
  end

  local cwds, by_root, rows = term_cwds(terms), {}, {}
  for _, tab in ipairs(tabs) do
    local cwd = cwds[terms[tab]]
    local root, name = workspace_of(cwd)
    local row = { tab = tab, cwd = cwd and vim.fn.fnamemodify(cwd, ':~') or '?' }
    if root then
      by_root[root] = by_root[root] or ntree_workspaces(root)
      local ws = by_root[root][name] or {}
      row.name, row.branch, row.port, row.running, row.desc = name, ws.branch, ws.port, ws.running, ws.desc
    end
    table.insert(rows, row)
  end

  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    vim.notify('ntree: telescope not available', vim.log.levels.ERROR)
    return
  end
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  pickers.new({}, {
    prompt_title = 'terminals',
    finder = finders.new_table({
      results = rows,
      entry_maker = function(r)
        local mark = r.tab == current and '*' or ' '
        local display
        if r.name then
          display = string.format('%s %d  %-18s %-22s %-6s %-8s %s', mark, r.tab, r.name, r.branch or '',
            r.port and (':' .. r.port) or '', r.running and 'running' or '', r.desc or '')
        else
          display = string.format('%s %d  %s', mark, r.tab, r.cwd)
        end
        return {
          value = r,
          display = display,
          ordinal = r.tab .. ' ' .. (r.name or '') .. ' ' .. (r.branch or '') .. ' ' .. (r.desc or r.cwd),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection then SwitchTerminal(selection.value.tab) end
      end)
      return true
    end,
  }):find()
end

function NtreeMain()
  local main_root = ntree_main_root()
  if main_root then
    vim.cmd('cd ' .. vim.fn.fnameescape(main_root))
    vim.cmd('echo "ntree: back to main checkout"')
  else
    vim.notify('ntree: not inside a git repo', vim.log.levels.ERROR)
  end
end

function NtreeNew()
  local branch = vim.fn.input('ntree new branch: ')
  if branch == '' then return end
  local desc = vim.fn.input('description (optional): ')
  local main_root = ntree_main_root()
  if not main_root then
    vim.notify('ntree: not inside a git repo', vim.log.levels.ERROR)
    return
  end
  local cmd = { 'ntree', 'new', branch }
  if desc ~= '' then vim.list_extend(cmd, { '-m', desc }) end
  local errors = {}
  vim.notify('ntree: creating workspace ' .. branch .. ' ...')
  vim.fn.jobstart(cmd, {
    cwd = main_root,
    stderr_buffered = true,
    on_stderr = function(_, data)
      for _, l in ipairs(data or {}) do
        if l:match('^error:') or l:match('^fatal:') then table.insert(errors, l) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          local path = main_root .. '/.ntree/' .. branch:gsub('/', '-')
          vim.cmd('cd ' .. vim.fn.fnameescape(path))
          vim.notify('ntree: switched to ' .. branch)
        else
          vim.notify('ntree new failed: ' .. (errors[1] or ('exit ' .. code)), vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

function NtreeDesc()
  local main_root = ntree_main_root()
  local name = main_root and ntree_current(main_root)
  if not name then
    vim.notify('ntree: not inside a workspace (cd into one with <leader>ws)', vim.log.levels.WARN)
    return
  end
  local cwd_cmd = 'cd ' .. vim.fn.shellescape(main_root) .. ' && '
  local old = vim.fn.trim(vim.fn.system(cwd_cmd .. 'ntree desc ' .. vim.fn.shellescape(name)))
  local text = vim.fn.input('description for ' .. name .. ' (empty clears): ', old)
  local arg = text == '' and '--clear' or text
  local out = vim.fn.system(cwd_cmd .. 'ntree desc ' .. vim.fn.shellescape(name) .. ' ' .. vim.fn.shellescape(arg) .. ' 2>&1')
  if vim.v.shell_error ~= 0 then
    vim.notify('ntree desc failed: ' .. vim.fn.trim(out), vim.log.levels.ERROR)
  else
    vim.notify('ntree: ' .. (text == '' and ('cleared ' .. name .. "'s description") or (name .. ': ' .. text)))
  end
end
EOF

nnoremap <leader>ws :lua NtreeSwitch()<CR>
nnoremap <leader>wm :lua NtreeMain()<CR>
nnoremap <leader>wn :lua NtreeNew()<CR>
nnoremap <leader>wd :lua NtreeDesc()<CR>
nnoremap <leader>wt :lua NtreeTerminals()<CR>
tnoremap <leader>wt <C-\><C-n>:lua NtreeTerminals()<CR>
