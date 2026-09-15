--[[--------------------------------------------------------------------------
  re7trainer.utils.object_helpers — working with live RE Engine managed objects.

  The distinction that matters here:

    * A TypeDefinition describes a type. It is static and safe to hold forever.
    * A managed object is a live instance inside the game process. It becomes
      INVALID when the scene changes, the player dies, a cutscene starts, or a
      save is loaded. Holding one across those boundaries and touching it is a
      plausible route to a hard crash.

  So this module's job is to make object lifetime explicit:

    * every cached handle is tagged with the frame it was acquired on
    * every access re-validates before use
    * anything that fails validation is dropped rather than retried

  It also centralises the "is this thing usable" question, because getting it
  wrong in fifteen places is how trainers crash games.
----------------------------------------------------------------------------]]

local safe = require("re7trainer.utils.safe_call")
local logger = require("re7trainer.logger")

local M = {}

--- Objects cached longer than this are treated as stale and re-acquired.
-- One second at 60fps. Long enough to be useful, short enough that a scene
-- transition cannot leave us holding something from the previous scene.
local MAX_CACHE_AGE_FRAMES = 60

--- Is this value usable as a live managed object?
--
-- Returns false for nil, for plain Lua values, and for anything whose type
-- definition we cannot read — the last case is the signature of a dangling
-- handle in practice.
-- @param object any
-- @return boolean
function M.is_valid(object)
  if object == nil then
    return false
  end
  local kind = type(object)
  if kind ~= "userdata" and kind ~= "table" then
    return false
  end

  -- Touching the object's type is the cheapest liveness probe available. If
  -- this throws or yields nothing, we must not touch the object again.
  local ok, type_definition = pcall(function()
    return object:get_type_definition()
  end)

  return ok and type_definition ~= nil
end

--- Fully qualified type name of a live object, or nil if unreadable.
-- @param object any
-- @return string|nil
function M.type_name(object)
  if object == nil then
    return nil
  end

  local ok, result = pcall(function()
    local type_definition = object:get_type_definition()
    if type_definition == nil then
      return nil
    end
    return type_definition:get_full_name() or type_definition:get_name()
  end)

  if not ok then
    return nil
  end
  return result
end

--- Read a field, returning nil when the read is not possible.
-- Thin convenience wrapper; safe_call.get_field does the actual guarding.
-- @param object userdata
-- @param name string
-- @return any|nil
function M.get(object, name)
  local ok, value = safe.get_field(object, name)
  if not ok then
    return nil
  end
  return value
end

--- Read a numeric field as a Lua number, or nil.
-- RE Engine exposes some numeric fields as userdata; safe_call.to_number
-- normalises those.
-- @param object userdata
-- @param name string
-- @return number|nil
function M.get_number(object, name)
  return safe.to_number(M.get(object, name))
end

--- Read a boolean field, or nil when unreadable.
-- @param object userdata
-- @param name string
-- @return boolean|nil
function M.get_bool(object, name)
  local value = M.get(object, name)
  if type(value) == "boolean" then
    return value
  end
  return nil
end

--- Write a field. Returns true only when the write was accepted.
-- @param object userdata
-- @param name string
-- @param value any
-- @return boolean
function M.set(object, name, value)
  return safe.set_field(object, name, value)
end

--- Invoke a method and return its result, or nil on failure.
-- @param object userdata
-- @param name string
-- @return any|nil
function M.call(object, name, ...)
  local ok, result = safe.call_method(object, name, ...)
  if not ok then
    return nil
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Handle cache
--
-- Cheats hold a handle to a game object and re-resolve it every frame rather
-- than resolving it once at enable time. The cache exists only to avoid
-- hammering the SDK with the same lookup 60 times a second; correctness always
-- wins over the cache.
-- ---------------------------------------------------------------------------

local cache = {}

--- Fetch a cached handle, or resolve and cache it.
--
-- @param key string            stable cache key, e.g. "player_status"
-- @param resolver function     called as resolver(); returns an object or nil
-- @return userdata|nil
function M.acquire(key, resolver)
  local entry = cache[key]
  local frame = logger.frame()

  if entry ~= nil then
    local age = frame - entry.frame
    if age <= MAX_CACHE_AGE_FRAMES and M.is_valid(entry.object) then
      return entry.object
    end

    -- Stale or invalid. Drop it and fall through to a fresh resolve. We log
    -- the drop once per key so a scene transition is visible in the log
    -- without becoming a per-frame flood.
    logger.throttled("stale:" .. key, 120, "debug", "Discovery",
                     "cached handle '" .. key .. "' went stale; re-acquiring")
    cache[key] = nil
  end

  local object = resolver()
  if object == nil then
    return nil
  end

  cache[key] = { object = object, frame = frame }
  return object
end

--- Drop a specific cached handle.
-- @param key string
function M.release(key)
  cache[key] = nil
end

--- Drop every cached handle. Called on scene change and on script reset, so
--- that nothing survives a transition.
function M.release_all()
  cache = {}
end

--- How many handles are currently cached. Surfaced in the debug UI.
-- @return number
function M.cache_size()
  local n = 0
  for _ in pairs(cache) do
    n = n + 1
  end
  return n
end

return M
