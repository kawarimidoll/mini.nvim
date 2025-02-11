-- MIT License Copyright (c) 2021 Evgeni Chasnovski

---@brief [[
--- Lua module for minimal session management (read, write, delete), which
--- works using |mksession| (meaning 'sessionoptions' is fully respected).
--- This is intended as a drop-in Lua replacement for session management part
--- of [mhinz/vim-startify](https://github.com/mhinz/vim-startify) (works out
--- of the box with sessions created by it). Implements both global (from
--- configured directory) and local (from current directory) sessions.
---
--- Key design ideas:
--- - Sessions are represented by readable files (results of applying
---   |mksession|). There are two kinds of sessions:
---     - Global: any file inside a configurable directory.
---     - Local: configurable file inside current working directory (|getcwd|).
--- - All session files are detected during `MiniSessions.setup()` with session
---   names being file names (including their possible extension).
--- - Store information about detected sessions in separate table
---   (|MiniSessions.detected|) and operate only on it. Meaning if this
---   information changes, there will be no effect until next detection. So to
---   avoid confusion, don't directly use |mksession| and |source| for writing
---   and reading sessions files.
---
--- Features:
--- - Autoread default session (local if detected, latest otherwise) if Neovim
---   was called without intention to show something else.
--- - Autowrite current session before quitting Neovim.
--- - Configurable severity level of all actions.
---
--- # Setup
---
--- This module needs a setup with `require('mini.sessions').setup({})`
--- (replace `{}` with your `config` table). It will create global Lua table
--- `MiniSessions` which you can use for scripting or manually (with
--- `:lua MiniSessions.*`).
---
--- Default `config`:
--- <code>
---   {
---     -- Whether to autoread latest session if Neovim was called without file arguments
---     autoread = false,
---
---     -- Whether to write current session before quitting Neovim
---     autowrite = true,
---
---     -- Directory where global sessions are stored (use `''` to disable)
---     directory = --<"session" subdirectory of user data directory from |stdpath()|>,
---
---     -- File for local session (use `''` to disable)
---     file = 'Session.vim',
---
---     -- Whether to force possibly harmful actions (meaning depends on function)
---     force = { read = false, write = true, delete = false },
---
---     -- Whether to print session path after action
---     verbose = { read = false, write = true, delete = true },
---   }
--- </code>
--- # Disabling
---
--- To disable core functionality, set `g:minisessions_disable` (globally) or
--- `b:minisessions_disable` (for a buffer) to `v:true`.
---@brief ]]
---@tag MiniSessions mini.sessions

-- Module and its helper --
local MiniSessions = {}
local H = { path_sep = package.config:sub(1, 1) }

--- Module setup
---
---@param config table: Module config table.
---@usage `require('mini.sessions').setup({})` (replace `{}` with your `config` table)
function MiniSessions.setup(config)
  -- Export module
  _G.MiniSessions = MiniSessions

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Module behavior
  vim.cmd([[au VimEnter * ++nested ++once lua MiniSessions.on_vimenter()]])

  if config.autowrite then
    vim.cmd([[au VimLeavePre * lua if vim.v.this_session ~= '' then MiniSessions.write(nil, {force = true}) end]])
  end
end

-- Module config --
MiniSessions.config = {
  -- Whether to read latest session if Neovim was called without file arguments
  autoread = false,

  -- Whether to write current session before quitting Neovim
  autowrite = true,

  -- Directory where global sessions are stored (use `''` to disable)
  directory = ('%s%ssession'):format(vim.fn.stdpath('data'), H.path_sep),

  -- File for local session (use `''` to disable)
  file = 'Session.vim',

  -- Whether to force possibly harmful actions (meaning depends on function)
  force = { read = false, write = true, delete = false },

  -- Whether to print session path after action
  verbose = { read = false, write = true, delete = true },
}

-- Module data --
---@class MiniSessions.detected @Table of detected sessions. Keys represent session name. Values are tables with session information that currently has these fields (but subject to change):
---@field modify_time number: modification time (see |getftime|) of session file.
---@field name string: name of session (should be equal to table value).
---@field path string: full path to session file.
---@field type string: type of session ('global' or 'local').

MiniSessions.detected = {}

-- Module functionality --
--- Read detected session
---
--- What it does:
--- - Delete all current buffers with |bwipeout|. This is needed to correctly
---   restore buffers from target session. If `force` is not `true`, checks
---   beforehand for unsaved buffers and stops if there is any.
--- - Source session with supplied name.
---
---@param session_name string: Name of detected session file to read. Default: `nil` for default session: local (if detected) or latest session (see |MiniSessions.get_latest|).
---@param opts table: Table with options. Current allowed keys: `force` (whether to delete unsaved buffers; default: `MiniSessions.config.force.read`), `verbose` (whether to print session path after action; default `MiniSessions.config.verbose.read`).
function MiniSessions.read(session_name, opts)
  if H.is_disabled() then
    return
  end
  if vim.tbl_count(MiniSessions.detected) == 0 then
    H.notify([[There is no detected sessions. Change configuration and rerun `MiniSessions.setup()`.]])
    return
  end

  if session_name == nil then
    if MiniSessions.detected[MiniSessions.config.file] ~= nil then
      session_name = MiniSessions.config.file
    else
      session_name = MiniSessions.get_latest()
    end
  end

  opts = vim.tbl_deep_extend('force', H.default_opts('read'), opts or {})

  if not H.validate_detected(session_name) then
    return
  end
  if not H.wipeout_all_buffers(opts.force) then
    return
  end

  local session_path = MiniSessions.detected[session_name].path
  vim.cmd(('source %s'):format(vim.fn.fnameescape(session_path)))

  if opts.verbose then
    H.notify(('Read session %s'):format(session_path))
  end
end

--- Write session
---
--- What it does:
--- - Check if file for supplied session name already exists. If it does and
---   `force` is not `true`, then stop.
--- - Write session with |mksession| to a file named `session_name`. Its
---   directory is determined based on type of session:
---     - It is at location |v:this_session| if `session_name` is `nil` and
---       there is current session.
---     - It is current working directory (|getcwd|) if `session_name` is equal
---       to `MiniSessions.config.file` (represents local session).
---     - It is `MiniSessions.config.directory` otherwise (represents global
---       session).
--- - Update |MiniSessions.detected|.
---
---@param session_name string: Name of session file to write. Default: `nil` for current session (|v:this_session|).
---@param opts table: Table with options. Current allowed keys: `force` (whether to ignore existence of session file; default: `MiniSessions.config.force.write`), `verbose` (whether to print session path after action; default `MiniSessions.config.verbose.write`).
function MiniSessions.write(session_name, opts)
  if H.is_disabled() then
    return
  end
  if type(session_name) == 'string' and #session_name == 0 then
    H.notify([[Supply non-empty session name to write.]])
    return
  end

  opts = vim.tbl_deep_extend('force', H.default_opts('write'), opts or {})

  local session_path = H.name_to_path(session_name)
  if session_path == nil then
    return
  end

  if not opts.force and H.is_readable_file(session_path) then
    H.notify([[Can't write to existing session when `opts.force` is not `true`.]])
    return
  end

  -- Make session file
  local cmd = ('mksession%s'):format(opts.force and '!' or '')
  vim.cmd(('%s %s'):format(cmd, vim.fn.fnameescape(session_path)))

  -- Update detected sessions
  local s = H.new_session(session_path)
  MiniSessions.detected[s.name] = s

  if opts.verbose then
    H.notify(('Written session %s'):format(session_path))
  end
end

--- Delete detected session
---
--- What it does:
--- - Check if session name is a current one. If yes and `force` is not `true`,
---   then stop.
--- - Delete session.
--- - Update |MiniSessions.detected|.
---
---@param session_name string: Name of detected session file to delete. Default: `nil` for name of current session (taken from |v:this_session|).
---@param opts table: Table with options. Current allowed keys: `force` (whether to ignore deletion of current session; default: `MiniSessions.config.force.delete`), `verbose` (whether to print session path after action; default `MiniSessions.config.verbose.delete`).
function MiniSessions.delete(session_name, opts)
  if H.is_disabled() then
    return
  end
  if vim.tbl_count(MiniSessions.detected) == 0 then
    H.notify([[There is no detected sessions. Change configuration and rerun `MiniSessions.setup()`.]])
    return
  end

  opts = vim.tbl_deep_extend('force', H.default_opts('delete'), opts or {})

  local session_path = H.name_to_path(session_name)
  if session_path == nil then
    return
  end

  -- Make sure to delete only detected session (matters for local session)
  session_name = vim.fn.fnamemodify(session_path, ':t')
  if not H.validate_detected(session_name) then
    return
  end
  session_path = MiniSessions.detected[session_name].path

  local is_current_session = session_path == vim.v.this_session
  if not opts.force and is_current_session then
    H.notify([[Can't delete current session when `opts.force` is not `true`.]])
    return
  end

  -- Delete and update detected sessions
  vim.fn.delete(session_path)
  MiniSessions.detected[session_name] = nil
  if is_current_session then
    vim.v.this_session = ''
  end

  if opts.verbose then
    H.notify(('Deleted session %s'):format(session_path))
  end
end

--- Get name of latest detected session
---
--- Latest session is the session with the latest modification time determined
--- by |getftime|.
---
---@return string|nil: Name of latest session or `nil` if there is no sessions.
function MiniSessions.get_latest()
  if vim.tbl_count(MiniSessions.detected) == 0 then
    return
  end

  local latest_time, latest_name = -1, nil
  for name, data in pairs(MiniSessions.detected) do
    if data.modify_time > latest_time then
      latest_time, latest_name = data.modify_time, name
    end
  end

  return latest_name
end

--- Act on |VimEnter|
function MiniSessions.on_vimenter()
  -- It is assumed that something is shown if there is something in 'current'
  -- buffer or if at least one file was supplied on startup
  local is_something_shown = vim.fn.line2byte('$') > 0 or vim.fn.argc() > 0
  if MiniSessions.config.autoread and not is_something_shown then
    MiniSessions.read()
  end
end

-- Helper data --
-- Module default config
H.default_config = MiniSessions.config

-- Helper functions --
-- Settings
function H.setup_config(config)
  -- General idea: if some table elements are not present in user-supplied
  -- `config`, take them from default config
  vim.validate({ config = { config, 'table', true } })
  config = vim.tbl_deep_extend('force', H.default_config, config or {})

  vim.validate({
    autoread = { config.autoread, 'boolean' },
    autowrite = { config.autowrite, 'boolean' },
    directory = { config.directory, 'string' },
    file = { config.file, 'string' },

    force = { config.force, 'table' },
    ['force.read'] = { config.force.read, 'boolean' },
    ['force.write'] = { config.force.write, 'boolean' },
    ['force.delete'] = { config.force.delete, 'boolean' },

    verbose = { config.verbose, 'table' },
    ['verbose.read'] = { config.verbose.read, 'boolean' },
    ['verbose.write'] = { config.verbose.write, 'boolean' },
    ['verbose.delete'] = { config.verbose.delete, 'boolean' },
  })

  return config
end

function H.apply_config(config)
  MiniSessions.config = config

  MiniSessions.detected = H.detect_sessions(config)
end

function H.is_disabled()
  return vim.g.minisessions_disable == true or vim.b.minisessions_disable == true
end

-- Work with sessions
function H.detect_sessions(config)
  local res_global = config.directory == '' and {} or H.detect_sessions_global(config.directory)
  local res_local = config.file == '' and {} or H.detect_sessions_local(config.file)

  -- If there are both local and global session with same name, prefer local
  return vim.tbl_deep_extend('force', res_global, res_local)
end

function H.detect_sessions_global(global_dir)
  global_dir = vim.fn.fnamemodify(global_dir, ':p')
  if vim.fn.isdirectory(global_dir) ~= 1 then
    H.notify(('%s is not a directory path.'):format(vim.inspect(global_dir)))
    return {}
  end

  local globs = vim.fn.globpath(global_dir, '*')
  if #globs == 0 then
    return {}
  end

  local res = {}
  for _, f in pairs(vim.split(globs, '\n')) do
    if H.is_readable_file(f) then
      local s = H.new_session(f, 'global')
      res[s.name] = s
    end
  end
  return res
end

function H.detect_sessions_local(local_file)
  local f = H.joinpath(vim.fn.getcwd(), local_file)

  if not H.is_readable_file(f) then
    return {}
  end

  local res = {}
  local s = H.new_session(f, 'local')
  res[s.name] = s
  return res
end

function H.new_session(session_path, session_type)
  return {
    modify_time = vim.fn.getftime(session_path),
    name = vim.fn.fnamemodify(session_path, ':t'),
    path = vim.fn.fnamemodify(session_path, ':p'),
    type = session_type or H.get_session_type(session_path),
  }
end

function H.get_session_type(session_path)
  if MiniSessions.config.directory == '' then
    return 'local'
  end

  local session_dir = vim.fn.fnamemodify(session_path, ':p')
  local global_dir = vim.fn.fnamemodify(MiniSessions.config.directory, ':p')
  return session_dir == global_dir and 'global' or 'local'
end

function H.validate_detected(session_name)
  local is_detected = vim.tbl_contains(vim.tbl_keys(MiniSessions.detected), session_name)
  if is_detected then
    return true
  end

  H.notify(('%s is not a name for detected session.'):format(vim.inspect(session_name)))
  return false
end

function H.wipeout_all_buffers(force)
  if force then
    vim.cmd([[%bwipeout!]])
    return true
  end

  -- Check for unsaved buffers and do nothing if they are present
  local unsaved_buffers = vim.tbl_filter(function(buf_id)
    vim.api.nvim_buf_get_option(buf_id, 'modified')
  end, vim.api.nvim_list_bufs())

  if #unsaved_buffers > 0 then
    local buf_list = table.concat(unsaved_buffers, ', ')
    H.notify(('There are unsaved buffers: %s.'):format(buf_list))
    return false
  end

  vim.cmd([[%bwipeout]])
  return true
end

function H.get_current_session_name()
  return vim.fn.fnamemodify(vim.v.this_session, ':t')
end

function H.name_to_path(session_name)
  if session_name == nil then
    if vim.v.this_session == '' then
      H.notify([[There is no active session. Supply non-nil session name.]])
      return
    end
    return vim.v.this_session
  end

  local session_dir = (session_name == MiniSessions.config.file) and vim.fn.getcwd() or MiniSessions.config.directory
  local path = H.joinpath(session_dir, session_name)
  return vim.fn.fnamemodify(path, ':p')
end

-- Utilities
function H.default_opts(action)
  return { force = MiniSessions.config.force[action], verbose = MiniSessions.config.verbose[action] }
end

function H.notify(msg)
  vim.notify(('(mini.sessions) %s'):format(msg))
end

function H.is_readable_file(path)
  return vim.fn.isdirectory(path) ~= 1 and vim.fn.getfperm(path):sub(1, 1) == 'r'
end

function H.joinpath(directory, filename)
  return ('%s%s%s'):format(directory, H.path_sep, tostring(filename))
end

return MiniSessions
