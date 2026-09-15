# Discovery

How this trainer goes from "we know some type names" to "we know which function to hook".

Read this before running anything. It explains what is already established, what still has to come
from the running game, and exactly what to send back.

---

## The gap, stated plainly

There are two kinds of fact in this project, and they have completely different sources.

**Kind 1 — type names. Already known.**
Extracted from `re2_framework_log.txt`, which REFramework writes into the game folder on every
launch. At startup REFramework walks the game's type database and logs every type name. The log on
this machine produced **36,534 unique type names** at **TDB version 70**. These are real, they are
RE7's, and they are already mined — the results are in this document.

**Kind 2 — fields and methods. Not known, and not obtainable offline.**
The type dump contains type names and nothing else. No field names, no method names, no
signatures, no offsets. That information lives in the running game process and exists nowhere on
disk.

This is why the cheats are empty. Kind 1 tells us *where to look*. Only Kind 2 tells us *what to
call*.

**The discovery subsystem exists to convert Kind 2 into a file you can send back.**

---

## How the type list was extracted (so you can repeat it)

The framework writes `re2_framework_log.txt` next to `re7.exe`. It is large — around 4 MB — and
contains, among much else, one line per type:

```
[2026-09-15 13:06:11.995] [REFramework] [info] app.AI.Evaluator
[2026-09-15 13:06:11.995] [REFramework] [info] app.AI.AIEvaluator`1<app.AI.ThinkBase>
```

Extract them with:

```bash
LOG="$HOME/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard/re2_framework_log.txt"

grep -aE '\] \[REFramework\] \[info\] [A-Za-z_][A-Za-z0-9_.`<>,\[\] ]*$' "$LOG" \
  | sed 's/.*\[info\] //' \
  | sort -u > types_unique.txt

wc -l types_unique.txt     # 36534
```

### Confirming this list is genuinely RE7

Worth doing, because RE Framework's shared build serves several games. Test for markers unique to
each title:

```bash
grep -aic Molded types_unique.txt        # 222  -> RE7's enemies
grep -aic Ethan  types_unique.txt        # app.EthanGraveMarkerManager
grep -aic Lycan  types_unique.txt        # 0    -> not RE8
grep -aic Zombie types_unique.txt        # 0    -> not RE2
grep -aic Nemesis types_unique.txt       # 0    -> not RE3
```

**Beware false positives.** This bit us during discovery:

| grep | hits | what they actually are |
|---|---|---|
| `Baker` | 25 | `via.landscape.BakerManager`, `MapBaker`, `FoliageBaker` — **texture baking**, not Jack Baker |
| `Jack` | 87 | mostly unrelated substring matches |
| `Lab` | 494 | `Label` |
| `Ship` | 3 | `Relationship`, `Shipment` |

A substring match is **not** evidence. Always read the matched lines and confirm the match means
what you think it means.

---

## What is already established

### Managed singletons — 140 of them

In RE Engine, a manager wrapped in `SingletonBehavior\`1<...>` is a managed singleton, reachable at
runtime by name. This is the engine declaring it, not us guessing:

```bash
grep -aoE 'app\.SingletonBehavior`1<[^>]+>' types_unique.txt \
  | sed 's/app\.SingletonBehavior`1<//; s/>$//' | sort -u
```

The ones that matter here:

| Singleton | Why |
|---|---|
| `app.InventoryManager` | primary inventory container |
| `app.InventorySystem` | secondary inventory system |
| `app.ItemManager` | item definitions |
| `app.ItemResourceManager` | item resources |
| `app.CraftItemManager` | RE7's chem-fluid crafting |
| `app.AdditionalItemManager` | extra items |
| `app.Collision.DamageManager` | **shared damage pipeline** |
| `app.Collision.CollisionSystem` | collision |
| `app.GameManager` | game state |
| `app.GameFlowFsmManager` | game flow state machine |
| `app.MenuManager` | menu state |
| `app.AAASceneTransitionController` | scene transitions |
| `app.NowLoadingMovieManager` | loading |

### Main-game player types

RE7's type database contains three parallel sets: unprefixed, `app.CH8*`, and `app.CH9*`
(1,564 and 1,638 types respectively; `CH1`–`CH7` do not exist at all). The unprefixed set appears
to be the main game, and `CH8`/`CH9` appear to be DLC scenario modules — `app.CH9PlayerKnuckleWeapon`
and `app.CH9InteractWeaponGauntletEvent` look like End of Zoe's gauntlets.

**Which scenario each `CH` prefix belongs to is not determinable from type names alone.** The
probes dump all three so they can be compared against what is actually live at runtime. Do not
assume.

Health-related, unprefixed (main-game candidates):

```
app.PlayerStatus                     app.PlayerDamageController
app.PlayerMaxHealthTable             app.PlayerDamageController.DamageGUIController
app.PlayerResurrection               app.PlayerDamageControllerSaveData
app.PlayerBreathController           app.PlayerLArmDamage
app.CharacterDefine                  app.CharacterDefine.Vitality
```

`app.PlayerMaxHealthTable` is the most promising name in the database: it implies health is bounded
by table-driven maximums, which would give a principled ceiling to preserve against rather than an
invented constant.

Shared damage pipeline (affects enemies too — broader, so a fallback rather than a first choice):

```
app.DamageController                 app.Collision.DamageManager
app.DamageController.DamageRecord    app.Collision.CalculateDamage
app.Collision.HitController.DamageInfo    app.Collision.HitController.DamageValue
```

Weapon-related:

```
app.PlayerGun                        app.PlayerWeaponChange
app.PlayerWeaponChange.ItemType      app.PlayerReloadSpeedRateTable
app.PlayerEquipCheck                 app.PlayerMelee
app.PlayerThrowable                  app.BulletBase / app.BulletID
```

---

## Running the discovery dump

You need this because of the gap above: the dump is the only way to learn member names.

1. Launch RE7 and **load into actual gameplay.** Game objects are not constructed in the main
   menu; running the dump there produces an empty result.
2. Press **Insert** to open the REFramework menu.
3. Open **RE7 Personal Trainer → Developer**.
4. Click **Run discovery dump**.
5. The trainer writes `re7trainer_discovery.json` into the game folder, next to `re7.exe`:

   ```
   ~/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard/re7trainer_discovery.json
   ```

6. Optionally also tick **Log discovery output** to mirror a summary into the REFramework log.

**The JSON file is written through `json.dump_file`, which does not depend on REFramework's "Log to
disk" setting.** That setting is currently `false` in `re2_fw_config.txt`, which is why the
trainer writes its own file rather than relying on the log.

### Send back

The file `re7trainer_discovery.json` — or, if it is very large, just the sections for the subsystem
you care about:

```bash
# health only
python3 -c "import json;d=json.load(open('re7trainer_discovery.json'));print(json.dumps({'singletons':d['singletons'],'types':{'health':d['types']['health'],'damage':d['types']['damage'],'player_status':d['types']['player_status']}},indent=1))"
```

Alongside it, please note **where you were in the game** when you ran it — main menu, gameplay,
which chapter — because "singleton exists but is not constructed" is a meaningful result that
depends on it.

---

## What the dump contains

```jsonc
{
  "schema": "re7trainer-discovery",
  "environment": { "game_name": ..., "sdk_available": true, "trainer_frame": 12345 },

  // Which candidate singletons resolved. Three distinct states matter:
  //   type_exists=false            -> this build does not have it
  //   type_exists=true, constructed=false -> right build, not built yet (menu/loading)
  //   constructed=true             -> live and usable
  "singletons": [ { "name": "app.InventoryManager", "type_exists": true,
                    "constructed": true, "instance_type": "app.InventoryManager" } ],

  // Per subsystem: every candidate type with its full member list
  "types": {
    "health": [ {
      "type_name": "app.PlayerDamageController",
      "found": true,
      "parents": [ ... ],
      "method_count": 12,
      "field_count": 5,
      "methods": [ "System.Void applyDamage(System.Single, System.Int32)", ... ],
      "fields":  [ "System.Single DamageRate", ... ]
    } ]
  },

  "summary": { "candidate_types_found": 31, "candidate_types_missing": 7,
               "singletons_constructed": 4 }
}
```

**The `methods` and `fields` arrays are the point.** They are what turns a type name into a
decision.

---

## What happens with the result

Once the member lists are in hand, each cheat picks a strategy from a fixed, documented preference
order. This is already coded — the branches exist in `src/cheats/*.lua`, empty, waiting for real
names.

**Health**, in preference order:

1. **Hook the damage path.** If `app.PlayerDamageController` exposes a method that applies incoming
   damage, hook it and skip the original call. Nothing else changes: enemies still take damage,
   healing still works, the damage UI simply never fires. Preferred because it touches no data.
2. **Preserve the value.** If no hook point exists but a readable *and writable* health field does,
   capture it and restore it when it drops. The damage UI and audio still play.
3. **Restore after the fact.** Readable but not writable. Visible flicker, last resort.

**Ammo**, in preference order:

1. **Prevent consumption.** Hook the operation that decrements the magazine and skip it, so the
   count is never written by us at all.
2. **Capture and restore.** Read before and after the fire operation; rewrite if it dropped.
3. **Hold at baseline.** Crudest and most visible — it would also undo legitimate pickups, which is
   why it is last.

**Items**, in preference order:

1. **Prevent consumption on the consumable path only.** Hook the specific operation that consumes
   one unit of a *stackable* item, and skip it. Narrow by construction.
2. **Restore on decrease, consumables only.**

There is no third fallback for items. If neither is available, the cheat stays off permanently.

### The hard precondition on Infinite Items

Before Infinite Items can be enabled, discovery must establish **both**:

- a readable and writable quantity for a stackable consumable, **and**
- a reliable way to distinguish a stackable consumable from a **key/quest item**

If the second cannot be established, the correct outcome is a documented limitation and a
permanently disabled toggle. RE7 key items gate puzzles; a trainer that cannot tell a herb from a
keycard will eventually duplicate a keycard and make a run unrecoverable. The code enforces this —
`inventory.is_supported()` returns false while the safe-item set is empty — rather than leaving it
as a convention.

---

## Discovery is deliberately not automatic

Discovery never runs on a timer and never runs per frame. Walking every method of every candidate
type is genuinely expensive, and doing it during gameplay would stutter. It is triggered only by the
button, is guarded against re-entry, and caches its results.

When a cheat cannot be implemented, the correct response is **more discovery**, not a guess. That is
the rule this repository is built on.
