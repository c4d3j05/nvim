let mapleader=";"

" move through split windows
nmap <leader><Up> :wincmd k<CR>
nmap <leader><Down> :wincmd j<CR>
nmap <leader><Left> :wincmd h<CR>
nmap <leader><Right> :wincmd l<CR>

" move through buffers
nmap <leader>[ :bp!<CR>
nmap <leader>] :bn!<CR>
nmap <leader>x :bp<bar>bd#<CR>

" copy, cut and paste
vmap <C-c> "+y
vmap <C-x> "+c
vmap <C-v> c<ESC>"+p
imap <C-v> <ESC>"+pa

" duplicate line
nmap <leader>d :t.<CR>

" Telescope
nnoremap <C-p> :Telescope find_files<CR>
nnoremap <leader>ff :Telescope find_files<CR>
nnoremap <leader>fg :Telescope live_grep<CR>
nnoremap <leader>fb :Telescope buffers<CR>
nnoremap <leader>fh :Telescope help_tags<CR>

" TagbarToggle (;tt, not ;t, which would wait to see if ;tn follows)
nnoremap <leader>tt :TagbarToggle<CR>

inoremap jj <Esc>

" Terminal manager with multiple tabs
"   normal mode:   ;Enter show/hide   ;tn new   ;tx close   ;1-;9 go to   ;th ;tl prev/next
"   terminal mode: the same with Alt (M-Enter, M-n, M-x, M-1..9, M-h M-l), so typing
"                  ; in a shell never waits for a mapping
lua << EOF
local terminals = {}   -- terminal buffers in tab order: tab N is terminals[N]
local current_term = 1
local term_win = nil
local term_height = 15
local stay_normal = false   -- while set, entering a terminal window doesn't start terminal mode

-- For other config (ntree.vim): the terminal buffers by tab number, and the
-- current tab number.
function TerminalList()
  return terminals, current_term
end

local function panel_open()
  return term_win ~= nil and vim.api.nvim_win_is_valid(term_win)
end

-- Drop terminals whose buffer is gone, keeping the list dense (tabs renumber)
-- and the current tab on the same terminal when it survives.
local function prune()
  local cur_buf, alive = terminals[current_term], {}
  for _, buf in ipairs(terminals) do
    if vim.api.nvim_buf_is_valid(buf) then table.insert(alive, buf) end
  end
  terminals = alive
  current_term = math.max(1, math.min(current_term, #terminals))
  for i, buf in ipairs(terminals) do
    if buf == cur_buf then current_term = i end
  end
end

local HELP = ";tn new  ;tx close  ;th ;tl switch  ;Enter hide  (Alt in terminal) "

local function render_term_tabs()
  if not panel_open() then return end
  -- Optional per-tab names (ntree.vim names a tab after the workspace its shell is in)
  local names = TermTabNames and TermTabNames(terminals) or {}
  local width = vim.api.nvim_win_get_width(term_win)

  -- Shorten labels until the row fits: full names, short names, numbers, no help.
  local function build(name_len, help)
    local parts, len = {}, #"  Terminal: "
    for i in ipairs(terminals) do
      local label = " " .. i .. " "
      if names[i] and name_len > 0 then label = " " .. i .. " " .. names[i]:sub(1, name_len) .. " " end
      len = len + vim.fn.strdisplaywidth(label)
      local hl = i == current_term and "%#TermTabActive#" or "%#TermTab#"
      table.insert(parts, hl .. label:gsub("%%", "%%%%") .. "%*")
    end
    if help then len = len + #help end
    return "  Terminal: " .. table.concat(parts) .. (help and ("%=" .. help) or ""), len
  end
  local winbar
  for _, try in ipairs({ { 18, HELP }, { 8, HELP }, { 0, HELP }, { 18, nil }, { 8, nil }, { 0, nil } }) do
    local bar, len = build(try[1], try[2])
    winbar = bar
    if len <= width then break end
  end
  vim.api.nvim_win_set_option(term_win, 'winbar', winbar)
end

-- Leaving terminal mode is when a `cd` in the shell has happened: refresh tab names.
vim.api.nvim_create_autocmd('TermLeave', { callback = function() render_term_tabs() end })

-- Set up highlight groups for terminal tabs
vim.api.nvim_set_hl(0, 'TermTab', { fg = '#888888', bg = '#1e1e1e' })
vim.api.nvim_set_hl(0, 'TermTabActive', { fg = '#1e1e1e', bg = '#7dcfff', bold = true })

-- Terminals are unlisted, so :bn/:bp (;] ;[), ;x and Telescope buffers only
-- see files. The manager keeps track of them itself in `terminals`.
local function open_terminal()
  vim.cmd('terminal')
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buflisted = false
  return buf
end

-- Show the panel (if hidden) and focus it.
local function focus_panel()
  if panel_open() then
    vim.api.nvim_set_current_win(term_win)
    return
  end
  vim.cmd('botright split')
  term_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(term_win, term_height)
  vim.wo[term_win].number = false
  vim.wo[term_win].relativenumber = false
  vim.wo[term_win].signcolumn = 'no'
end

local function hide_panel()
  if not panel_open() then return end
  term_height = vim.api.nvim_win_get_height(term_win)
  if #vim.api.nvim_tabpage_list_wins(0) == 1 then
    vim.api.nvim_win_call(term_win, function() vim.cmd('enew') end)  -- can't close the last window
  else
    vim.api.nvim_win_hide(term_win)
  end
  term_win = nil
end

-- Entering a terminal window starts terminal mode, except while a switch made
-- from normal mode is running (show_terminal with insert = false).
vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
  pattern = 'term://*',
  callback = function() if not stay_normal then vim.cmd('startinsert') end end,
})

-- Show terminal <index> in the panel and focus it. Args: <index>, [follow], [insert]
-- (follow: let ntree.vim move the code to the checkout this terminal is in;
--  insert: end in terminal mode, default true. Switches from normal mode pass
--  false so ;1 ;2 ;3 / ;th ;tl can be pressed one after another.)
local function show_terminal(index, follow, insert)
  insert = insert ~= false
  current_term = index
  stay_normal = not insert
  focus_panel()
  vim.api.nvim_win_set_buf(term_win, terminals[index])
  render_term_tabs()
  if follow and TermSwitched then TermSwitched(terminals[index]) end
  stay_normal = false
  vim.cmd(insert and 'startinsert' or 'stopinsert')
end

function NewTerminal()
  prune()
  focus_panel()
  table.insert(terminals, open_terminal())
  current_term = #terminals
  render_term_tabs()
  vim.cmd('startinsert')
end

function ToggleTerminal()
  if panel_open() then
    hide_panel()
    return
  end
  prune()
  if #terminals == 0 then NewTerminal() else show_terminal(current_term) end
end

-- Args: <index>, [insert] (false: stay in normal mode)
function SwitchTerminal(index, insert)
  prune()
  if not terminals[index] then
    vim.notify(#terminals == 0 and 'no terminals — ;tn opens one'
      or ('no terminal ' .. index .. ' (there are ' .. #terminals .. ')'), vim.log.levels.WARN)
    return
  end
  show_terminal(index, true, insert)
end

function NextTerminal(insert)
  prune()
  if #terminals == 0 then return NewTerminal() end
  show_terminal(current_term % #terminals + 1, true, insert)
end

function PrevTerminal(insert)
  prune()
  if #terminals == 0 then return NewTerminal() end
  show_terminal((current_term - 2) % #terminals + 1, true, insert)
end

-- Make <index> the current terminal without focusing it: shown in the panel if
-- the panel is open, otherwise next time it opens. (Used by ntree.vim.)
function SelectTerminal(index)
  prune()
  if not terminals[index] then return end
  current_term = index
  if panel_open() then
    vim.api.nvim_win_set_buf(term_win, terminals[index])
    render_term_tabs()
  end
end

-- Remove terminal <buf> from the list (later tabs renumber). If the panel was
-- showing it, show a neighbour instead, or hide the panel if none are left.
local function remove_terminal(buf)
  local index
  for i, b in ipairs(terminals) do if b == buf then index = i end end
  if not index then return end
  -- When a shell exits, nvim may already have closed the panel window with it.
  local was_shown = term_win ~= nil and (not panel_open() or vim.api.nvim_win_get_buf(term_win) == buf)
  table.remove(terminals, index)
  if current_term > index or current_term > #terminals then current_term = math.max(1, current_term - 1) end
  if was_shown then
    if #terminals == 0 then
      hide_panel()
      term_win = nil
    else
      focus_panel()
      vim.api.nvim_win_set_buf(term_win, terminals[current_term])
      if TermSwitched then TermSwitched(terminals[current_term]) end
    end
  end
  if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  render_term_tabs()
end

function CloseTerminal()
  prune()
  local buf = terminals[current_term]
  if buf then remove_terminal(buf) end
end

-- A shell exited (e.g. `exit`): take its tab out and renumber, keeping the panel
-- open on a neighbour.
vim.api.nvim_create_autocmd('TermClose', {
  callback = function(ev)
    for _, b in ipairs(terminals) do
      if b == ev.buf then
        vim.schedule(function() remove_terminal(ev.buf) end)
        return
      end
    end
  end,
})
EOF

" Normal mode
nnoremap <leader><CR> :lua ToggleTerminal()<CR>
nnoremap <leader>tn :lua NewTerminal()<CR>
nnoremap <leader>tx :lua CloseTerminal()<CR>
" switching from normal mode stays in normal mode, so these can be chained
nnoremap <leader>tl :lua NextTerminal(false)<CR>
nnoremap <leader>th :lua PrevTerminal(false)<CR>
for i in range(1, 9)
  execute 'nnoremap <leader>' . i . ' :lua SwitchTerminal(' . i . ', false)<CR>'
endfor

" Terminal mode: Alt, so ; types instantly in the shell
tnoremap <M-CR> <C-\><C-n>:lua ToggleTerminal()<CR>
tnoremap <M-n> <C-\><C-n>:lua NewTerminal()<CR>
tnoremap <M-x> <C-\><C-n>:lua CloseTerminal()<CR>
tnoremap <M-l> <C-\><C-n>:lua NextTerminal()<CR>
tnoremap <M-h> <C-\><C-n>:lua PrevTerminal()<CR>
tnoremap <C-Tab> <C-\><C-n>:lua NextTerminal()<CR>
tnoremap <C-S-Tab> <C-\><C-n>:lua PrevTerminal()<CR>
for i in range(1, 9)
  execute 'tnoremap <M-' . i . '> <C-\><C-n>:lua SwitchTerminal(' . i . ')<CR>'
endfor

" Exit terminal mode with Esc or jj
tnoremap <Esc> <C-\><C-n>
tnoremap jj <C-\><C-n>

" Navigate from terminal mode directly (Alt-arrows)
tnoremap <M-Up> <C-\><C-n>:wincmd k<CR>
tnoremap <M-Down> <C-\><C-n>:wincmd j<CR>
tnoremap <M-Left> <C-\><C-n>:wincmd h<CR>
tnoremap <M-Right> <C-\><C-n>:wincmd l<CR>


" Resize splits with ;= and ;- (height) and ;. and ;, (width)
nnoremap <leader>= :resize +5<CR>
nnoremap <leader>- :resize -5<CR>
nnoremap <leader>. :vertical resize +5<CR>
nnoremap <leader>, :vertical resize -5<CR>

" Also work from terminal mode (Alt)
tnoremap <M-=> <C-\><C-n>:resize +5<CR>i
tnoremap <M--> <C-\><C-n>:resize -5<CR>i
tnoremap <M-.> <C-\><C-n>:vertical resize +5<CR>i
tnoremap <M-,> <C-\><C-n>:vertical resize -5<CR>i

" Git (vim-fugitive)
nnoremap <leader>gs :Git<CR>
nnoremap <leader>ga :Git add %<CR>
nnoremap <leader>gc :Git commit<CR>
nnoremap <leader>gp :Git push<CR>
nnoremap <leader>gl :Git pull<CR>
nnoremap <leader>gd :Gdiffsplit<CR>
nnoremap <leader>gb :Git blame<CR>
nnoremap <leader>gL :Git log --oneline<CR>
nnoremap <leader>gr :Git rebase -i<CR>
nnoremap <leader>gS :Git stash<CR>
nnoremap <leader>gSp :Git stash pop<CR>
nnoremap <leader>gSl :Git stash list<CR>
nnoremap <leader>gcp :Git cherry-pick<Space>

" Git (neogit)
nnoremap <leader>gg :Neogit<CR>

" Cheatsheet
nnoremap <leader>? :Cheatsheet<CR>
