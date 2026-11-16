-- Rex extension: a native macOS popup for switching sessions.
--
-- Load it from init.lua (`make enable` does this):
--   dofile(os.getenv("HOME") .. "/.config/rex/rex-macos-session-switcher/session-switcher.lua")
--
-- Options, set before the dofile line:
--   rex_macos_session_switcher = { bind = "cmd+shift+e" }  -- another key
--   rex_macos_session_switcher = { bind = false }          -- no key binding
-- The action is named switch_session, so you can also bind it yourself:
--   rex.bind("ctrl+space", "switch_session")

local options = rex_macos_session_switcher or {}

-- Rex's configuration directory: REX_CONFIG's, else XDG_CONFIG_HOME/rex, else ~/.config/rex.
local function config_dir()
  local file = os.getenv("REX_CONFIG")
  if file and file ~= "" then return file:match("^(.*)/[^/]*$") or "." end
  local xdg = os.getenv("XDG_CONFIG_HOME")
  local base = (xdg and xdg ~= "") and xdg or (os.getenv("HOME") .. "/.config")
  return base .. "/rex"
end

local dir = config_dir() .. "/rex-macos-session-switcher"
local helper = dir .. "/rex-session-switcher"
local recent_file = dir .. "/recent.txt"

-- Session IDs, most recently used first. Rex doesn't report when a session was
-- last used, so the switcher keeps its own list, updated whenever it is opened.
local function load_recent()
  local ids = {}
  local f = io.open(recent_file, "r")
  if f then
    for line in f:lines() do
      if line ~= "" then ids[#ids + 1] = line end
    end
    f:close()
  end
  return ids
end

local function save_recent(ids)
  local f = io.open(recent_file, "w")
  if not f then return end
  f:write(table.concat(ids, "\n"), "\n")
  f:close()
end

local function touch(ids, id)
  for i, v in ipairs(ids) do
    if v == id then table.remove(ids, i) break end
  end
  table.insert(ids, 1, id)
end

-- Sessions ordered by recent use; ones never seen keep the server's order after.
local function sort_sessions(sessions, recent)
  local by_id, sorted = {}, {}
  for _, s in ipairs(sessions) do by_id[s.session_id] = s end
  for _, id in ipairs(recent) do
    if by_id[id] then
      sorted[#sorted + 1] = by_id[id]
      by_id[id] = nil
    end
  end
  for _, s in ipairs(sessions) do
    if by_id[s.session_id] then sorted[#sorted + 1] = s end
  end
  return sorted
end

local TERMINAL = "com.superlogical.terminal"
local urgency = { blocked = 4, error = 3, working = 2, done = 1 }

-- The most urgent status any terminal in the session has reported (agents
-- report with the OSC 7501 program status protocol), or nil.
local function agent_status(session_id)
  local blocks = rex.call("session.list_blocks", { session_id = session_id })
  if not blocks then return nil end
  local best, rank = nil, 0
  for _, b in ipairs(blocks.blocks or {}) do
    if b.creator_name == TERMINAL then
      local r = rex.block.call(TERMINAL, "program_status",
        { session_id = session_id, block_id = b.block_id })
      for _, rec in ipairs(r and r.records or {}) do
        local u = urgency[rec.state] or 0
        if u > rank or (u > 0 and u == rank and rec.updated_at > best.updated_at) then
          best, rank = rec, u
        end
      end
    end
  end
  if not best then return nil end
  return { state = best.state, msg = best.msg, kind = best.kind, updated_at = best.updated_at }
end

rex.action{
  name        = "switch_session",
  title       = "Switch Session (Native)",
  description = "Choose a Rex session from a native macOS popup.",
  keywords    = "switch session popup",
  run = function(ctx, args)
    local probe = io.open(helper, "r")
    if not probe then
      rex.log("error", "switch_session: " .. helper .. " is missing. Run `make install`.")
      return
    end
    probe:close()

    local listed, err = rex.call("session.list")
    if not listed then
      rex.log("error", "switch_session: " .. tostring(err))
      return
    end
    -- The session being left was in use until now.
    local recent = load_recent()
    touch(recent, ctx.session_id)
    save_recent(recent)

    -- Reading other sessions' terminals needs this connection to see them all.
    -- If anything here fails the switcher still works, just without statuses.
    local sessions = sort_sessions(listed.sessions, recent)
    if rex.call("session.attach_all", { event_scope = "session" }) then
      for _, s in ipairs(sessions) do
        local ok, st = pcall(agent_status, s.session_id)
        if ok then s.status = st end
      end
    end

    local r, exec_err = rex.exec({ helper }, {
      stdin = rex.json.encode({ sessions = sessions, current = ctx.session_id }),
    })
    if not r then
      rex.log("error", "switch_session: " .. tostring(exec_err))
      return
    end
    -- Exit status 1 means the user cancelled.
    if not r.ok then
      if r.code ~= 1 then rex.log("error", "switch_session: " .. r.stderr) end
      return
    end
    local choice = rex.json.decode(r.stdout)
    if type(choice) ~= "table" then
      rex.log("error", "switch_session: unexpected output: " .. r.stdout)
      return
    end
    local id = choice.session_id
    -- Selecting a session needs Remote Control turned on in Rex.app.
    local function go()
      touch(recent, id)
      save_recent(recent)
      rex.client.queue("session.select", { session_id = id })
    end

    if choice.action == "new_session" then
      local created, create_err = rex.call("session.create", {
        label = choice.label,
        initial_windows = {
          { window_label = "Terminal", layout = rex.layout.block{ flavor = "com.superlogical.terminal.shell" } },
        },
      })
      if not created then
        rex.log("error", "switch_session: " .. tostring(create_err))
        return
      end
      id = created.session_id
      go()
    elseif choice.action == "select" then
      go()
    elseif choice.action == "rename" then
      rex.call("session.set_label", { session_id = id, label = choice.label })
    elseif choice.action == "new_tab" then
      rex.call("session.new_window", {
        session_id = id,
        layout = rex.layout.block{ flavor = "com.superlogical.terminal.shell" },
      })
      go()
    elseif choice.action == "copy" then
      rex.exec({ "pbcopy" }, { stdin = id })
    elseif choice.action == "close" then
      rex.call("session.destroy", { session_id = id })
      for i, v in ipairs(recent) do
        if v == id then table.remove(recent, i) break end
      end
      save_recent(recent)
    end
  end,
}

if options.bind ~= false then
  rex.bind(options.bind or "cmd+e", "switch_session")
end
