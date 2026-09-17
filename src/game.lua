--[[--------------------------------------------------------------------------
  re7trainer.game — RE7-specific accessors.

  This is the only module that knows the concrete shape of RE7's object graph.
  Keeping it in one place means that when a field is renamed by a game update,
  or a route turns out to be wrong, there is exactly one file to fix — and the
  cheats above it stay written in terms of "the inventory" and "the player"
  rather than in terms of field reads.

  EVERY ROUTE HERE CAME FROM A LIVE DISCOVERY DUMP. See docs/DISCOVERY_RESULTS.md.
  None of it is inferred from a type name.
----------------------------------------------------------------------------]]

local safe = require("re7trainer.utils.safe_call")
local objects = require("re7trainer.utils.object_helpers")
local logger = require("re7trainer.logger")

local M = {}

-- ---------------------------------------------------------------------------
-- The player
-- ---------------------------------------------------------------------------

--- The active player inventory.
--
-- Two independent routes exist, and both are attempted because each can fail
-- in a different situation:
--
--   A. app.Inventory.getActivePlayerInventory() -- a static method, no
--      singleton lookup, no field read. Preferred: it cannot hold a stale
--      reference and it re-resolves against the live game every call.
--   B. sdk.get_managed_singleton("app.InventoryManager")._Inventory --
--      the singleton is confirmed constructed at runtime, and _Inventory is
--      its own field. Used as a fallback.
--
-- Called fresh every time on purpose. Caching either would risk holding a
-- reference across a scene change, which is where trainers crash.
--
-- @return userdata|nil app.Inventory
function M.inventory()
  -- Route A: app.Inventory.getActivePlayerInventory(), a static method.
  --
  -- Called through the REMethodDefinition's own `call`, which is registered on
  -- that type in this build. is_static is checked first: calling a method with
  -- a nil receiver is only correct for a static, and getting that wrong is the
  -- kind of mistake that reads as a game crash rather than a Lua error.
  local type_definition = safe.type_definition("app.Inventory")
  if type_definition ~= nil then
    local ok, method = pcall(function()
      return type_definition:get_method("getActivePlayerInventory")
    end)

    if ok and method ~= nil then
      local is_static = safe.try(method, "is_static")
      if is_static == true then
        local called, result = pcall(function()
          return method:call(nil)
        end)
        if called and result ~= nil then
          return result
        end
      end
    end
  end

  -- Route B: the managed singleton, whose _Inventory field is the inventory.
  local manager = safe.singleton("app.InventoryManager")
  if manager ~= nil then
    local inventory = objects.get(manager, "_Inventory")
    if inventory ~= nil then
      return inventory
    end
  end

  return nil
end

--- The player's status component.
--
-- app.PlayerStatus is the hub: it holds PlayerGun, Inventory, EquipManager and
-- PlayerDamageController as fields. Health accessors are inherited from
-- app.CharacterCommonStatus, which is where get_health / get_maxHealth /
-- get_IsDead / set_isForbidDamageReaction come from.
--
-- The field is typed app.IPlayerStatus (an interface). Method calls go through
-- REFramework's dynamic dispatch on the concrete object, so the inherited
-- accessors resolve normally — but the type check below is deliberately done
-- against the live object rather than trusting the declared field type.
--
-- @return userdata|nil
function M.player_status()
  local inventory = M.inventory()
  if inventory == nil then
    return nil
  end

  local status = objects.get(inventory, "PlayerStatus")
  if status == nil then
    return nil
  end

  if not objects.is_valid(status) then
    return nil
  end

  return status
end

--- The player's damage controller.
-- Preferred hook target for preventing damage; also a useful fallback source
-- for the max-health table reference.
-- @return userdata|nil
function M.damage_controller()
  local status = M.player_status()
  if status == nil then
    return nil
  end
  return objects.get(status, "PlayerDamageController")
end

-- ---------------------------------------------------------------------------
-- Health
-- ---------------------------------------------------------------------------

--- Current and maximum health, or nil if unreadable.
-- @return table|nil { current = number, max = number, normalized = number }
function M.health()
  local status = M.player_status()
  if status == nil then
    return nil
  end

  local current = safe.to_number(objects.call(status, "get_health"))
  local maximum = safe.to_number(objects.call(status, "get_maxHealth"))

  if current == nil then
    return nil
  end

  return {
    current = current,
    max = maximum,
    normalized = safe.to_number(objects.call(status, "get_normalizedHealth")),
  }
end

--- The damage controller, which is where health actually lives.
--
-- app.PlayerDamageController derives from app.DamageController, and it is the
-- BASE class that carries the writable health record:
--
--     F app.HealthInfo HealthInfo
--     M app.HealthInfo getHealthInfo()
--     M System.Void    adjustHealth(?), setHealth(?), recoveryHealth(?)
--
-- The subclass exposes only reaction/motion work -- doDamage, playDamage*Motion.
-- Confirmed in game: hooking PlayerDamageController.doDamage and skipping it
-- did not prevent health loss, because that method is not where health changes.
--
-- @return userdata|nil
function M.health_info()
  local controller = M.damage_controller()
  if controller == nil then
    -- Fall back to the player status, which may expose the same accessor
    -- through a different inheritance route.
    controller = M.player_status()
    if controller == nil then
      return nil
    end
  end

  local info = objects.call(controller, "getHealthInfo")
  if info == nil then
    info = objects.get(controller, "HealthInfo")
  end

  if info == nil or not objects.is_valid(info) then
    return nil
  end

  return info
end

--- Write the player's health, and VERIFY the write actually took.
--
-- WHY THIS IS NOT A ONE-LINER
-- ---------------------------
-- The first version called app.HealthInfo:set_health(value) and checked only
-- that the call did not error. In game it returned success every time while
-- health kept dropping -- app.HealthInfo is a value type, so getHealthInfo()
-- hands back a COPY, and writing to the copy is discarded. The cheat reported
-- "restored" hundreds of times and changed nothing.
--
-- A write that reports success and has no effect is worse than one that fails,
-- because it looks like it is working. So every route below is followed by a
-- re-read, and success means the number actually moved.
--
-- Routes, in order:
--   1. app.DamageController.setHealth(value, maxHealth) -- on the real
--      component object, not a struct copy. Two parameters, so the second is
--      assumed to be the maximum; if that assumption is wrong the verify step
--      catches it rather than silently corrupting anything.
--   2. app.DamageController.adjustHealth(delta) -- add back what was lost.
--   3. app.HealthInfo.set_health -- kept last, because it is the route already
--      proven not to work; it costs nothing to leave as a final fallback.
--
-- @param value number  the health to restore to
-- @return boolean ok, string detail
function M.set_health(value)
  local before = M.health()
  if before == nil then
    return false, "health unreadable before write"
  end

  local controller = M.damage_controller()
  local maximum = before.max or value

  --- Re-read and report whether the value actually moved.
  local function verify(route)
    local after = M.health()
    if after == nil then
      return false, route .. ": unreadable after write"
    end
    if math.abs(after.current - value) < 0.01 then
      return true, route
    end
    return false, string.format("%s: no effect (%.1f -> %.1f, wanted %.1f)",
                                route, before.current, after.current, value)
  end

  if controller ~= nil then
    -- Route 1: the controller's own setter.
    if safe.call_method(controller, "setHealth", value, maximum) then
      local ok, detail = verify("setHealth")
      if ok then
        return true, detail
      end
    end

    -- Route 2: adjust by the difference.
    local delta = value - before.current
    if delta ~= 0 and safe.call_method(controller, "adjustHealth", delta) then
      local ok, detail = verify("adjustHealth")
      if ok then
        return true, detail
      end
    end
  end

  -- Route 3: the struct-copy route, kept only as a last resort.
  local info = M.health_info()
  if info ~= nil then
    if safe.call_method(info, "set_health", value) then
      local ok, detail = verify("HealthInfo.set_health")
      if ok then
        return true, detail
      end
    end
    if objects.set(info, "Health", value) then
      local ok, detail = verify("HealthInfo.Health field")
      if ok then
        return true, detail
      end
    end
  end

  return false, "no health write route had any effect"
end

--- Is the player dead, according to the game?
-- @return boolean|nil
function M.is_dead()
  local status = M.player_status()
  if status == nil then
    return nil
  end
  local value = objects.call(status, "get_IsDead")
  if type(value) == "boolean" then
    return value
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Items and their categories
-- ---------------------------------------------------------------------------

--- Category values the trainer is allowed to conserve.
--
-- READ OFF THE RUNNING GAME, not from the enum's declaration order.
--
-- A live item dump on build 22773795 reported these, each with the item it came
-- from, and the mapping is consistent across every sample:
--
--   1  Knife, Handgun G17          -> Weapon
--   2  ShotgunBullet, HandgunBullet -> Shell       CONSERVE
--   3  RemedyM, Stimulant           -> Drug        CONSERVE
--   4  MorgueKey                    -> KeyItem
--   7  ChemicalM                    -> Material    CONSERVE
--
-- The enum's own member names sort alphabetically in a reflection listing, so
-- the names cannot be paired with numbers by position -- the numbers had to be
-- observed. Only the three conservable values are listed; everything else,
-- including any value not seen here, is treated as untouchable.
M.SAFE_CATEGORY_VALUES = {
  [2] = "Shell",
  [3] = "Drug",
  [7] = "Material",
}

--- Category names the trainer is allowed to conserve, when a name is available.
-- Kept for the case where a build surfaces the enum as a string instead of a
-- number; both spellings of the same set are accepted.
M.SAFE_CATEGORIES = {
  Drug = true,
  Material = true,
  Shell = true,
}

--- Category values the user has opted into, beyond the three defaults.
--
-- RUNTIME ONLY, never persisted. A category that was conservable last session
-- is not a fact about this one, and a stale allowlist is exactly the kind of
-- hidden state that makes a trainer behave in ways its owner cannot explain.
--
-- THE GATE IS STILL AN ALLOWLIST, and this is the only way a category becomes
-- conservable on top of the three defaults. A value that is not in here and
-- not a default stays untouchable -- so a category this build has that the
-- discovery dump never showed is still refused rather than swept up.
--
-- What this is for: the dump established values 1, 2, 3, 4 and 7. It did NOT
-- establish 5, 6, 8 or anything above, because the enum's members sort
-- alphabetically in a reflection listing and the numbers had to be observed
-- rather than derived. This lets an observed value be added live, from the
-- inventory in front of the player, instead of being guessed at here.
local extra_conserved = {}

--- Is this category value conserved, by default or by choice?
-- @param value number|nil
-- @return boolean
function M.category_conserved(value)
  if type(value) ~= "number" then
    return false
  end
  if M.SAFE_CATEGORY_VALUES[value] ~= nil then
    return true
  end
  return extra_conserved[value] == true
end

--- Is this value conserved because the user opted in, rather than by default?
-- Used by the panel to render the control's state.
-- @param value number
-- @return boolean
function M.is_category_opted_in(value)
  return extra_conserved[value] == true
end

--- Is this value one of the three defaults, which cannot be switched off?
-- @param value number
-- @return boolean
function M.is_category_default(value)
  return M.SAFE_CATEGORY_VALUES[value] ~= nil
end

--- Add or remove a category value from the conserved set.
--
-- The defaults cannot be switched off from here. Turning Shell off would make
-- Infinite Ammo's item-side counterpart silently stop working for the items it
-- was built for, which is the "switch that does nothing" failure this project
-- is arranged against. Opting a category IN is additive only.
--
-- @param value number
-- @param on boolean
-- @return boolean accepted
function M.set_category_conserved(value, on)
  if type(value) ~= "number" then
    return false
  end
  if M.SAFE_CATEGORY_VALUES[value] ~= nil then
    return false
  end

  if on == true then
    extra_conserved[value] = true
  else
    extra_conserved[value] = nil
  end
  return true
end

--- The carried items, as a plain Lua array of app.Inventory.ItemInfo.
--
-- Two accessors are tried, because the first one returned nothing in game even
-- though the destroyItem hook was demonstrably receiving real items: so items
-- existed and were reachable, but get_ItemList() was not the way to enumerate
-- them. _ItemList is the backing field the same method reads from.
--
-- @return table array (possibly empty)
-- @return string which route produced the result, for diagnostics
function M.item_infos()
  local inventory = M.inventory()
  if inventory == nil then
    return {}, "no inventory"
  end

  local type_helpers = require("re7trainer.utils.type_helpers")

  -- Route A: the public accessor.
  local via_method, how_method = type_helpers.to_managed_list(objects.call(inventory, "get_ItemList"))
  if #via_method > 0 then
    return via_method, "get_ItemList() [" .. how_method .. "]"
  end

  -- Route B: the backing field.
  local via_field, how_field = type_helpers.to_managed_list(objects.get(inventory, "_ItemList"))
  if #via_field > 0 then
    return via_field, "_ItemList field [" .. how_field .. "]"
  end

  -- Neither produced anything. Report what each accessor actually returned and
  -- how it was interpreted -- "returned a list of size 0" and "returned
  -- something we could not read" are different problems.
  return {}, string.format("get_ItemList: %s | _ItemList: %s", how_method, how_field)
end

--- The category of an app.Item, or nil.
--
-- Returns TWO values: a display name (which may be nil) and the raw observed
-- shape. The numeric value is the authoritative one -- see is_safe_to_conserve,
-- which does not depend on the name at all.
--
-- In game the field arrives as a NUMBER (1, 2, 3, 4, 7, ...), not a string.
-- The first version demanded a string and therefore reported every item as
-- "category unreadable", which correctly refused everything and made the cheat
-- do nothing. An enum does not necessarily marshal as a name; here it does not.
--
-- @param item userdata app.Item
-- @return string|nil category_name
-- @return string observation, for logging
-- @return number|nil raw numeric value
function M.item_category(item)
  if item == nil then
    return nil, "no item", nil
  end

  local item_data = objects.call(item, "get_ItemData")
  if item_data == nil then
    item_data = objects.get(item, "_ItemData")
  end
  if item_data == nil then
    return nil, "app.ItemData unreachable", nil
  end

  local raw = objects.get(item_data, "Category")
  if raw == nil then
    return nil, "Category field unreadable", nil
  end

  -- The case that actually occurs: a numeric enum value.
  local as_number = safe.to_number(raw)
  if as_number ~= nil then
    local name = M.SAFE_CATEGORY_VALUES[as_number]
    return name, "numeric value " .. tostring(as_number), as_number
  end

  -- A string, if some build surfaces it that way.
  if type(raw) == "string" then
    return raw, "string", nil
  end

  -- A boxed value with a name accessor.
  local name = safe.try(raw, "get_name") or safe.try(raw, "ToString")
  if type(name) == "string" then
    return name, "boxed", nil
  end

  return nil, "unrecognised shape: " .. type(raw), nil
end

--- Is this item safe for the trainer to conserve?
--
-- Two independent gates, in order of confidence:
--
--   1. The engine's category value. This is the precise answer and is preferred
--      whenever it can be read -- as a number OR a name, since different builds
--      may surface either.
--
--   2. Stackability, as a fallback. An item whose MaxStackNum is greater than 1
--      is by definition a stackable consumable; a key item does not stack. Not
--      a guess about item names -- a different engine-provided fact that happens
--      to divide the same way.
--
-- Fails CLOSED: if neither gate can be evaluated, the item is not safe.
--
-- @param item userdata app.Item
-- @return boolean safe, string reason
function M.is_safe_to_conserve(item)
  if item == nil then
    return false, "no item"
  end

  local category, observation, numeric = M.item_category(item)

  -- Gate 1a: numeric category. Authoritative when available.
  if numeric ~= nil then
    local name = M.SAFE_CATEGORY_VALUES[numeric]
    if name ~= nil then
      return true, name .. " (value " .. tostring(numeric) .. ")"
    end
    if M.is_category_opted_in(numeric) then
      -- Chosen by the player from the panel, after seeing which items are in
      -- it. Recorded as such so the debug panel says WHY an item is conserved
      -- rather than implying the default set covers it.
      return true, "category value " .. tostring(numeric) .. " (opted in)"
    end
    return false, "category value " .. tostring(numeric) .. " is not conservable"
  end

  -- Gate 1b: named category.
  if category ~= nil then
    if M.SAFE_CATEGORIES[category] then
      return true, category
    end
    return false, "category '" .. category .. "' is not conservable"
  end

  -- Gate 2: category unreadable. Fall back to stackability.
  local max_stack = safe.to_number(objects.call(item, "getMaxStackNum"))
  if max_stack == nil then
    local item_data = objects.call(item, "get_ItemData") or objects.get(item, "_ItemData")
    if item_data ~= nil then
      max_stack = safe.to_number(objects.get(item_data, "MaxStackNum"))
    end
  end

  if max_stack == nil then
    return false, "category unreadable (" .. observation .. ") and stack size unknown"
  end

  if max_stack > 1 then
    return true, "stackable (max " .. tostring(max_stack) .. "); category unreadable: " .. observation
  end

  return false, "does not stack (max " .. tostring(max_stack) .. ") -- treating as a key item"
end

--- Every item category currently present in the inventory, for the panel.
--
-- This is what makes opting a category in possible without guessing: it
-- reports the values actually in front of the player, alongside one of the
-- items each came from, so a value is chosen with its contents visible.
--
-- Only NUMERIC categories are reported. A build that surfaces the enum as a
-- string is already covered by SAFE_CATEGORIES, and there is nothing useful to
-- opt into for a category that reads as a name.
--
-- @return table array of { value = number, count = number, sample = string|nil }
function M.observed_categories()
  local counts, samples, order = {}, {}, {}

  for _, info in ipairs(M.item_infos()) do
    local item = objects.get(info, "Item")
    if item ~= nil then
      local _, _, numeric = M.item_category(item)
      if numeric ~= nil then
        if counts[numeric] == nil then
          counts[numeric] = 0
          order[#order + 1] = numeric
        end
        counts[numeric] = counts[numeric] + 1

        if samples[numeric] == nil then
          local id = objects.get(item, "ItemDataID")
          if type(id) == "string" then
            samples[numeric] = id
          end
        end
      end
    end
  end

  table.sort(order)

  local out = {}
  for _, value in ipairs(order) do
    out[#out + 1] = {
      value = value,
      count = counts[value],
      sample = samples[value],
    }
  end
  return out
end

--- How many items are currently classified as safe to conserve.
-- Surfaced in the UI so the state is visible rather than implied.
-- @return number safe, number total
function M.count_safe_items()
  local safe_count, total = 0, 0

  for _, info in ipairs(M.item_infos()) do
    local item = objects.get(info, "Item")
    if item ~= nil then
      total = total + 1
      if M.is_safe_to_conserve(item) then
        safe_count = safe_count + 1
      end
    end
  end

  return safe_count, total
end

-- ---------------------------------------------------------------------------
-- Weapons
-- ---------------------------------------------------------------------------

--- The currently equipped gun: the app.WeaponGun object, not the controller.
--
-- THE HOP THAT WAS MISSING
-- ------------------------
-- app.PlayerStatus.PlayerGun is an app.PlayerGun, and app.PlayerGun is a
-- CONTROLLER -- it derives from app.PlayerBase and carries 230 methods of
-- aiming, reloading and firing state. It is not the gun.
--
-- It holds the actual weapon in a field:
--
--     app.PlayerGun
--       F app.WeaponGun WeaponGun
--
-- app.PlayerGun does expose get_loadNum(), which is why the magazine read
-- worked while everything nested on the real gun did not: that accessor is a
-- passthrough to a weapon this function was never reaching. WeaponGunParameter
-- and CurrentBulletInfo live on app.WeaponGun, so they were unreachable by
-- construction.
--
-- Falls back to the controller itself when the weapon field is empty, so a
-- partially-initialised state still yields something readable.
--
-- @return userdata|nil app.WeaponGun
function M.equipped_gun()
  local status = M.player_status()
  if status == nil then
    return nil
  end

  local controller = objects.get(status, "PlayerGun")
  if controller == nil or not objects.is_valid(controller) then
    return nil
  end

  -- The real weapon.
  local weapon = objects.call(controller, "get_WeaponGun")
  if weapon == nil then
    weapon = objects.get(controller, "WeaponGun")
  end

  if weapon ~= nil and objects.is_valid(weapon) then
    return weapon
  end

  -- Some states (unarmed, mid-swap) have no weapon object. The controller can
  -- still report a magazine count, so return it rather than reporting nothing.
  return controller
end

--- Magazine and reserve counts for a gun, or nil.
-- @param gun userdata|nil defaults to the equipped gun
-- @return table|nil { magazine = number, magazine_max = number, reserve = number }
function M.gun_ammo(gun)
  gun = gun or M.equipped_gun()
  if gun == nil then
    return nil
  end

  local magazine = safe.to_number(objects.call(gun, "get_loadNum"))
  if magazine == nil then
    return nil
  end

  return {
    magazine = magazine,
    magazine_max = safe.to_number(objects.call(gun, "get_maxLoadNum")),
    reserve = safe.to_number(objects.call(gun, "get_bulletStackNum")),
  }
end

--- The gun's current bullet record -- where the magazine count actually lives.
--
-- app.WeaponGun.get_loadNum() reads a value derived from this, which is why
-- calling the gun's own set_loadNum had no effect in game: the game recomputes
-- it from CurrentBulletInfo on the next update.
--
-- @param gun userdata|nil
-- @return userdata|nil app.WeaponGun.BulletInfo
function M.current_bullet_info(gun)
  gun = gun or M.equipped_gun()
  if gun == nil then
    return nil
  end

  local info = objects.call(gun, "get_CurrentBulletInfo")
  if info == nil then
    info = objects.get(gun, "CurrentBulletInfo")
  end

  if info == nil or not objects.is_valid(info) then
    return nil
  end
  return info
end

--- The gun's parameter block, which carries the game's own infinity flags.
-- @param gun userdata|nil
-- @return userdata|nil app.WeaponGunParameter
function M.gun_parameter(gun)
  gun = gun or M.equipped_gun()
  if gun == nil then
    return nil
  end

  local param = objects.call(gun, "get_WeaponGunParameter")
  if param == nil then
    param = objects.get(gun, "WeaponGunParameter")
  end

  if param == nil or not objects.is_valid(param) then
    return nil
  end
  return param
end

--- Turn the game's own unlimited-magazine flag on or off.
--
-- app.WeaponGunParameter carries `IsLoadNumInfinity` and
-- `IsBulletStackNumInfinity` as plain writable booleans, and app.WeaponGun
-- already exposes get_isLoadNumInfinity() over them. So RE7 has a built-in
-- infinite-ammo concept, and this uses it rather than fighting the counter.
--
-- This is the preferred mechanism and is strictly better than restoring a
-- number every frame: the value is never wrong, not even for one frame, and no
-- write happens per shot.
--
-- Prefers a setter if one exists, falls back to the field.
--
-- @param on boolean
-- @param gun userdata|nil
-- @return boolean ok, string detail
function M.set_infinite_magazine(on, gun)
  local param = M.gun_parameter(gun)
  if param == nil then
    return false, "WeaponGunParameter unreachable"
  end

  local wanted = on == true

  -- Setter first, if the type provides one.
  if safe.call_method(param, "set_IsLoadNumInfinity", wanted) then
    local check = objects.get(param, "IsLoadNumInfinity")
    if check == wanted then
      return true, "set_IsLoadNumInfinity"
    end
  end

  if objects.set(param, "IsLoadNumInfinity", wanted) then
    local check = objects.get(param, "IsLoadNumInfinity")
    if check == wanted then
      return true, "IsLoadNumInfinity field"
    end
    return false, "field write had no effect (reads back " .. tostring(check) .. ")"
  end

  return false, "could not write IsLoadNumInfinity"
end

--- Write a gun's magazine count, and VERIFY the write took.
--
-- Writes CurrentBulletInfo.LoadNum, NOT the gun's own set_loadNum. In game,
-- gun:set_loadNum(4) was accepted and left the count at 3 -- the gun derives
-- its loadNum from CurrentBulletInfo, so writing the derived value is
-- overwritten immediately.
--
-- @param value number
-- @param gun userdata|nil defaults to the equipped gun
-- @return boolean ok, string detail
function M.set_magazine(value, gun)
  gun = gun or M.equipped_gun()
  if gun == nil then
    return false, "no gun"
  end

  local bullet_info = M.current_bullet_info(gun)
  if bullet_info == nil then
    return false, "CurrentBulletInfo unreachable"
  end

  --- Confirm by re-reading the gun's own accessor, which is what the HUD uses.
  local function verify(route)
    local after = safe.to_number(objects.call(gun, "get_loadNum"))
    if after == nil then
      return false, route .. ": unreadable after write"
    end
    if math.abs(after - value) < 0.5 then
      return true, route
    end
    return false, string.format("%s: no effect (now %.0f, wanted %.0f)", route, after, value)
  end

  if safe.call_method(bullet_info, "set_loadNum", value) then
    local ok, detail = verify("BulletInfo.set_loadNum")
    if ok then
      return true, detail
    end
  end

  if objects.set(bullet_info, "LoadNum", value) then
    local ok, detail = verify("BulletInfo.LoadNum field")
    if ok then
      return true, detail
    end
  end

  return false, "no route to the magazine had any effect"
end

--- Write an item's stack count.
-- @param item userdata app.Item
-- @param value number
-- @return boolean ok
function M.set_item_stack(item, value)
  if item == nil then
    return false
  end

  local ok, result = safe.call_method(item, "setStackNum", value)
  if ok and result ~= nil then
    return true
  end

  return objects.set(item, "ItemStackNum", value)
end

--- An item's current stack count, or nil.
-- @param item userdata app.Item
-- @return number|nil
function M.item_stack(item)
  if item == nil then
    return nil
  end

  local value = safe.to_number(objects.call(item, "getStackNum"))
  if value ~= nil then
    return value
  end
  return safe.to_number(objects.get(item, "ItemStackNum"))
end

--- Does this text look like an RE Engine item identifier?
--
-- THE BUG THIS REPLACES
-- ---------------------
-- The first version tested for things a sol2 pointer *might* render as --
-- text containing "userdata", or text starting with "0x" -- rather than for
-- what an identifier actually looks like. Neither guess was what this build
-- produces, which is:
--
--     sol.REManagedObject*: 000000010BB92698
--
-- That passed the check, was returned as the item id, and -- because
-- read_managed_string returns on the first route that succeeds -- the
-- ToString routes underneath were never reached even once. In game every
-- call reported:
--
--     reduceItem args: sol.REManagedObject*: 000000010BB92698 (not in inventory)
--
-- and passed through. Nothing was ever blocked, and no route that could have
-- worked was ever tried.
--
-- So the test is now POSITIVE. Item ids in this game are short ASCII
-- identifiers -- ChemicalM, RemedyM, AntiqueCoin, HandgunBullet -- and
-- anything that is not that shape is rejected. A negative test against one
-- build's pointer formatting is a guess that fails silently; this one fails
-- visibly, by leaving the later routes to run.
--
-- @param text any
-- @return boolean
local function looks_like_item_id(text)
  if type(text) ~= "string" then
    return false
  end
  if #text == 0 or #text > 96 then
    return false
  end
  -- A hex address literal. This is how a pointer is rendered in some builds,
  -- and it is pure alphanumerics, so the identifier rule below would accept
  -- it. No item id in this game has that shape, and accepting one puts us
  -- straight back into the failure this function exists to prevent.
  if text:match("^0x%x+$") ~= nil then
    return false
  end
  return text:match("^%w[%w_]*$") ~= nil
end

M.looks_like_item_id = looks_like_item_id

--- Read a managed System.String as a Lua string, or nil.
--
-- A hook parameter arriving as a managed string is not a Lua string -- it is a
-- pointer to a managed object. REFramework may or may not surface its text
-- through any given accessor, and which one works cannot be reasoned out
-- offline, so every plausible route is tried in turn and the caller is told
-- which one succeeded.
--
-- This matters because app.Inventory.reduceItem receives the item id as
-- System.String in args[3]; without being able to read it, that call cannot be
-- gated on which item is being consumed.
--
-- EVERY route's result is collected, not just the first failure. "Could not be
-- rendered" was previously reported with no indication of what each route
-- actually returned, which made the one question that mattered -- did the
-- pointer arrive, and what came out of it -- unanswerable from the panel.
--
-- @param value any
-- @return string|nil
-- @return string how it was read, or every route tried and what it yielded
function M.read_managed_string(value)
  if value == nil then
    return nil, "nil"
  end

  if type(value) == "string" then
    if looks_like_item_id(value) then
      return value, "already a Lua string"
    end
    return nil, "a Lua string, but not an identifier shape: '" .. value .. "'"
  end

  local object = safe.to_managed_object(value)
  if object == nil then
    return nil, "not a managed object (" .. type(value) .. ")"
  end

  local type_name = objects.type_name(object)
  local tried = {}

  --- Accept a candidate, or record what it actually was and move on.
  local function take(route, candidate)
    if looks_like_item_id(candidate) then
      return candidate, route
    end
    tried[#tried + 1] = string.format("%s=%s", route, tostring(candidate))
    return nil
  end

  -- Route 1: tostring. In this build this renders the sol2 pointer, not the
  -- text -- which is the trap described above. Recorded, not trusted.
  local ok, text = take("tostring", tostring(object))
  if ok ~= nil then
    return ok, text
  end

  -- Route 2: ToString(), which for System.String returns itself.
  local via_call = objects.call(object, "ToString")
  if via_call ~= nil then
    ok, text = take("ToString", tostring(via_call))
    if ok ~= nil then
      return ok, text
    end
  else
    tried[#tried + 1] = "ToString=nil"
  end

  return nil, string.format("no route yielded an identifier (object is %s): %s",
                            tostring(type_name), table.concat(tried, " | "))
end

--- Find a carried item by its data ID.
--
-- Turns an item id arriving as a hook parameter into a real app.Item, so its
-- category can be checked before anything is decided.
--
-- BOTH SIDES ARE NORMALISED. The id read off an app.Item and the id arriving
-- as a hook argument can be represented differently -- one may be a Lua string
-- while the other is a managed object -- and comparing those directly is never
-- equal. Each is pushed through read_managed_string so the comparison happens
-- in one representation.
--
-- @param item_data_id string
-- @return userdata|nil app.Item
function M.find_item_by_id(item_data_id)
  if type(item_data_id) ~= "string" or item_data_id == "" then
    return nil
  end

  local infos = M.item_infos()
  for _, info in ipairs(infos) do
    local item = objects.get(info, "Item")
    if item ~= nil then
      local id = objects.get(item, "ItemDataID")

      if type(id) == "string" then
        if id == item_data_id then
          return item
        end
      elseif id ~= nil then
        local text = M.read_managed_string(id)
        if text == item_data_id then
          return item
        end
      end
    end
  end

  return nil
end

--- Resolve a hook argument into a real carried app.Item, or nil.
--
-- WHY THIS EXISTS
-- ---------------
-- reduceItem's three parameters have never been identified individually. The
-- earlier version assumed args[3] was the item id and read it as a string --
-- an assumption that turned out to be load-bearing and wrong in effect, since
-- the read silently produced a pointer rendering and every call passed
-- through. Rather than assume a shape for the other two, each argument is
-- offered here and resolved by what it actually IS.
--
-- Two shapes are tried, in order of safety:
--
--   1. An item id (a managed System.String naming a carried item).
--   2. The app.Item object itself, classified directly -- no string decoding
--      involved at all.
--
-- The object path demands an exact type-name match. A pointer that happened to
-- look object-like and got blocked could consume a key item or desync the
-- inventory, so anything not positively identified as app.Item is refused.
--
-- Fails closed: an unresolvable argument returns nil and the caller passes the
-- call through.
--
-- @param value any  a raw hook argument
-- @return userdata|nil app.Item
-- @return string how it was resolved, or why it was not
function M.resolve_hook_arg(value)
  -- Path 1: the argument names a carried item.
  local id, how = M.read_managed_string(value)
  if id ~= nil then
    local item = M.find_item_by_id(id)
    if item ~= nil then
      return item, string.format("id '%s' via %s", id, how)
    end
    return nil, string.format("id '%s' (%s) is not a carried item", id, how)
  end

  -- Path 2: the argument IS the item.
  --
  -- Only userdata/table values are considered. A primitive cannot be an
  -- app.Item, and feeding a raw integer to to_managed_object would reinterpret
  -- a count as a pointer -- which is exactly the kind of guess that turns a
  -- trainer into a crash.
  local kind = type(value)
  if kind ~= "userdata" and kind ~= "table" then
    return nil, string.format("%s: %s", kind, tostring(how))
  end

  local object = safe.to_managed_object(value)
  if object == nil or not objects.is_valid(object) then
    return nil, string.format("not a live object; %s", tostring(how))
  end

  local type_name = objects.type_name(object)
  if type_name == "app.Item" then
    return object, "the app.Item itself"
  end

  return nil, string.format("not an app.Item (%s); %s", tostring(type_name), tostring(how))
end

return M
