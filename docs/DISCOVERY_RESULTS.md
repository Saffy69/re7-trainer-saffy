# Discovery Results — RE7's actual APIs

Everything in this document was read out of the **running game**, via the trainer's own discovery
dump taken in gameplay on build `22773795` (TDB v70). Nothing here is inferred from names, and
nothing is copied from a forum.

Source of truth: `reframework/data/re7trainer_discovery.json`.

---

## How to read this

Every name below arrived as a member of a live type in the RE Engine type database. The dump
reported `83/86` candidate types with populated member lists.

Two things the dump does **not** give, and which must not be assumed:

- **Full parameter lists.** Methods show as `name(? (N params))` — the arity is real, the parameter
  types are not captured. For hooking, only methods with 0 params can be used without further work.
- **Which method is called in which situation.** The names are strong evidence, not proof. Each
  cheat below names what still has to be confirmed by observing the game.

---

## Entry point: reaching the player

There is no `sdk.get_local_player()` in this build — confirmed absent. The two verified routes are:

```lua
-- Route A: static method, no singleton lookup at all.
local inventory = app.Inventory.getActivePlayerInventory()

-- Route B: the managed singleton (confirmed live: constructed = true).
local inv_manager = sdk.get_managed_singleton("app.InventoryManager")
local inventory   = inv_manager._Inventory
```

Route B also gives `app.InventoryManager._PlayerObj` (a `via.GameObject`).

From `app.Inventory`:

```lua
local player_status = inventory.PlayerStatus   -- typed app.IPlayerStatus
```

`app.PlayerStatus` is the hub. Its fields reach every subsystem:

```
app.PlayerStatus
  app.PlayerDamageController PlayerDamageController
  app.PlayerGun               PlayerGun
  app.Inventory               Inventory
  app.EquipManager            EquipManager
  app.PlayerWeaponChange      PlayerWeaponChange
  app.PlayerItem              PlayerItem
```

It derives from `app.CharacterCommonStatus`, which is where the health accessors live.

**Still to confirm:** that `.PlayerStatus` on a live `app.Inventory` is non-nil outside menus. It is a
field read, so it is nil-safe to check.

---

## Health

The health values live on **`app.CharacterCommonStatus`**, inherited by `app.PlayerStatus`:

```
M System.Single  get_health()             -- current
M System.Single  get_maxHealth()
M System.Single  get_normalizedHealth()
M System.Boolean get_IsDead()
M System.Boolean get_isHealthZero()
M System.Boolean get_isForbidDamageReaction()
M System.Void    set_isForbidDamageReaction(System.Boolean)   <-- WRITABLE
F System.Boolean <isForbidDamageReaction>k__BackingField
```

`set_isForbidDamageReaction(true)` is the least invasive possible health cheat: it flips a flag the
game itself consults before running damage reactions. No hook, no memory write, and it is a real
game API — the field name `k__BackingField` confirms it is a property with a setter.

**It is not yet proven that this flag alone prevents health loss.** "Forbid damage *reaction*" may
govern only the animation/stagger response while the health value still drops. This must be tested:
enable it, take a hit, read `get_health()`.

The damage path, if a hook is needed instead:

```
app.PlayerDamageController
  M System.Void    doDamage(? (1 params))     -- the damage application, 1 arg
  M System.Void    doDie(? (1 params))
  M System.Single  calcDamage(? (1 params))
  M System.Single  calcDamageValue(? (1 params))
  M System.Boolean isEnableDieByDamageInfo(? (1 params))
  M System.Boolean get_isEnableDamage()
  F System.Action`1<app.Collision.HitController.DamageInfo> DamageHandler
  F app.PlayerMaxHealthTable PlayerMaxHealthTable
  F System.Single DyingHealth
  F System.Single LatestDamage
```

`doDamage` takes one parameter, so a hook that skips the original needs no parameter handling —
`sdk.hook(method, function() return sdk.PreHookResult.SKIP_ORIGINAL end, nil)` is sufficient.

A plain health record also exists with a writable setter, useful for the preserve/restore fallback:

```
app.HealthInfo
  F System.Single Health
  F System.Single MaxHealth
  M System.Single get_health()  /  get_maxHealth()  /  get_normalizedHealth()
  M System.Void   set_health(System.Single)   <-- WRITABLE
  M System.Void   set_maxHealth(System.Single)
```

The maximum is table-driven, as the type name suggested:

```
app.PlayerMaxHealthTable
  F List<System.Single> MaxHealthList
  F System.Single DefaultMaxHealth
  M System.Single getMaxHealth(? (1 params))
```

`app.fsm.HealthSet` is a state-machine node with `Health`, `MaxHealth`, `Recovery`, `RecoveryAll`
fields — a write point if a hook is preferable to a field write.

---

## Ammunition

The gun is reached from the inventory item list, or from `app.PlayerStatus.PlayerGun`:

```
app.Inventory.ItemInfo
  F app.Item      Item
  F app.WeaponGun Gun        <-- the gun, straight off the item entry
  F via.GameObject Owner
```

`app.WeaponGun` — 68 methods, and this is the important part:

```
M System.Int32  get_loadNum()             -- magazine (rounds in the gun)
M System.Void   set_loadNum(System.Int32) -- WRITABLE
M System.Int32  get_maxLoadNum()
M System.Int32  get_bulletStackNum()      -- reserve
M System.Boolean expendBullet()           -- <-- CONSUMPTION. 0 params.
M System.Boolean get_isMagazineEmpty()
M System.Boolean get_isMagazineFull()
M System.Boolean get_isLoadNumInfinity()
M System.Boolean get_isBulletStackNumInfinity()
M System.Void   shoot(? (3 params))
M System.Void   reload(? (1 params))  /  reload(? (2 params))
```

**`expendBullet()` with zero parameters is the ideal hook point** — the trainer's preferred strategy
of preventing consumption rather than rewriting a value. Skipping it means the magazine count is
never decremented by the game at all, so nothing ever reads a wrong value.

The two `get_is*Infinity()` accessors are a notable find: the game already has an infinity concept
for both magazine and reserve. They are read-only in the dump, so they cannot simply be set — but
whatever drives them is worth looking at if hooking proves impractical.

Note also, on `app.Inventory`:

```
M System.Boolean hasUnlimitedAmmo()
M System.Boolean get_isBulletStackNumInfinity()
```

**Still to confirm:** that `expendBullet()` is on the firing path (as opposed to reload or
housekeeping). Test by hooking it and firing.

---

## Items

`app.Item` — 52 methods, and the quantity API is complete:

```
F System.Int32  ItemStackNum
M System.Int32  getStackNum()             -- READ
M System.Void   setStackNum(System.Int32) -- WRITE
M System.Int32  getMaxStackNum()
M System.Boolean isMaxStack()
M System.Boolean reduceNum(? (2 params))  -- <-- CONSUMPTION
M System.Boolean useItem(? (1 params))
M System.Boolean isCanUse()
F app.ItemData  _ItemData
M app.ItemData  get_ItemData()
M app.WeaponGun get_WeaponGun()
M app.Weapon    get_weapon()
```

### The classification problem is solved

The hard precondition for Infinite Items — telling a stackable consumable from a key item — is fully
satisfiable. `app.ItemData` carries the category:

```
app.ItemData
  F app.Item.ItemCategoryType Category
  F System.Int32 MaxStackNum
  F app.ItemSortCategory SortCategory
```

And the enum is complete:

```
app.Item.ItemCategoryType
  DiscardableKeyItem   Drug      File        KeyItem     Map
  Material             Max       OtherItem   Shell       StackWeapon
  SupplyBox            UsableKeyItem        Weapon
```

So the safe set is explicit:

| Category | Meaning | Conserve? |
|---|---|---|
| `Drug` | herbs, first aid | **yes** |
| `Material` | chem fluids, crafting | **yes** |
| `Shell` | ammunition | **yes** |
| `KeyItem` | keys, puzzle items | **never** |
| `UsableKeyItem` | usable puzzle items | **never** |
| `DiscardableKeyItem` | discardable key items | **never** |
| `Weapon` / `StackWeapon` | weapons | **never** |
| `File` / `Map` | documents | **never** |
| `SupplyBox` / `OtherItem` | misc | **no** — not proven stackable |

Everything not in the three "yes" rows is treated as untouchable. That is the conservative
direction, and it is the direction that keeps a save file intact.

### The inventory container

```
app.Inventory                                   (83m / 16f)
  F List<app.Inventory.ItemInfo> _ItemList      -- the carried items
  M List<app.Inventory.ItemInfo> get_ItemList()
  M System.Int32  getTotalStackNum(? (2 params))
  M System.Int32  getTotalStackNumIncludeItemBox(? (2 params))
  M System.Int32  getInventoryItemNum(? (1 params))
  M System.Boolean hasItem(? (2 params))
  M System.Boolean reduceItem(? (3 params))     -- inventory-level consumption
  M System.Boolean interimItemUse(? (1 params)) / (? (2 params))
  M app.Inventory.AddItemResult addItem(2/3/4 params)
  M static app.Inventory getActivePlayerInventory()
```

`getTotalStackNum(itemId, ?)` is the cleanest read for a per-item count, and is a useful cross-check
against the `app.Item` entry.

---

## What is confirmed vs what still needs a test

**Confirmed present and reachable** (from a live dump, not from names):
all types and members listed above.

**Confirmed live at runtime:** `app.InventoryManager`, `app.InventorySystem`, `app.ItemManager`,
`app.ItemResourceManager`, `app.AdditionalItemManager`, `app.Collision.DamageManager`,
`app.GameManager`, `app.GameFlowFsmManager`, `app.MenuManager`, `app.OptionManager`,
`app.SaveDataManager`, `app.CharacterExistManager`, `app.ObjectManager`, `app.NowLoadingMovieManager`.

**Not constructed during the dump** (normal — they belong to modes not active at the time):
`app.CraftItemManager`, `app.AAASceneTransitionController`, `app.PlayerJunkPartsManager`.

**Still to establish by testing in-game:**

1. That `inventory.PlayerStatus` is non-nil during ordinary gameplay.
2. That `set_isForbidDamageReaction(true)` actually prevents health loss, rather than only
   suppressing the reaction animation. Read `get_health()` before and after a hit.
3. That `expendBullet()` is on the firing path.
4. That `reduceNum()` / `useItem()` are the paths taken when consuming a herb.
5. That `app.ItemData.Category` returns the values the enum implies for a herb and for a key item.

Each of these is a single observation, and each one is the difference between a cheat that works and
a cheat that silently does nothing. They are listed here rather than assumed away.
