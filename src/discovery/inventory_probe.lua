--[[--------------------------------------------------------------------------
  re7trainer.discovery.inventory_probe — locate the inventory and item path.

  THE STRONGEST FINDING IN THE WHOLE PROJECT
  ------------------------------------------
  The user's type dump contains this line, verbatim:

      app.SingletonBehavior`1<app.InventoryManager>

  In RE Engine, a manager wrapped in SingletonBehavior`1 is a MANAGED SINGLETON.
  That is not a plausible-looking guess — it is the engine declaring that this
  type is a singleton, which means it is reachable at runtime by name:

      sdk.get_managed_singleton("app.InventoryManager")

  The same declaration exists for app.InventorySystem, app.ItemManager,
  app.ItemResourceManager, app.CraftItemManager and app.AdditionalItemManager.

  This probe therefore starts from singletons rather than from player objects,
  which is the opposite of the health and ammo probes — the evidence supports
  it here and does not there.

  WHAT WE STILL DO NOT KNOW
  -------------------------
  How an item is represented, how quantity is stored, and which operation
  consumes one. The singleton gives us a door; this probe finds out what is
  behind it. It does not open it.

  THE SAFETY CONSTRAINT THAT SHAPES THIS
  --------------------------------------
  The requirement is that using five herbs leaves five herbs — not 999999, and
  not a duplicated key item. That means we must be able to tell a stackable
  consumable from a quest item BEFORE we touch anything. If the type database
  does not expose that distinction, the correct outcome is a documented
  limitation, not a best-effort guess that duplicates a key item and breaks
  the save.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local types = require("re7trainer.utils.type_helpers")
local safe = require("re7trainer.utils.safe_call")
local objects = require("re7trainer.utils.object_helpers")

local M = {}

M.NAME = "inventory"

--- Singletons to interrogate. Every one of these appeared inside
--- SingletonBehavior`1<...> in the user's type dump.
M.SINGLETON_TARGETS = {
  "app.InventoryManager",
  "app.InventorySystem",
  "app.ItemManager",
  "app.ItemResourceManager",
  "app.CraftItemManager",
  "app.AdditionalItemManager",
}

--- Types to dump members for.
M.TARGETS = {
  -- The singletons themselves: their methods are the API surface we would use.
  "app.InventoryManager",
  "app.InventorySystem",
  "app.ItemManager",

  -- Containers and entries.
  "app.ItemBoxData",
  "app.InventoryItemBox",
  "app.InventoryItemBox.ItemNumType",
  "app.AddItem",
  "app.AddItemListData",

  -- The player's view of their items.
  "app.PlayerItem",
  "app.PlayerItemDesc",
}

--- Enum-ish types that might carry a stackable/consumable/key-item
--- classification. If one of these exposes a usable category, the trainer can
--- honour "never touch key items"; if none does, that limitation gets
--- documented rather than worked around.
M.CLASSIFICATION_TARGETS = {
  "app.PlayerWeaponChange.ItemType",
  "app.InventoryItemBox.ItemNumType",
  "app.ItemBoxData",
}

--- Run the probe.
-- @return table structured result, safe to serialise
function M.run()
  local report = {
    probe = M.NAME,
    singletons = {},
    targets = {},
    classification = {},
    notes = {},
  }

  -- Resolve each singleton for real. `constructed == false` with
  -- `type_exists == true` means "right type, but the game has not built it yet"
  -- which usually means we are still in a menu or a load.
  for _, name in ipairs(M.SINGLETON_TARGETS) do
    local instance = safe.singleton(name)
    local entry = {
      name = name,
      type_exists = types.exists(name),
      constructed = instance ~= nil,
      instance_type = nil,
    }
    if instance ~= nil then
      entry.instance_type = objects.type_name(instance)
    end
    report.singletons[#report.singletons + 1] = entry
  end

  for _, name in ipairs(M.TARGETS) do
    report.targets[#report.targets + 1] = types.dump_type(name)
  end

  for _, name in ipairs(M.CLASSIFICATION_TARGETS) do
    report.classification[#report.classification + 1] = types.dump_type(name)
  end

  report.notes[#report.notes + 1] =
    "app.InventoryManager is confirmed to be a managed singleton by the engine's own "
    .. "SingletonBehavior declaration. What is NOT yet known is how items and quantities "
    .. "are represented on it."

  report.notes[#report.notes + 1] =
    "Before enabling Infinite Items, confirm from the field/method lists that stackable "
    .. "consumables can be distinguished from key items. If they cannot, do not enable it."

  local constructed = 0
  for _, entry in ipairs(report.singletons) do
    if entry.constructed then
      constructed = constructed + 1
    end
  end

  logger.info("Inventory", string.format(
    "Probe complete: %d/%d inventory singletons constructed.",
    constructed, #M.SINGLETON_TARGETS))

  if constructed == 0 then
    logger.warn("Inventory", "No inventory singletons are constructed. This is normal on the "
                          .. "main menu — run the probe again from inside gameplay.")
  end

  return report
end

--- One-line status for the UI.
-- @return string
function M.status()
  return "app.InventoryManager confirmed as managed singleton"
end

return M
