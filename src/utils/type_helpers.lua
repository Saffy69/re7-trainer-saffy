--[[--------------------------------------------------------------------------
  re7trainer.utils.type_helpers — read-only introspection over the RE Engine
  type database.

  This module is used by the discovery subsystem, not by the cheats. It exists
  to answer questions about the game's type system without ever mutating
  anything:

    * does this type exist in this build?
    * what methods does it declare?
    * what fields does it declare, and what are their types?
    * what does it inherit from?

  VERIFIED METHOD NAMES
  ---------------------
  Every reflection method called here was confirmed to exist as a literal
  string in the user's installed dinput8.dll (REFramework v1.5.9+7-5bae4701):

      get_methods  get_fields  get_method  get_field  get_name  get_full_name
      get_parent_type  get_type  is_a  get_declaring_type  get_function
      get_num_params  get_param_types  get_return_type  is_static  get_flags
      get_type_definition

  Names that are NOT present in this build and must never be used here:
      get_index  get_field_type  get_object_type  get_typename  get_types
      get_num_fields  get_num_methods

  WHAT THIS MODULE CANNOT DO
  --------------------------
  It reports what the type database declares. It does not — and cannot — tell
  you whether a particular method is the one that actually decrements ammo or
  applies damage. That is what the probes in src/discovery/ are for.
----------------------------------------------------------------------------]]

local safe = require("re7trainer.utils.safe_call")
local logger = require("re7trainer.logger")

local M = {}

-- ---------------------------------------------------------------------------
-- Type lookup
-- ---------------------------------------------------------------------------

--- Look up a type by fully qualified name.
-- @param name string
-- @return userdata|nil TypeDefinition
function M.find(name)
  return safe.type_definition(name)
end

--- Does this type exist in the running build of the game?
-- @param name string
-- @return boolean
function M.exists(name)
  return M.find(name) ~= nil
end

--- Fully qualified name of a type definition.
-- @param type_definition userdata
-- @return string|nil
function M.name_of(type_definition)
  return safe.try(type_definition, "get_full_name")
      or safe.try(type_definition, "get_name")
end

--- Parent type, or nil for a root type.
-- @param type_definition userdata
-- @return userdata|nil
function M.parent_of(type_definition)
  return safe.try(type_definition, "get_parent_type")
end

--- Walk the inheritance chain from `type_definition` up to the root.
-- @param type_definition userdata
-- @return table array of TypeDefinition, nearest first (excludes the type itself)
function M.ancestors(type_definition)
  local chain = {}
  local current = M.parent_of(type_definition)
  local guard = 0

  while current ~= nil and guard < 64 do
    chain[#chain + 1] = current
    current = M.parent_of(current)
    guard = guard + 1
  end

  return chain
end

--- Does `type_definition` derive from the named type anywhere up the chain?
--
-- sdk exposes is_a on the instance API, but for a bare TypeDefinition the
-- reliable route is walking get_parent_type ourselves.
-- @param type_definition userdata
-- @param ancestor_name string
-- @return boolean
function M.derives_from(type_definition, ancestor_name)
  if type_definition == nil then
    return false
  end
  if M.name_of(type_definition) == ancestor_name then
    return true
  end

  for _, ancestor in ipairs(M.ancestors(type_definition)) do
    if M.name_of(ancestor) == ancestor_name then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Members
-- ---------------------------------------------------------------------------

--- Declared methods of a type.
-- @param type_definition userdata
-- @return table array of Method objects (possibly empty)
function M.methods(type_definition)
  local result = safe.try(type_definition, "get_methods")
  if type(result) ~= "table" then
    return {}
  end
  return result
end

--- Declared fields of a type.
-- @param type_definition userdata
-- @return table array of Field objects (possibly empty)
function M.fields(type_definition)
  local result = safe.try(type_definition, "get_fields")
  if type(result) ~= "table" then
    return {}
  end
  return result
end

--- Method names only.
-- @param type_definition userdata
-- @return table array of string
function M.method_names(type_definition)
  local names = {}
  for _, method in ipairs(M.methods(type_definition)) do
    local name = safe.try(method, "get_name")
    if name ~= nil then
      names[#names + 1] = name
    end
  end
  return names
end

--- Field names only.
-- @param type_definition userdata
-- @return table array of string
function M.field_names(type_definition)
  local names = {}
  for _, field in ipairs(M.fields(type_definition)) do
    local name = safe.try(field, "get_name")
    if name ~= nil then
      names[#names + 1] = name
    end
  end
  return names
end

--- Build a readable signature string for a method.
--
-- Uses get_num_params / get_param_types / get_return_type, all verified
-- present in this build. The exact shape of what get_param_types returns is
-- NOT verified — it may be a table of TypeDefinition, or a table of names. The
-- pcall-and-inspect approach below handles both and reports what it found, so
-- a wrong assumption produces a slightly ugly string rather than an error.
--
-- @param method userdata
-- @return string
function M.describe_method(method)
  local name = safe.try(method, "get_name") or "<unnamed>"
  local num_params = safe.try(method, "get_num_params")
  local return_type = safe.try(method, "get_return_type")
  local is_static = safe.try(method, "is_static")

  local return_name = "?"
  if return_type ~= nil then
    return_name = M.name_of(return_type) or "?"
  end

  local parts = {}
  local param_types = safe.try(method, "get_param_types")
  if type(param_types) == "table" then
    for _, param in ipairs(param_types) do
      if type(param) == "string" then
        parts[#parts + 1] = param
      else
        parts[#parts + 1] = M.name_of(param) or "?"
      end
    end
  end

  -- Fall back to the declared arity when we could not read the param list, so
  -- the output still tells us how many arguments the method takes.
  local param_text
  if #parts > 0 then
    param_text = table.concat(parts, ", ")
  elseif type(num_params) == "number" then
    param_text = "?" .. " (" .. num_params .. " params)"
  else
    param_text = ""
  end

  local prefix = ""
  if is_static == true then
    prefix = "static "
  end

  return prefix .. return_name .. " " .. name .. "(" .. param_text .. ")"
end

--- Build a readable description of a field, including its declared type.
-- @param field userdata
-- @return string
function M.describe_field(field)
  local name = safe.try(field, "get_name") or "<unnamed>"
  local field_type = safe.try(field, "get_type")
  local type_name = M.name_of(field_type) or "?"
  return type_name .. " " .. name
end

-- ---------------------------------------------------------------------------
-- Bulk dump
-- ---------------------------------------------------------------------------

--- Produce a structured, serialisable description of a type.
--
-- This is the payload the discovery subsystem writes out. It is deliberately
-- plain data (strings and tables) so it can go straight through json.dump_file.
--
-- @param name string fully qualified type name
-- @return table|nil
function M.dump_type(name)
  local type_definition = M.find(name)
  if type_definition == nil then
    return {
      type_name = name,
      found = false,
    }
  end

  local methods = {}
  for _, method in ipairs(M.methods(type_definition)) do
    methods[#methods + 1] = M.describe_method(method)
  end
  table.sort(methods)

  local fields = {}
  for _, field in ipairs(M.fields(type_definition)) do
    fields[#fields + 1] = M.describe_field(field)
  end
  table.sort(fields)

  local parents = {}
  for _, ancestor in ipairs(M.ancestors(type_definition)) do
    parents[#parents + 1] = M.name_of(ancestor) or "?"
  end

  return {
    type_name = name,
    found = true,
    full_name = M.name_of(type_definition),
    parents = parents,
    method_count = #methods,
    field_count = #fields,
    methods = methods,
    fields = fields,
  }
end

--- Dump several types at once, skipping any that do not exist.
-- @param names table array of string
-- @return table array of dump_type results
function M.dump_types(names)
  local results = {}
  for _, name in ipairs(names) do
    results[#results + 1] = M.dump_type(name)
  end
  return results
end

--- Search the type database for types whose name contains `substring`.
--
-- Deliberately NOT used for bulk scanning at startup: it is O(n) over every
-- type in the game and is rate-limited to an explicit user action in the UI.
--
-- @param substring string case-insensitive
-- @param limit number maximum results to return
-- @return table array of string
function M.search(substring, limit)
  if type(sdk) ~= "table" then
    return {}
  end

  local needle = string.lower(substring)
  local found = {}
  limit = limit or 100

  -- The SDK's type collection accessor differs across framework versions, so
  -- this is guarded rather than assumed. If unavailable we report that plainly
  -- instead of silently returning an empty list that looks like "no matches".
  local ok, all_types = pcall(function()
    return sdk.get_types and sdk.get_types() or nil
  end)

  if not ok or type(all_types) ~= "table" then
    logger.once("search:notypes", "warn", "Discovery",
                "Type-list enumeration is not available in this REFramework build; " ..
                "use the explicit type list instead of substring search.")
    return {}
  end

  for _, type_definition in ipairs(all_types) do
    if #found >= limit then
      break
    end
    local name = M.name_of(type_definition)
    if name ~= nil and string.find(string.lower(name), needle, 1, true) then
      found[#found + 1] = name
    end
  end

  return found
end

return M
