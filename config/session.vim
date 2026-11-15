" Sessions: close everything and resume it later ----------------------------
" <leader>qs  save the session, write all files and quit (terminals included)
" <leader>rs  resume the saved session for this repo
"
" One session per repo (keyed by the main checkout, so it's shared by the ntree
" workspaces). It brings back windows, splits, open files and cursor positions,
" the checkout nvim was in, NERDTree, and the ;tn terminal tabs in order, each
" reopened in the folder its shell was in. Whatever ran inside a terminal (an
" agent, a dev server started by hand) does not survive quitting; `ntree run -d`
" servers do, they don't belong to nvim. To keep everything running instead,
" use `nv` (tmux) and detach.
"
" Started by `nv` (NV_RESTORE=1, no file arguments), nvim resumes on its own;
" plain `nvim` only says that a saved session exists.

lua << EOF
local function session_root()
  local out = vim.fn.systemlist({ 'git', '-C', vim.fn.getcwd(), 'rev-parse', '--path-format=absolute', '--git-common-dir' })
  if vim.v.shell_error == 0 and out[1] then return vim.fs.dirname(out[1]) end
  return vim.fn.getcwd()
end

-- <state>/sessions/<root with / as %>.vim (+ .json for terminals and panels)
local function session_files(root)
  local dir = vim.fn.stdpath('state') .. '/sessions'
  vim.fn.mkdir(dir, 'p')
  local base = dir .. '/' .. root:gsub('[/\\:]', '%%')
  return base .. '.vim', base .. '.json'
end

local function nerdtree_open()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'nerdtree' then return true end
  end
  return false
end

-- Write the session for this repo. The session file holds only the code
-- windows: the terminal panel and NERDTree are closed first and recorded in the
-- .json next to it, with each terminal's folder.
function SessionSave()
  local root = session_root()
  local vim_file, json_file = session_files(root)

  local terms, current = {}, 1
  if TerminalList then terms, current = TerminalList() end
  local cwds = TerminalCwds and TerminalCwds(terms) or {}
  local dirs = {}
  for i, buf in ipairs(terms) do dirs[i] = cwds[buf] or vim.fn.getcwd() end
  local panel, height = false, nil
  if TerminalPanel then panel, height = TerminalPanel() end
  local tree = nerdtree_open()

  if panel then ToggleTerminal() end
  if tree then vim.cmd('silent! NERDTreeClose') end
  vim.o.sessionoptions = 'buffers,curdir,folds,help,tabpages,winsize'
  vim.cmd('mksession! ' .. vim.fn.fnameescape(vim_file))
  vim.fn.writefile({ vim.json.encode({
    terminals = dirs, current = current, panel = panel, height = height, nerdtree = tree,
  }) }, json_file)
  return root
end

function SessionSaveQuit()
  local ok, err = pcall(vim.cmd, 'wall')
  if not ok then
    vim.notify('session not saved — ' .. (tostring(err):match('E%d+:.*') or tostring(err)), vim.log.levels.ERROR)
    return
  end
  SessionSave()
  vim.cmd('qa!')   -- ! ends the terminal jobs; every file was just written
end

function SessionRestore()
  local root = session_root()
  local vim_file, json_file = session_files(root)
  if vim.fn.filereadable(vim_file) == 0 then
    vim.notify('no saved session for ' .. vim.fn.fnamemodify(root, ':~'), vim.log.levels.WARN)
    return
  end
  vim.cmd('silent source ' .. vim.fn.fnameescape(vim_file))

  local data = {}
  if vim.fn.filereadable(json_file) == 1 then
    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(json_file), '\n'))
    if ok and type(decoded) == 'table' then data = decoded end
  end

  local code_win = vim.api.nvim_get_current_win()
  local dirs = data.terminals or {}
  if #dirs > 0 and NewTerminal then
    for _, dir in ipairs(dirs) do NewTerminal(dir) end
    if data.height then vim.api.nvim_win_set_height(0, data.height) end
    if data.panel then
      SelectTerminal(math.min(data.current or 1, #dirs))
    else
      ToggleTerminal()   -- hide it again; the current tab is kept for ;Enter
      SelectTerminal(math.min(data.current or 1, #dirs))
    end
  end
  if data.nerdtree then vim.cmd('silent! NERDTreeCWD') end
  if vim.api.nvim_win_is_valid(code_win) then vim.api.nvim_set_current_win(code_win) end
  vim.cmd('stopinsert')
  vim.notify('resumed session for ' .. vim.fn.fnamemodify(root, ':~')
    .. (#dirs > 0 and (' (' .. #dirs .. ' terminal' .. (#dirs == 1 and '' or 's') .. ')') or ''))
end

vim.api.nvim_create_autocmd('VimEnter', {
  callback = function()
    if vim.fn.argc() > 0 then return end
    vim.schedule(function()
      local vim_file = session_files(session_root())
      if vim.fn.filereadable(vim_file) == 0 then return end
      if vim.env.NV_RESTORE == '1' then
        SessionRestore()
      else
        vim.notify('saved session for this repo — ;rs to resume')
      end
    end)
  end,
})
EOF

nnoremap <leader>qs :lua SessionSaveQuit()<CR>
nnoremap <leader>rs :lua SessionRestore()<CR>
