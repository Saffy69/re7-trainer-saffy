--[[--------------------------------------------------------------------------
  re7trainer.discovery.introspect — capability probe for the reflection API.

  WHY THIS EXISTS
  ---------------
  The first discovery dump came back with real inheritance chains but ZERO
  methods and ZERO fields for every candidate type:

      app.PlayerDamageController  (0m/0f)
        parents = app.DamageController, app.DoomsUpdater, app.DoomsBehavior,
                  via.Behavior, via.Component, System.Object

  That combination is informative. get_full_name() and get_parent_type() both
  returned correct data, so the type database IS reachable and those bindings
  work. Only the member accessors came back empty.

  The likely cause is a SHAPE mismatch, not a missing API: get_methods() and
  get_fields() most likely return something that is not a plain Lua array —
  a sol2 container, a map keyed from 0, or a userdata with its own iteration —
  and our code does `if type(result) ~= "table" then return {} end`, which
  silently turns anything unexpected into "empty".

  That silent coercion is the actual bug: it made a shape mismatch look
  identical to "this type genuinely has no members". This module replaces the
  guess with a measurement.

  WHAT IT DOES
  ------------
  For each candidate accessor it reports, as data:
    * whether the accessor exists on the object at all
    * what type() the call result actually is
    * for tables: the ipairs length, the pairs() key count, the types of the
      keys, and a sample of the values
    * for userdata: whether #, size(), and index access work
    * the type() and a short description of each sampled element

  The output is deliberately verbose and boring. Its whole purpose is to be
  unambiguous when read back, so the next implementation step is a decision
  rather than another guess.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local safe = require("re7trainer.utils.safe_call")

local M = {}

M.OUTPUT_FILE = "re7trainer_introspect.json"

--- Types to probe. A small, representative set chosen so that the answer
--- distinguishes the competing explanations:
---   System.Object      - a type with well-known declared members
---   app.HealthInfo     - a plain non-Behavior type, parent System.Object
---   app.fsm.HealthSet  - derives from via.fsm.Action
---   app.PlayerDamageController - derives from via.Component
---   app.InventoryManager       - derives from app.SingletonBehavior
M.PROBE_TYPES = {
  "System.Object",
  "app.HealthInfo",
  "app.fsm.HealthSet",
  "app.PlayerDamageController",
  "app.InventoryManager",
}

--- Accessors to interrogate on a TypeDefinition.
M.TYPE_ACCESSORS = {
  "get_name",
  "get_full_name",
  "get_parent_type",
  "get_methods",
  "get_fields",
  "get_method",
  "get_field",
}

--- Methods to interrogate on whatever get_methods()/get_fields() returns.
M.MEMBER_ACCESSORS = {
  "get_name",
  "get_full_name",
  "get_type",
  "get_return_type",
  "get_num_params",
  "get_param_types",
  "is_static",
  "get_declaring_type",
  "get_function",
}

-- ---------------------------------------------------------------------------
-- Value description
-- ---------------------------------------------------------------------------

--- Describe an arbitrary value compactly and without throwing.
-- @param value any
--- @param depth number  recursion guard
-- @return string
function M.describe_value(value, depth)
  depth = depth or 0
  local kind = type(value)

  if value == nil then
    return "nil"
  end

  if kind == "number" or kind == "boolean" or kind == "string" then
    local text = tostring(value)
    if #text > 80 then
      text = text:sub(1, 77) .. "..."
    end
    return kind .. "(" .. text .. ")"
  end

  if kind == "table" then
    if depth >= 2 then
      return "table(<max depth>)"
    end

    local n = 0
    for _ in pairs(value) do n = n + 1 end

    local length = #value
    local key_kinds = {}
    local sample = nil
    local sample_key = nil

    for k, v in pairs(value) do
      local kk = type(k)
      key_kinds[kk] = (key_kinds[kk] or 0) + 1
      if sample == nil then
        sample = v
        sample_key = k
      end
    end

    local kinds = {}
    for kk, count in pairs(key_kinds) do
      kinds[#kinds + 1] = kk .. "=" .. count
    end
    table.sort(kinds)

    local text = string.format("table(len=#%d, pairs=%d, keys{%s})",
                               length, n, table.concat(kinds, ","))
    if sample ~= nil then
      text = text .. " first[" .. tostring(sample_key) .. "]="
                 .. M.describe_value(sample, depth + 1)
    end
    return text
  end

  -- userdata / function / thread: probe a few generic accessors.
  local probes = {}

  local ok_len, len = pcall(function() return #value end)
  probes[#probes + 1] = "len#=" .. (ok_len and tostring(len) or "err")

  for _, name in ipairs({ "size", "get_size", "get_count", "get_num" }) do
    local ok, res = pcall(function() return value[name](value) end)
    if ok then
      probes[#probes + 1] = name .. "()=" .. tostring(res)
    end
  end

  return kind .. "(" .. table.concat(probes, " ") .. ")"
end

-- ---------------------------------------------------------------------------
-- Accessor probing
-- ---------------------------------------------------------------------------

--- Probe one accessor on one object.
-- @param object userdata
-- @param name string
-- @return table
function M.probe_accessor(object, name)
  local entry = {
    accessor = name,
    index_kind = type(object[name]),
  }

  if type(object[name]) ~= "function" then
    entry.callable = false
    return entry
  end

  entry.callable = true

  local ok, result = pcall(function()
    return object[name](object)
  end)

  entry.call_ok = ok
  if not ok then
    entry.error = tostring(result)
    return entry
  end

  entry.result = M.describe_value(result)
  entry.result_type = type(result)

  -- If it is an array-like table, describe its first element in detail, since
  -- that is what we actually need in order to iterate members.
  if type(result) == "table" then
    local first = result[1]
    if first == nil then
      -- Try 0-based indexing, a classic sol2/vector binding difference.
      first = result[0]
      if first ~= nil then
        entry.zero_indexed = true
      end
    end

    if first ~= nil then
      entry.first_element = M.describe_value(first)
      entry.first_element_members = {}
      for _, member in ipairs(M.MEMBER_ACCESSORS) do
        entry.first_element_members[#entry.first_element_members + 1] =
          M.probe_accessor(first, member)
      end
    end
  end

  return entry
end

--- Probe a single type end to end.
-- @param name string
-- @return table
function M.probe_type(name)
  local report = {
    type_name = name,
    accessors = {},
  }

  local exists = safe.type_definition(name) ~= nil
  report.type_found = exists

  if not exists then
    return report
  end

  local type_definition = safe.type_definition(name)

  for _, accessor in ipairs(M.TYPE_ACCESSORS) do
    report.accessors[#report.accessors + 1] = M.probe_accessor(type_definition, accessor)
  end

  return report
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------

--- Run the whole probe and write the result out.
-- @return boolean ok, string|nil detail
function M.run()
  if not safe.has_sdk() then
    return false, "REFramework SDK is not available"
  end

  local payload = {
    schema = "re7trainer-introspect",
    schema_version = 1,
    note = "Capability probe: reports what the reflection bindings actually return.",
    types = {},
  }

  for _, name in ipairs(M.PROBE_TYPES) do
    payload.types[#payload.types + 1] = M.probe_type(name)
  end

  -- Summarise the one thing that matters most, so it is readable in the log
  -- without opening the JSON.
  local get_methods_shape = "unknown"
  for _, entry in ipairs(payload.types) do
    if entry.type_name == "app.PlayerDamageController" then
      for _, a in ipairs(entry.accessors) do
        if a.accessor == "get_methods" then
          get_methods_shape = tostring(a.result) .. "  [call_ok=" .. tostring(a.call_ok) .. "]"
        end
      end
    end
  end

  logger.info("Introspect", "get_methods() on app.PlayerDamageController returned: " .. get_methods_shape)

  local wrote = false
  if type(json) == "table" and type(json.dump_file) == "function" then
    local ok, err = pcall(json.dump_file, M.OUTPUT_FILE, payload)
    if ok then
      wrote = true
      logger.info("Introspect", "Wrote " .. M.OUTPUT_FILE)
    else
      logger.error("Introspect", "Could not write " .. M.OUTPUT_FILE .. ": " .. tostring(err))
    end
  end

  return true, wrote and M.OUTPUT_FILE or "log only"
end

return M
