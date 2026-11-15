" ntree workspace integration -------------------------------------------------
" <leader>ws  pick a workspace (or main) and switch to it
" <leader>wm  switch back to the main checkout
" <leader>wn  create a new workspace (ntree new <branch> -m <description>) and switch to it
" <leader>wd  set or clear the current workspace's description
"
" Switching moves everything at once: nvim's cwd, NERDTree, and the open files
" (each is swapped for the same file in the target checkout). It also selects
" the ;tn terminal whose shell is in that checkout. The other way round,
" switching terminals (;1-5, Ctrl-Tab) switches the code to the checkout that
" terminal is in. Terminal tabs are named after their workspace.

lua << EOF
-- The main checkout of the repo at <path> (default: nvim's cwd).
local function ntree_main_root(path)
  local lines = vim.fn.systemlist({ 'git', '-C', path or vim.fn.getcwd(), 'worktree', 'list', '--porcelain' })
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

local function real(path)
  return path and path ~= '' and (vim.uv.fs_realpath(path) or path) or nil
end

-- The checkout <path> is in: <main>/.ntree/<name> for a workspace, main_root
-- for the main checkout, nil when it's outside the repo.
local function checkout_of(path, main_root)
  if not path or not main_root then return nil end
  local root, name = workspace_of(path)
  if root == main_root then return main_root .. '/.ntree/' .. name end
  if path == main_root or path:sub(1, #main_root + 1) == main_root .. '/' then return main_root end
  return nil
end

-- Select (without focusing) the lowest-numbered ;tn terminal whose shell is in <dir>.
local function select_terminal_in(dir, main_root)
  if not (TerminalList and SelectTerminal) then return end
  local terms, current = TerminalList()
  local cwds, tabs = term_cwds(terms), vim.tbl_keys(terms)
  table.sort(tabs)
  for _, tab in ipairs(tabs) do
    if checkout_of(cwds[terms[tab]], main_root) == dir then
      if tab ~= current then SelectTerminal(tab) end
      return
    end
  end
end

-- Point nvim at another checkout <dir> (main or a workspace): cwd, NERDTree and
-- open files. An open file from any other checkout of this repo is swapped for
-- the same file in <dir> when it exists there, in the same windows and cursor
-- position; one with unsaved changes stays put. Unless a terminal switch called
-- this, the terminal in <dir> is selected too. Focus stays where it was.
local function activate(main_root, dir, label, from_terminal)
  local win = vim.api.nvim_get_current_win()
  vim.cmd('cd ' .. vim.fn.fnameescape(dir))

  local moved, kept = 0, {}
  do
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local path = vim.bo[buf].buflisted and vim.bo[buf].buftype == '' and real(vim.api.nvim_buf_get_name(buf))
      local from = path and checkout_of(path, main_root)
      if from and from ~= dir then
        local rel = path:sub(#from + 2)
        local target = dir .. '/' .. rel
        if vim.bo[buf].modified then
          table.insert(kept, rel)
        elseif vim.uv.fs_stat(target) then
          local wins = vim.fn.win_findbuf(buf)
          if #wins == 0 then
            vim.cmd('badd ' .. vim.fn.fnameescape(target))
          else
            local new
            for _, w in ipairs(wins) do
              local pos = vim.api.nvim_win_get_cursor(w)
              if new then vim.api.nvim_win_set_buf(w, new)
              else
                vim.api.nvim_win_call(w, function() vim.cmd('edit ' .. vim.fn.fnameescape(target)) end)
                new = vim.api.nvim_win_get_buf(w)
              end
              pcall(vim.api.nvim_win_set_cursor, w, pos)
            end
          end
          pcall(vim.api.nvim_buf_delete, buf, {})
          moved = moved + 1
        end
      end
    end
  end

  -- Re-root NERDTree if it's open (it takes focus; give it back).
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'nerdtree' then
      vim.cmd('silent! NERDTreeCWD')
      break
    end
  end
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
  vim.cmd('silent! checktime')

  if not from_terminal then select_terminal_in(dir, main_root) end

  local msg = 'ntree: switched to ' .. label
  if moved > 0 then msg = msg .. ' (' .. moved .. ' open file' .. (moved == 1 and '' or 's') .. ' moved)' end
  if #kept > 0 then
    vim.notify(msg .. ' — kept unsaved: ' .. table.concat(kept, ', '), vim.log.levels.WARN)
  else
    vim.notify(msg)
  end
end

-- Hook for the terminal manager (maps.vim): a terminal tab became current.
-- If its shell is in this repo's main checkout or a workspace, follow it.
function TermSwitched(buf)
  local cwd = term_cwds({ buf })[buf]
  if not cwd then return end
  local main_root = ntree_main_root(cwd)
  local dir = checkout_of(cwd, main_root)
  if not dir or dir == checkout_of(real(vim.fn.getcwd()), main_root) then return end
  local _, name = workspace_of(dir)
  activate(main_root, dir, name or 'main checkout', true)
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
          local e = selection.value
          activate(ntree_main_root(), e.path, e.name == 'main' and 'main checkout' or e.name)
        end
      end)
      return true
    end,
  }):find()
end

function NtreeMain()
  local main_root = ntree_main_root()
  if main_root then
    activate(main_root, main_root, 'main checkout')
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
          local name = branch:gsub('/', '-')
          activate(main_root, main_root .. '/.ntree/' .. name, name)
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
