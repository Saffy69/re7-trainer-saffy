--[[--------------------------------------------------------------------------
  re7trainer.logger — prefixed, rate-limited logging.

  WHY THIS FILE EXISTS
  --------------------
  A trainer that logs every frame will flood REFramework's console and can
  measurably cost frame time. A trainer that logs nothing is undebuggable.
  This module gives every other module a single logging entry point with two
  guarantees:

    1. Every line carries a stable prefix so it can be grepped out of the
       REFramework log:  [RE7Trainer][Discovery] ...
    2. Repetitive messages (the ones that fire every frame while a game object
       is missing) are rate-limited so they appear once, not 6000 times.

  VERIFICATION NOTE
  -----------------
  REFramework exposes its logging table as a global. The method names
  info/warn/error/debug were each confirmed to exist as literal strings inside
  the user's installed dinput8.dll (REFramework v1.5.9+7-5bae4701). What we
  cannot prove without running the game is the exact table nesting. Every call
  is therefore issued through pcall, and a wrong guess degrades to "no log
  output" instead of a Lua error every frame.

  THROTTLING MODEL
  ----------------
  We never call os.time / os.clock. REFramework's Lua sandbox is not guaranteed
  to expose the `os` table, and the trainer already ticks once per frame, so a
  frame counter is cheaper and deterministic. main.lua calls M.tick() once per
  frame before anything else runs.
----------------------------------------------------------------------------]]

local M = {}

local PREFIX = "[RE7Trainer]"

--- Frames elapsed since script load. Advanced by M.tick().
local frame = 0

--- key -> frame index at which the message was last emitted.
local last_emitted = {}

--- key -> true, for M.once().
local emitted_once = {}

--- Resolve REFramework's logging table, or nil when unavailable.
-- Tries the documented global first, then a nested fallback, so that a
-- difference in binding shape between framework versions is survivable.
local function log_table()
  if type(log) == "table" then
    return log
  end
  if type(re) == "table" and type(re.log) == "table" then
    return re.log
  end
  return nil
end

--- Emit one already-formatted line at the given level. Never throws.
local function emit(level, message)
  local tbl = log_table()
  if tbl == nil then
    return
  end
  local fn = tbl[level]
  if type(fn) ~= "function" then
    return
  end
  pcall(fn, PREFIX .. message)
end

--- Format an optional tag into the message body.
local function format(tag, message)
  if tag == nil then
    return message
  end
  return "[" .. tag .. "] " .. message
end

-- ---------------------------------------------------------------------------
-- Frame clock
-- ---------------------------------------------------------------------------

--- Advance the frame counter. Called exactly once per frame by main.lua.
function M.tick()
  frame = frame + 1
end

--- Current frame index. Exposed so modules can build their own timing.
-- @return number
function M.frame()
  return frame
end

-- ---------------------------------------------------------------------------
-- Plain logging
--
-- These accept either (message) or (tag, message):
--     logger.info("hello")
--     logger.info("Discovery", "hello")
-- ---------------------------------------------------------------------------

--- @param tag string|nil
--- @param message string|nil
function M.info(tag, message)
  if message == nil then
    tag, message = nil, tag
  end
  emit("info", format(tag, message))
end

--- @param tag string|nil
--- @param message string|nil
function M.warn(tag, message)
  if message == nil then
    tag, message = nil, tag
  end
  emit("warn", format(tag, message))
end

--- @param tag string|nil
--- @param message string|nil
function M.error(tag, message)
  if message == nil then
    tag, message = nil, tag
  end
  emit("error", format(tag, message))
end

--- @param tag string|nil
--- @param message string|nil
function M.debug(tag, message)
  if message == nil then
    tag, message = nil, tag
  end
  emit("debug", format(tag, message))
end

-- ---------------------------------------------------------------------------
-- Rate-limited logging
-- ---------------------------------------------------------------------------

--- Log a message at most once per `every_frames` frames, per key.
--
-- Use this for anything that would otherwise repeat every frame, e.g.
-- "player object not found". The first occurrence always logs immediately;
-- subsequent ones are suppressed until the interval has elapsed.
--
-- @param key string            stable identifier for this message
-- @param every_frames number   minimum frames between emissions (>= 1)
-- @param level string          "info" | "warn" | "error" | "debug"
-- @param tag string|nil
-- @param message string
function M.throttled(key, every_frames, level, tag, message)
  if every_frames < 1 then
    every_frames = 1
  end

  local last = last_emitted[key]
  if last ~= nil and (frame - last) < every_frames then
    return
  end
  last_emitted[key] = frame

  emit(level, format(tag, message))
end

--- Log a message exactly once for the lifetime of the script, per key.
--
-- Use this for one-shot facts: capability probe results, discovery summaries,
-- "this API is missing" notices. A script reset clears the bookkeeping, so a
-- hot-reload logs everything again — which is what you want when debugging.
--
-- @param key string
-- @param level string
-- @param tag string|nil
-- @param message string
function M.once(key, level, tag, message)
  if emitted_once[key] then
    return
  end
  emitted_once[key] = true
  emit(level, format(tag, message))
end

--- Clear throttle/once bookkeeping. Called on script reset.
function M.reset()
  last_emitted = {}
  emitted_once = {}
  frame = 0
end

return M
