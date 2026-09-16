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

--- Write the player's health directly.
--
-- app.HealthInfo carries a plain writable `Health` float and a set_health(float)
-- accessor, both confirmed present in the discovery dump. This exists because
-- hooking the damage path proved unreliable in practice, while reading and
-- writing the value does not.
--
-- @param value number
-- @return boolean ok
function M.set_health(value)
  local info = M.health_info()
  if info == nil then
    return false
  end

  local ok, result = safe.call_method(info, "set_health", value)
  if ok and result ~= nil then
    return true
  end

  -- Fall back to writing the field directly.
  return objects.set(info, "Health", value)
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

--- Item categories the trainer is allowed to conserve.
--
-- This is the list that makes Infinite Items safe. Everything NOT in this set
-- is treated as untouchable, which is the conservative direction and the one
-- that cannot corrupt a save.
--
--   Drug      herbs, first aid -- stackable, consumed
--   Material  chem fluids, crafting -- stackable, consumed
--   Shell     ammunition -- stackable, consumed
--
-- Deliberately absent, and therefore never touched:
--   KeyItem, UsableKeyItem, DiscardableKeyItem  -- key items gate puzzles;
--       duplicating one can make a run unrecoverable
--   Weapon, StackWeapon                          -- not consumables
--   File, Map                                    -- documents
--   SupplyBox, OtherItem                         -- not proven stackable
--
-- The enum members were read out of app.Item.ItemCategoryType in a live dump.
M.SAFE_CATEGORIES = {
  Drug = true,
  Material = true,
  Shell = true,
}

--- The carried items, as a plain Lua array of app.Inventory.ItemInfo.
-- @return table array (possibly empty)
function M.item_infos()
  local inventory = M.inventory()
  if inventory == nil then
    return {}
  end

  local raw = objects.call(inventory, "get_ItemList")
  return require("re7trainer.utils.type_helpers").to_array(raw)
end

--- The category of an app.Item, as a name, or nil.
--
-- WHY THIS IS SO DEFENSIVE
-- ------------------------
-- The first version read app.ItemData.Category and expected a string. In game
-- it came back unreadable, and the hook logged "pass (category unreadable)" --
-- so the gate refused everything, correctly, and the cheat did nothing.
--
-- A .NET enum field does not necessarily surface as a Lua string. It may arrive
-- as a number, as a userdata, or as a boxed value object, and which one it is
-- cannot be determined without observing it. Rather than guess a third time,
-- every plausible shape is attempted and the result is reported honestly.
--
-- @param item userdata app.Item
-- @return string|nil category_name
-- @return string a short description of what was actually observed, for logging
function M.item_category(item)
  if item == nil then
    return nil, "no item"
  end

  local item_data = objects.call(item, "get_ItemData")
  if item_data == nil then
    item_data = objects.get(item, "_ItemData")
  end
  if item_data == nil then
    return nil, "app.ItemData unreachable"
  end

  local raw = objects.get(item_data, "Category")
  if raw == nil then
    return nil, "Category field unreadable"
  end

  -- Shape 1: already a string.
  if type(raw) == "string" then
    return raw, "string"
  end

  -- Shape 2: a number. Named lookup is impossible without the enum's member
  -- values, so the caller falls back to the stack-size test below.
  local as_number = safe.to_number(raw)
  if as_number ~= nil then
    return nil, "numeric enum value " .. tostring(as_number)
  end

  -- Shape 3: a boxed value with a name accessor.
  local name = safe.try(raw, "get_name") or safe.try(raw, "ToString")
  if type(name) == "string" then
    return name, "boxed"
  end

  return nil, "unrecognised shape: " .. type(raw)
end

--- Is this item safe for the trainer to conserve?
--
-- Two independent gates, in order of confidence:
--
--   1. The engine's own category enum, when it can be read as a name. This is
--      the precise answer and is preferred whenever available.
--
--   2. Stackability, as a fallback. An item whose MaxStackNum is greater than 1
--      is by definition a stackable consumable; a key item does not stack. This
--      is not a guess about item names -- it is a different engine-provided fact
--      that happens to divide the same way, and it is why the cheat can still
--      be gated honestly when the enum cannot be read.
--
-- Fails CLOSED: if neither gate can be evaluated, the item is not safe.
--
-- @param item userdata app.Item
-- @return boolean safe, string reason
function M.is_safe_to_conserve(item)
  if item == nil then
    return false, "no item"
  end

  local category, observation = M.item_category(item)

  if category ~= nil then
    if M.SAFE_CATEGORIES[category] then
      return true, category
    end
    return false, "category '" .. category .. "' is not conservable"
  end

  -- Category unreadable. Fall back to stackability.
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

--- The currently equipped gun, or nil.
--
-- Reached from app.PlayerStatus.PlayerGun. The inventory item list also carries
-- a Gun reference per item (app.Inventory.ItemInfo.Gun), which is the better
-- route if this one returns nil — an equipped-weapon field can legitimately be
-- empty while the player is unarmed.
-- @return userdata|nil app.WeaponGun
function M.equipped_gun()
  local status = M.player_status()
  if status == nil then
    return nil
  end

  local gun = objects.get(status, "PlayerGun")
  if gun ~= nil and objects.is_valid(gun) then
    return gun
  end

  return nil
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

--- Write a gun's magazine count.
--
-- set_loadNum is the method the game itself calls to change the magazine.
-- Confirmed in game: emptying a magazine and reloading produced six
-- set_loadNum calls. Note that expendBullet, which the first implementation
-- hooked, never fired at all -- it is not on the firing path in this build.
--
-- @param value number
-- @param gun userdata|nil defaults to the equipped gun
-- @return boolean ok
function M.set_magazine(value, gun)
  gun = gun or M.equipped_gun()
  if gun == nil then
    return false
  end

  local ok, result = safe.call_method(gun, "set_loadNum", value)
  return ok and result ~= nil
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

return M
