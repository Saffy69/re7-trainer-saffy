--[[--------------------------------------------------------------------------
  re7trainer.config — persistence for user preferences.

  WHAT IS PERSISTED AND WHAT IS NOT
  ---------------------------------
  Only booleans from state.prefs. Deliberately nothing else.

  Specifically NOT persisted:
    * object references — a handle to a live game object is meaningless in the
      next session and writing one out is a good way to crash on load
    * discovered offsets or field indices — these are build-specific and would
      silently point at the wrong memory after a game update
    * "supported" flags — these are re-derived by discovery every session, so a
      stale true can never resurrect a toggle that no longer works

  STORAGE MECHANISM
  -----------------
  REFramework exposes json.dump_file(path, table) and json.load_file(path).
  Both were confirmed present as literal strings in the user's installed
  dinput8.dll. There is NO filesystem library in this build (fs.* is absent),
  so json.* is the only route to disk, and every call to it is guarded — if it
  fails, the trainer still runs, it just forgets your preferences.

  The path is relative and resolves against the game's working directory,
  which is the game install folder. If the write fails (read-only install,
  unusual cwd) the trainer logs it once and carries on with defaults.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")

local M = {}

--- Config filename, relative to the game working directory.
M.FILE = "re7trainer_config.json"

--- Bumped when the persisted shape changes incompatibly.
local SCHEMA_VERSION = 1

--- Keys that are safe to round-trip. Anything not listed here is ignored on
--- load, so an edited or hand-crafted config cannot inject unexpected fields.
local PERSISTED_KEYS = {
  "trainer_enabled",
  "god_mode",
  "infinite_ammo",
  "infinite_items",
  "debug_mode",
  "discovery_mode",
  "log_discovery",
}

--- Is the json library available in this REFramework build?
-- @return boolean
local function json_available()
  return type(json) == "table"
      and type(json.dump_file) == "function"
      and type(json.load_file) == "function"
end

--- Load preferences from disk into state.prefs.
--
-- Failure is not an error: a missing or corrupt config just means we run on
-- defaults. Every failure path here is logged at most once.
-- @return boolean loaded
function M.load()
  if not json_available() then
    logger.once("cfg:nojson", "warn", nil,
                "json.dump_file/load_file unavailable in this REFramework build; " ..
                "settings will not persist.")
    return false
  end

  local ok, data = pcall(json.load_file, M.FILE)
  if not ok or type(data) ~= "table" then
    logger.info(nil, "No config loaded from " .. M.FILE .. " (first run, or file unreadable). Using defaults.")
    return false
  end

  local version = tonumber(data.schema_version)
  if version ~= nil and version > SCHEMA_VERSION then
    logger.warn(nil, string.format(
      "Config at %s was written by a newer trainer (schema %d > %d). Ignoring it rather than guessing.",
      M.FILE, version, SCHEMA_VERSION))
    return false
  end

  local applied = 0
  for _, key in ipairs(PERSISTED_KEYS) do
    local value = data[key]
    if type(value) == "boolean" then
      state.prefs[key] = value
      applied = applied + 1
    end
  end

  logger.info(nil, string.format("Loaded %d setting(s) from %s.", applied, M.FILE))
  return true
end

--- Write current preferences to disk.
-- @return boolean saved
function M.save()
  if not json_available() then
    return false
  end

  local payload = { schema_version = SCHEMA_VERSION }
  for _, key in ipairs(PERSISTED_KEYS) do
    payload[key] = state.prefs[key] == true
  end

  local ok, err = pcall(json.dump_file, M.FILE, payload)
  if not ok then
    logger.throttled("cfg:savefail", 600, "error", nil,
                     "Could not write " .. M.FILE .. ": " .. tostring(err) ..
                     " (settings will not persist this session)")
    return false
  end

  logger.debug(nil, "Saved settings to " .. M.FILE)
  return true
end

--- Save, but only when something actually changed.
--
-- REFramework calls on_config_save continuously while the menu is open, so
-- writing unconditionally would hit the disk many times a second.
-- @param previous table snapshot of prefs taken before the change
-- @return boolean saved
function M.save_if_changed(previous)
  for _, key in ipairs(PERSISTED_KEYS) do
    if previous[key] ~= state.prefs[key] then
      return M.save()
    end
  end
  return false
end

--- Snapshot the persisted keys, for change detection.
-- @return table
function M.snapshot()
  local copy = {}
  for _, key in ipairs(PERSISTED_KEYS) do
    copy[key] = state.prefs[key]
  end
  return copy
end

return M
