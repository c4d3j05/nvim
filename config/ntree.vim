" ntree workspace integration -------------------------------------------------
" <leader>ws  Telescope picker: switch nvim's cwd to a workspace (or main)
" <leader>wm  jump back to the main checkout
" <leader>wn  create a new workspace (ntree new <branch> -m <description>) and switch to it
" <leader>wd  set or clear the current workspace's description

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

-- Live status and checked-out branch come from `ntree list` (it verifies pids
-- and asks git); name, ports and description from state.json. A workspace's
-- path is always <main>/.ntree/<name>.
local function ntree_entries()
  local main_root = ntree_main_root()
  if not main_root then return nil end
  local current = ntree_current(main_root)
  local entries = { { name = 'main', branch = '(main checkout)', path = main_root, current = current == nil } }

  local live = {}
  local cmd = 'cd ' .. vim.fn.shellescape(main_root) .. ' && ntree list 2>/dev/null'
  for _, l in ipairs(vim.fn.systemlist(cmd)) do
    local name, branch = l:match('^(%S+)%s+(%S+)')
    if name and name ~= 'NAME' and name ~= '(root)' then
      live[name] = { branch = branch, running = l:find(' running ', 1, true) ~= nil }
    end
  end

  local state_path = main_root .. '/.ntree/state.json'
  if vim.fn.filereadable(state_path) == 1 then
    local ok, data = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(state_path), '\n'))
    if ok and data and data.workspaces then
      local names = vim.tbl_keys(data.workspaces)
      table.sort(names)
      for _, name in ipairs(names) do
        local ws = data.workspaces[name]
        local l = live[name] or {}
        local desc = ws.desc
        if desc == vim.NIL then desc = nil end
        table.insert(entries, {
          name = name,
          branch = l.branch or ws.branch,
          path = main_root .. '/.ntree/' .. name,
          port = type(ws.ports) == 'table' and ws.ports[1] or nil,
          running = l.running,
          desc = desc,
          current = name == current,
        })
      end
    end
  end
  return entries
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
