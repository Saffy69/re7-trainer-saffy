# RE7 Personal Trainer — working notes for Claude

A personal, offline, single-player trainer for **Resident Evil 7: Biohazard**, shipped as a
**REFramework Lua mod**. Lua 5.5 on the host is used only to build and self-test; the game loads
the mod from `reframework/autorun/`.

---

## The iron rule

> **DO NOT INVENT RE7 APIs.** Do not say a cheat works unless it has been verified against the
> actual RE7 runtime.

This outranks every other consideration in this repo, including "make the feature work".

It has three practical consequences, and the second two are the ones that get forgotten:

1. **No guessed member names, signatures, field indices, or offsets.** Every route in
   `src/game.lua` came out of a live discovery dump. If you need a new route, dump it — do not
   reason it out from a type name.
2. **A call that returns success is not evidence.** `app.HealthInfo:set_health()` returned
   success hundreds of times while health kept dropping, because the object was a struct copy.
   **Verify every write by re-reading the value.** `src/game.lua:209` (`M.set_health`) is the
   reference implementation of this.
3. **Report the real state.** If something was not tested, say "not tested". If a test failed,
   show the output. The user built this project specifically to avoid a trainer that lies.

---

## Current status — read this before believing anything else

As of the latest commit, all three cheats are **confirmed working in game** — the author ran them
and watched them work. `README.md` now describes this state accurately and is safe to use as a
user-facing status source.

| Cheat | Mechanism | In-game state |
|---|---|---|
| **Infinite Ammo** | Sets the game's own `app.WeaponGunParameter.IsLoadNumInfinity` | Confirmed working in game. |
| **Infinite Health** | Read-and-restore: target `get_maxHealth()`, write back when it drops | Confirmed working in game. |
| **Infinite Items** | Hook `app.Inventory.reduceItem`, skip it for conservable categories, plus a per-frame stack restore | Confirmed working in game — `reduceItem: calls=35 last=SKIP ([3] Material (value 7))`. |

"Confirmed working" means the author observed it in the running game on build `22773795`. It is
still not something a session can verify for itself, so before *extending* a cheat, get a fresh
observation — the debug panel is designed for exactly that.

The health and items cheats are **read-and-restore / hook-and-skip with verification**, which is
the project's *second*-choice strategy. The preferred "prevent it at the source" was not reachable
for health (the only interception point that fired is not the health write). This trade-off is
documented at the top of `src/cheats/health.lua`. Working is not the same as elegant — do not
rewrite the doc comment there to claim the preferred route was found.

**Unverified and worth testing:** `app.HealthInfo` has `set_isForbidDamageReaction(bool)`, which the
game itself consults. If it prevents health loss outright it would be a strictly better health
cheat. It is unproven — "forbid damage *reaction*" may only suppress the stagger animation.

### Conserved categories — the one user-widened surface

Infinite Items conserves three category values by default: `2=Shell`, `3=Drug`, `7=Material`. Those
are the only ones ever *observed*, because enum members sort alphabetically in a reflection listing
so names cannot be paired with numbers by position.

`Developer → Conserved categories` (`src/ui/debug_menu.lua::draw_category_controls`) lists the
values actually in the inventory and lets the player tick more. Ticking conserves that whole
category. Three properties to preserve if you touch it:

- **Runtime only, never persisted.** Same reason the cheat toggles are not persisted; a stale
  allowlist that survives a restart is a checkbox reading "on" over nothing.
- **Additive only.** A default cannot be unticked — switching off `Shell` would silently stop the
  cheat working for the items it was built for.
- **The gate stays an allowlist.** Unknown categories are untouchable. Do not invert this to a
  denylist.

Ticking a category containing key items can stall a run if the game removes one on purpose. The
panel warns about this; it is a real risk, not a disclaimer.

---

## Commands

```bash
# Build the single-file bundle (not the default install path, but used by selfcheck)
lua tools/bundle.lua src build/re7trainer.lua

# Syntax-check every source file
for f in $(find src -name '*.lua'); do luac -p "$f" || echo "FAIL $f"; done

# Offline self-test against a stubbed REFramework — MUST pass before you claim anything
lua tools/selfcheck.lua build/re7trainer.lua                  # bundle mode
lua tools/selfcheck.lua --autorun <game>/reframework/autorun  # modular mode

# Install (modular is the default; --bundle is a diagnostic)
./tools/install.sh "$HOME/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard"
./tools/uninstall.sh "<same path>"
```

`tools/selfcheck.lua` stands up a fake type database, a realistic imgui, and a logging sink, then
executes the whole thing. **It currently reports `70 checks, 0 failed` in bundle mode and `69
checks, 0 failed` in modular mode** (modular runs one check fewer because it does not exercise the
bundle's `package.preload` path) — treat any regression from that as a bug you introduced. It also
fails on any read of an **undefined global**, which catches modules quietly depending on state
another script happened to set.

**What selfcheck does NOT prove:** that any REFramework binding behaves as stubbed, or that any
cheat works. It is a regression net, not evidence. Passing it is necessary, never sufficient.

The installer syntax-checks `src/` with `luac -p` and refuses to install on failure. After editing
`src/`, re-run `install.sh` — the game does not read `src/`.

---

## You cannot see the game. The user is the sensor.

This is the single most important workflow fact. You cannot launch RE7, open the menu, or observe a
cheat. Every in-game fact arrives from the user, or from a JSON file they bring back.

So **the loop is**:

1. Make the change.
2. Make the *diagnostic* change alongside it. The debug panel
   (`src/ui/debug_menu.lua`) exists to answer "why is this doing nothing" without a log. If you are
   fixing something that "does not work", add or extend a panel line that distinguishes the
   candidate causes — do not guess which one it is.
3. Build, run selfcheck, report `N checks, M failed` verbatim.
4. **Tell the user exactly what to do and what to look for**, in concrete steps:
   > Enable X, fire once, then read Developer → Hooks and tell me the `calls=` and `last=` values.

Never ask "does it work now?" — ask for the specific observable that discriminates.

When the user reports "it still doesn't work", the debug panel is the first stop, not the source
code. The panel was built after three separate rounds of guessing at the wrong thing.

### The discovery dump

`Developer → Run discovery dump` writes `reframework/data/re7trainer_discovery.json` (note the
path — `json.dump_file` resolves relative to `reframework/data/`, not the game root).

> **Play first, dump second.** `RETypeDefinition:get_methods()` is a *filtered* view that drops
> methods whose function pointer is null or whose code is still stub. The engine resolves managed
> methods lazily, so a dump taken from a freshly loaded save reports **zero methods for every
> type** — while `get_parent_type()` still works, which makes it look like a shape bug. Have the
> user take damage, fire a weapon, and use an item *before* dumping.

`Developer → Probe reflection API` measures what the reflection accessors actually return, for when
a type comes back empty anyway.

`Developer → Method-call probe` installs counting hooks per group (`damage` / `ammo` / `items`),
then Mark → act → Report shows which methods actually fired. **Install one group at a time** —
installing a batch of unverified hooks crashed the game once and left no way to name the culprit.

---

## Architecture

```
src/
  main.lua                 entry point. callback registration + per-frame orchestration ONLY.
  state.lua                prefs (persisted booleans) vs runtime (session facts). *_supported flags.
  config.lua               json.dump_file persistence. Booleans only.
  logger.lua               prefixed logging; throttled(key, frames, ...) / once(key, ...)
  game.lua                 THE ONLY module that knows RE7's object graph.
  cheats/{health,ammo,inventory}.lua   lifecycle: initialize/enable/disable/update/reset/status
  ui/{menu,debug_menu}.lua             the panel and the developer panel
  discovery/                explorer (type dump), *_probe, introspect, hook_probe
  utils/
    safe_call.lua          guarded SDK access, hook install + counters
    type_helpers.lua       read-only type-database reflection, managed-list conversion
    object_helpers.lua     object validity, field get/set, handle cache
    imgui_safe.lua         defensive imgui wrappers
tools/
  bundle.lua  install.sh  uninstall.sh  selfcheck.lua
```

**Keep RE7 knowledge in `src/game.lua`.** The cheats are written in terms of "the inventory" and
"the player"; when a route turns out to be wrong there is exactly one file to fix. Adding a field
read to a cheat module directly is the thing this layout exists to prevent.

### Module loading

Only `autorun/re7trainer.lua` is auto-executed — `ScriptRunner::reset_scripts()` iterates
`autorun/*.lua` **non-recursively**. Everything under `autorun/re7trainer/` is pulled in by
`require()`, which works because `reset_scripts()` appends `<autorun>/?.lua` and
`<autorun>/?/init.lua` to `package.path` beforehand. New module? `require("re7trainer.<path>")`
with dots — no registration step. `--bundle` rebuilds it all into `package.preload` as a
diagnostic for when modular loading breaks.

---

## Design invariants — do not break these

1. **Never offer a switch that silently does nothing.** A toggle is interactive only when
   `state.runtime.<x>_supported` is true; otherwise `ui/menu.lua` renders a disabled line carrying
   the *specific* reason. This is the property the whole UI is built around.
2. **Fail closed.** An item whose category cannot be read is treated as a key item and left alone.
   An unidentifiable `reduceItem` call passes through. `is_safe_to_conserve` returns `false` when
   unsure — the conservative direction is the one that keeps a save file intact.
3. **Cheats default OFF and are never persisted.** `config.PERSISTED_KEYS` deliberately excludes
   the three cheat toggles. Persisting them produced a checkbox that read "on" while the module
   behind it had never had `enable()` called. Do not "fix" this by re-enabling on load — that means
   touching the game at startup, in the main menu, which is where the previous round of bugs came
   from.
4. **`initialize()` runs at script load, which is the main menu.** It may only check *types*. Any
   check requiring a live object belongs in `enable()` or `update()`. Getting this wrong marked a
   subsystem unsupported for a whole session, before a save was even loaded.
5. **Read-and-restore only undoes *decreases*.** A rise is a heal, pickup or story event. A naive
   "set to max every frame" fights the game and pins the player at a value it does not expect.
6. **`sdk.hook` has no `remove_hook` in this build.** A hook is permanent for the process. Enable
   state is carried by a *flag the callback reads*, never by the presence of the hook. Install at
   most once per key (`safe_call.hook_method` enforces this).
7. **Hook bodies must be cheap.** They run synchronously on whatever game thread called the method,
   holding the Lua lock, and stall that thread for their duration. Accumulate state, act in
   `re.on_frame`.
8. **Never cache a singleton or a game object across frames.** `sdk.get_managed_singleton` invokes
   the game's own `get_Instance()`, which legitimately returns nil mid-transition.
   `RETypeDefinition` handles are stable and fine to cache. `game.inventory()` re-resolves on every
   call on purpose.

---

## Traps already paid for — the highest-value section here

Each of these cost a round trip to the running game. Do not re-learn them.

| Trap | Reality |
|---|---|
| `get_method(name)` looks authoritative | It does **no** filtering. `get_methods()` drops stub/null-function methods. Hooking an unfiltered descriptor patches stub memory → silently does nothing, or crashes. `safe_call.hook_method` refuses these by checking the filtered list first. |
| `PlayerDamageController.doDamage` | Fires, and skipping it does **not** stop damage. It is reaction/animation work. Health lives on the base class `app.DamageController`. |
| `app.HealthInfo:set_health()` | Returns success, changes nothing — it is a value type, so `getHealthInfo()` hands back a copy. |
| `app.PlayerGun` | A **controller** (derives from `app.PlayerBase`, ~230 methods), not the gun. The real `app.WeaponGun` is in its `WeaponGun` field. `get_loadNum()` on the controller is a passthrough, which is why reads worked and everything nested looked unreachable. |
| `gun:set_loadNum()` | Accepted, no effect. The gun derives it from `CurrentBulletInfo.LoadNum`. |
| Item `Category` | Arrives as a **number**, not a string. And enum members sort alphabetically in a reflection listing, so names cannot be paired with numbers by position — the values were **observed**: `2=Shell`, `3=Drug`, `7=Material`. Only those three are conservable. |
| `expendBullet()` / `Item.reduceNum()` | Hooked, never fired. `WeaponGun.set_loadNum` and `shoot` are what actually run. |
| `Item.destroyItem` | Blocking it reported "2 blocked" while items were consumed anyway. It is a lifecycle notification, and it fires for combining and discarding too. Now observe-only. |
| Item enumeration | `get_ItemList()` returned nothing while the hook was demonstrably receiving real items; the `_ItemList` backing field works. Two routes are tried and the debug panel reports which one produced the result. |
| Lua local scoping | `ensure_hook` was defined *above* the callbacks it references, so it compiled and then passed `nil` to `sdk.hook` at runtime. **This happened twice.** Declare callbacks before the function that references them. |
| Shared hook counters | Two hooks recording under one key made the panel read `reduceItem: calls=0` while showing recorded arguments. Every `note_invocation` in a callback must use that callback's own key. |
| `main.lua` globals | `prefs_snapshot` must be declared *before* the closures that capture it, or they capture a global. |
| Missing REFramework APIs | No `sdk.get_local_player`, no `fs.*`, no `begin_child`, no `colored_text`, no `remove_hook`, no `get_game_directory`, no `to_int32`/`to_uint32`. Full present/absent list in `docs/COMPATIBILITY.md` — check it before using any binding. |
| `#` on sol2 containers | A sol2 container is not a Lua table. Use `type_helpers.to_managed_list` / `to_array`; do not `ipairs` raw results. |

---

## Verified API surface

Do not re-derive any of this. It is documented, with the evidence:

- **`docs/DISCOVERY_RESULTS.md`** — RE7's real object graph: how to reach the player, health, ammo
  and items, with the exact members. Read this first when touching a cheat.
- **`docs/COMPATIBILITY.md`** — the verified present/absent REFramework API, `sdk.hook`'s exact
  callback shape, the object-model corrections (`obj:get_type()` does not exist — use
  `get_type_definition()`), and how to re-verify against `dinput8.dll` with `grep -acx`.
- **`docs/DISCOVERY.md`** — the discovery workflow in full.
- **`docs/TROUBLESHOOTING.md`** — when it does not load, appear, or work.

Entry point to the player (both routes are tried, in `game.inventory()`):
`app.Inventory.getActivePlayerInventory()` (static, preferred) →
`inventory.PlayerStatus` → everything else hangs off `app.PlayerStatus`.

---

## Environment

Developed and verified against build `22773795`, TDB **70**, REFramework `v1.5.9`
(commit `5bae4701`), Proton. **A TDB bump invalidates the candidate type lists and anything learned
from a dump** — re-dump rather than carrying a fact forward. Never port an offset or field index
across builds; this repo deliberately stores none.

`~/Documents/CLAUDE.md` (the parent directory) contains frontend/design rules for web projects.
**They do not apply here** — there is no HTML, CSS, or Playwright in this repo. Ignore those
instructions for this project.

---

## Before you say you are done

1. `luac -p` clean on every file you touched.
2. `lua tools/selfcheck.lua build/re7trainer.lua` → report the check count and failure count
   verbatim. Do not round "0 failed" up from anything else.
3. State which parts are **verified** and which are **untested**. If you could not test it, say so
   plainly — that is the expected answer, not a failure.
4. If the user has to do something in-game for the next step, end with the exact steps and the
   exact values to bring back.
