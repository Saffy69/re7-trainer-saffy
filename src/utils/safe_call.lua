--[[--------------------------------------------------------------------------
  re7trainer.utils.safe_call — the safety layer between the trainer and
  REFramework's Lua bindings.

  WHY THIS EXISTS
  ---------------
  Every call into the RE Engine type database can fail in ways that are normal
  and expected, not exceptional:

    * the type does not exist in this build of the game
    * the method exists but has a different arity than we assumed
    * the singleton has not been constructed yet (we are still on the main menu)
    * the object we cached three scenes ago is now a dangling pointer

  In Lua, dereferencing a dangling RE Engine object is not a clean error — it
  can be a hard crash of the game process. So the rules for this module are:

    1. NEVER let an error escape to the frame callback. A trainer that crashes
       the game is worse than a trainer that does nothing.
    2. NEVER silently swallow an error. Every failure is logged, but through
       logger.throttled so a per-frame failure does not become a per-frame log
       flood.
    3. Return nil/false on failure so callers can branch on it.

  The wrappers take a short human-readable `description` rather than relying on
  Lua stack traces, because inside REFramework the stack trace points at
  generated binding code and is close to useless for diagnosis.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")

local M = {}

--- Unpack a list into varargs, across Lua versions.
-- table.unpack landed in 5.2; 5.1 and LuaJIT expose the global `unpack`. The
-- installed REFramework build embeds a Lua 5.4 package.path, but the framework
-- has shipped against several Lua versions over its life, so this costs
-- nothing and removes a whole class of "works on my build" failure.
local unpack = table.unpack or unpack

--- Frames between repeated reports of the same failing call.
-- At 60fps this is roughly one report every 5 seconds: frequent enough to
-- notice while playing, quiet enough not to drown the log.
local FAILURE_LOG_INTERVAL = 300

-- ---------------------------------------------------------------------------
-- Generic pcall wrapper
-- ---------------------------------------------------------------------------

--- Call `fn(...)` without ever throwing.
--
-- @param description string  short name used in log output, e.g. "app.PlayerStatus.GetHealth"
-- @param fn function
-- @return boolean ok, any result
function M.call(description, fn, ...)
  if type(fn) ~= "function" then
    logger.throttled("notfn:" .. tostring(description), FAILURE_LOG_INTERVAL,
                     "error", "Error", tostring(description) .. ": target is not a function")
    return false, nil
  end

  local ok, result = pcall(fn, ...)
  if not ok then
    logger.throttled("callfail:" .. tostring(description), FAILURE_LOG_INTERVAL,
                     "error", "Error", tostring(description) .. " threw: " .. tostring(result))
    return false, nil
  end
  return true, result
end

-- ---------------------------------------------------------------------------
-- REFramework SDK entry points
--
-- The bare names used here (get_managed_singleton, find_type_definition,
-- get_method, get_field, ...) were each verified to exist as literal strings
-- in the user's installed dinput8.dll. See docs/COMPATIBILITY.md for the
-- verification method and the full verified/absent list.
-- ---------------------------------------------------------------------------

--- Is the REFramework SDK table reachable at all?
-- The trainer calls this once at startup; if it returns false we are either
-- not running under REFramework or running under an incompatible build, and
-- every other capability is disabled rather than guessed at.
-- @return boolean
function M.has_sdk()
  return type(sdk) == "table"
end

--- Fetch a managed singleton by name.
-- @param name string  e.g. "app.InventoryManager"
-- @return userdata|nil
function M.singleton(name)
  if type(sdk) ~= "table" then
    return nil
  end
  local fn = sdk.get_managed_singleton
  if type(fn) ~= "function" then
    logger.once("nosdk:gms", "error", "Error", "sdk.get_managed_singleton is unavailable in this build")
    return nil
  end

  local ok, result = pcall(fn, name)
  if not ok then
    logger.throttled("singleton:" .. name, FAILURE_LOG_INTERVAL,
                     "error", "Error", "get_managed_singleton('" .. name .. "') threw: " .. tostring(result))
    return nil
  end
  return result
end

--- Fetch a native singleton by name.
-- @param name string
-- @return userdata|nil
function M.native_singleton(name)
  if type(sdk) ~= "table" then
    return nil
  end
  local fn = sdk.get_native_singleton
  if type(fn) ~= "function" then
    return nil
  end

  local ok, result = pcall(fn, name)
  if not ok then
    logger.throttled("nsingleton:" .. name, FAILURE_LOG_INTERVAL,
                     "error", "Error", "get_native_singleton('" .. name .. "') threw: " .. tostring(result))
    return nil
  end
  return result
end

--- Look up a type definition in the game's type database.
-- @param name string  fully qualified, e.g. "app.PlayerStatus"
-- @return userdata|nil
function M.type_definition(name)
  if type(sdk) ~= "table" then
    return nil
  end
  local fn = sdk.find_type_definition
  if type(fn) ~= "function" then
    logger.once("nosdk:ftd", "error", "Error", "sdk.find_type_definition is unavailable in this build")
    return nil
  end

  local ok, result = pcall(fn, name)
  if not ok then
    logger.throttled("typedef:" .. name, FAILURE_LOG_INTERVAL,
                     "error", "Error", "find_type_definition('" .. name .. "') threw: " .. tostring(result))
    return nil
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Instance member access
-- ---------------------------------------------------------------------------

--- Read an instance field by name.
--
-- `sdk` reachable via the instance itself, so this works for any RE Engine
-- managed object whose type we already hold.
--
-- @param object userdata
-- @param name string
-- @return boolean ok, any value
function M.get_field(object, name)
  if object == nil then
    return false, nil
  end

  local ok, result = pcall(function()
    return object:get_field(name)
  end)

  if not ok then
    logger.throttled("getfield:" .. tostring(name), FAILURE_LOG_INTERVAL,
                     "error", "Error", "get_field('" .. tostring(name) .. "') threw: " .. tostring(result))
    return false, nil
  end
  return true, result
end

--- Write an instance field by name.
--
-- Writability differs per field: RE Engine exposes many fields read-only
-- through the SDK. A write to a read-only field raises, which we catch and
-- report rather than propagating.
--
-- @param object userdata
-- @param name string
-- @param value any
-- @return boolean ok
function M.set_field(object, name, value)
  if object == nil then
    return false
  end

  local ok, err = pcall(function()
    object:set_field(name, value)
  end)

  if not ok then
    logger.throttled("setfield:" .. tostring(name), FAILURE_LOG_INTERVAL,
                     "error", "Error", "set_field('" .. tostring(name) .. "') threw: " .. tostring(err))
    return false
  end
  return true
end

--- Invoke an instance method by name.
--
-- @param object userdata
-- @param name string
-- @return boolean ok, any result
function M.call_method(object, name, ...)
  if object == nil then
    return false, nil
  end

  local args = { ... }
  local ok, result = pcall(function()
    return object:call(name, unpack(args))
  end)

  if not ok then
    logger.throttled("callmethod:" .. tostring(name), FAILURE_LOG_INTERVAL,
                     "error", "Error", "call('" .. tostring(name) .. "') threw: " .. tostring(result))
    return false, nil
  end
  return true, result
end

-- ---------------------------------------------------------------------------
-- Introspection helpers used by the discovery subsystem
-- ---------------------------------------------------------------------------

--- Call a zero-argument accessor on a reflection object, returning nil on failure.
-- Used heavily by discovery, where we are deliberately poking at methods we
-- have never seen and expect some of them to reject us.
-- @param object userdata
-- @param method_name string
-- @return any|nil
function M.try(object, method_name)
  if object == nil then
    return nil
  end
  local ok, result = pcall(function()
    return object[method_name](object)
  end)
  if not ok then
    return nil
  end
  return result
end

--- Safely read a numeric value that may arrive as a Lua number or a userdata
--- integer type. Returns nil when the value cannot be interpreted.
--
-- REFramework surfaces 64-bit integers as userdata in some contexts; sdk.to_int64
-- and sdk.to_float exist to normalise them. Both were verified present in the
-- installed binary, but we still guard the call.
-- @param value any
-- @return number|nil
function M.to_number(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "boolean" then
    return value and 1 or 0
  end
  if type(sdk) ~= "table" then
    return nil
  end

  for _, converter in ipairs({ "to_float", "to_double", "to_int64" }) do
    local fn = sdk[converter]
    if type(fn) == "function" then
      local ok, result = pcall(fn, value)
      if ok and type(result) == "number" then
        return result
      end
      -- to_int64 may hand back userdata; try one more hop through to_float.
      if ok and result ~= nil then
        local ok2, result2 = pcall(function() return tonumber(result) end)
        if ok2 and type(result2) == "number" then
          return result2
        end
      end
    end
  end
  return nil
end

return M
