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

-- ---------------------------------------------------------------------------
-- Hooking
--
-- INSTALL-ONCE SEMANTICS. THIS IS NOT A STYLE CHOICE.
--
-- This REFramework build exposes sdk.hook but has NO unhook and NO
-- remove_hook -- both confirmed absent from the installed binary. A hook, once
-- installed, is permanent for the life of the process.
--
-- Every design decision below follows from that:
--
--   1. A hook is installed at most once per method, tracked by key, so
--      repeated enable() calls cannot stack duplicate hooks on the same
--      function. Stacking them would multiply the work per call and, for
--      SKIP_ORIGINAL hooks, is the kind of thing that turns into a crash.
--   2. The cheat's enabled/disabled state is carried by a FLAG the callback
--      reads, not by the presence of the hook. Disabling a cheat stops it
--      doing anything; it does not and cannot uninstall anything.
--   3. The callback body must be cheap. It runs on whatever game thread
--      invoked the method, while holding the Lua lock, so it stalls that
--      thread for as long as it takes.
-- ---------------------------------------------------------------------------

--- Keys of hooks already installed, so they are never installed twice.
local installed = {}

--- Per-hook invocation counters, keyed the same way.
--
-- WHY THIS EXISTS. "The cheat does nothing" has two completely different
-- causes that look identical from the outside:
--
--   (a) the hook was never installed -- get_method returned nil, or sdk.hook
--       threw, or the cheat was never actually enabled
--   (b) the hook installed fine but the game never calls that method, so the
--       callback never runs
--
-- Guessing between them wastes a round trip. A counter settles it: zero
-- invocations while the player is being shot means the target is wrong, not
-- the hook. Anything else means the target is right and the decision inside
-- the callback is the problem.
local invocations = {}

--- Last decision a pre-callback returned, per hook key. Diagnostic only.
local last_decision = {}

--- Install a hook on a method, at most once.
--
-- The pre-callback receives a 1-indexed table of raw void*:
--     args[1] = REThreadContext*
--     args[2] = the `this` pointer
--     args[3..] = parameters
-- Mutating the table writes back to the real arguments. Returning
-- sdk.PreHookResult.SKIP_ORIGINAL skips the original method body.
--
-- Use sdk.to_managed_object(args[2]) to get a usable object back from the
-- raw pointer.
--
-- @param key string         unique key, e.g. "app.Item.reduceNum"
-- @param type_name string   e.g. "app.Item"
-- @param method_name string e.g. "reduceNum"
-- @param pre function|nil
-- @param post function|nil
-- @return boolean ok, string|nil detail
function M.hook_method(key, type_name, method_name, pre, post)
  if installed[key] then
    -- Already hooked. This is the normal path on a second enable(), not an
    -- error: the flag inside the callback is what changes.
    return true, "already hooked"
  end

  if type(sdk) ~= "table" or type(sdk.hook) ~= "function" then
    logger.error("Error", "sdk.hook is unavailable in this build")
    return false, "sdk.hook unavailable"
  end

  local type_definition = M.type_definition(type_name)
  if type_definition == nil then
    return false, "type not found: " .. type_name
  end

  -- get_method takes the method name as an argument, so it cannot go through
  -- M.try (which only calls zero-argument accessors).
  local ok_method, found = pcall(function()
    return type_definition:get_method(method_name)
  end)

  if not ok_method or found == nil then
    return false, "method not found: " .. type_name .. "." .. method_name
  end

  local ok, hook_id = pcall(sdk.hook, found, pre, post, false)
  if not ok then
    logger.error("Error", "sdk.hook(" .. key .. ") threw: " .. tostring(hook_id))
    return false, tostring(hook_id)
  end

  installed[key] = true
  invocations[key] = 0
  logger.info("Hook", "Installed on " .. type_name .. "." .. method_name)
  return true, nil
end

--- Record that a hook's pre-callback fired, and what it decided.
--
-- Called by the cheat callbacks themselves rather than by a wrapper, because
-- wrapping would hide the real callback from the selfcheck and would add a
-- closure layer inside a function that runs on the game thread.
-- @param key string
-- @param decision any the value the callback returned
function M.note_invocation(key, decision)
  invocations[key] = (invocations[key] or 0) + 1
  last_decision[key] = tostring(decision)
end

--- How many times a hook's callback has run.
-- @param key string
-- @return number
function M.invocation_count(key)
  return invocations[key] or 0
end

--- The last decision value a hook's callback returned, as a string.
-- @param key string
-- @return string|nil
function M.last_decision(key)
  return last_decision[key]
end

--- Summary of every hook, for the debug panel.
-- @return table array of { key, installed, invocations, last_decision }
function M.hook_report()
  local report = {}
  for key in pairs(installed) do
    report[#report + 1] = {
      key = key,
      installed = true,
      invocations = invocations[key] or 0,
      last_decision = last_decision[key],
    }
  end
  table.sort(report, function(a, b) return a.key < b.key end)
  return report
end

--- Has a hook already been installed for this key?
-- @param key string
-- @return boolean
function M.is_hooked(key)
  return installed[key] ~= nil
end

--- How many hooks this session has installed.
-- @return number
function M.hook_count()
  local n = 0
  for _ in pairs(installed) do
    n = n + 1
  end
  return n
end

--- Convert a raw hook argument pointer into a usable managed object.
--
-- Hook arguments arrive as bare void*, so reading a field off one requires
-- this hop. sdk.to_managed_object was confirmed present in the installed
-- binary; the pcall is there because a null pointer is a normal occurrence
-- (any argument may legitimately be nil).
--
-- @param pointer any
-- @return userdata|nil
function M.to_managed_object(pointer)
  if pointer == nil then
    return nil
  end
  if type(sdk) ~= "table" or type(sdk.to_managed_object) ~= "function" then
    return nil
  end

  local ok, object = pcall(sdk.to_managed_object, pointer)
  if not ok then
    return nil
  end
  return object
end

return M
