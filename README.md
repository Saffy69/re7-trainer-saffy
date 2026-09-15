# RE7 Personal Trainer

A personal, offline, single-player trainer for **Resident Evil 7: Biohazard**, implemented as a
REFramework Lua mod.

This repository is **discovery-first**. It does not yet contain working cheats, and that is
deliberate — see [Status](#status) below.

---

## Status

| Component | State |
|---|---|
| Trainer framework | **Working** |
| In-game menu | **Working** |
| Config persistence | **Working** |
| Safety / error handling | **Working** |
| Discovery subsystem | **Working** |
| Infinite Health / God Mode | **Not implemented** — game API not yet discovered |
| Infinite Ammo | **Not implemented** — game API not yet discovered |
| Infinite Items | **Not implemented** — game API not yet discovered |

**The three cheats do not work yet.** Their toggles exist, are structurally complete, and will
refuse to enable, explaining why in the menu. This is intentional and is explained in
[Why the cheats are empty](#why-the-cheats-are-empty).

---

## Why the cheats are empty

The project brief contains a rule that outranks every other requirement:

> DO NOT INVENT RE7 APIs. Do not tell me a cheat works unless we have verified it against the
> actual RE7 runtime.

So this is the honest position:

We know the **names** of 36,534 types in RE7's type database (TDB version 70). They were extracted
from your own REFramework log — see [docs/DISCOVERY.md](docs/DISCOVERY.md) for exactly how, and
which ones matter.

We do **not** know a single field name, method name, or method signature on any of them. The log
that gave us the type names contains type names only. Member information exists only inside the
running game process.

Writing `player:set_health()` today would be inventing an API. It would compile. It would run. It
would either do nothing, or write to an offset that happens to be valid and corrupt your save.
Neither is acceptable, so the cheats stay empty until discovery fills them in.

**What is already known and verified** is in [docs/DISCOVERY.md](docs/DISCOVERY.md) — including
`app.InventoryManager`, which the engine itself declares as a managed singleton.

---

## Requirements

- **Resident Evil 7: Biohazard** (Steam, AppID `418370`)
- **REFramework** installed and working
- Arch Linux + Proton (developed and verified against Proton Experimental)
- Lua 5.4+ on the host **only** for building and running the self-test — the game does not need it

This was developed against:

| | |
|---|---|
| Game build | Steam buildid `22773795` |
| REFramework | v1.5.9+7, commit `5bae4701`, built 2025-03-05 |
| TDB version | 70 |
| Game exe | `re7.exe`, 156,313,064 bytes |

See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for how these were determined and what the
trainer does when it finds something different.

---

## REFramework installation

Already done in this environment — REFramework is confirmed loading, and its log confirms the game
path and framework version. If you ever need to reinstall it:

1. Download REFramework from <https://github.com/praydog/REFramework>.
2. Extract `dinput8.dll` into the folder containing `re7.exe`.
3. Steam → RE7 → Properties → Launch Options:

   ```
   WINEDLLOVERRIDES="dinput8.dll=n,b" %command%
   ```

4. Launch the game and press **Insert** to confirm the REFramework menu opens.

The launch option is only needed if the DLL override is not already applied.

---

## Trainer installation

```bash
./tools/install.sh "/path/to/RESIDENT EVIL 7 biohazard"
```

The path is the folder containing `re7.exe`. On this machine:

```bash
./tools/install.sh "$HOME/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard"
```

The installer bundles `src/` into a single self-contained file and places it at
`reframework/autorun/re7trainer.lua`. It refuses to run against a folder with no `re7.exe`.

To remove it:

```bash
./tools/uninstall.sh "/path/to/RESIDENT EVIL 7 biohazard"
```

The uninstaller removes only files it installed, verified against a marker and a manifest. It never
touches `dinput8.dll`, `reframework/plugins/`, or any other mod.

### Why the installer bundles instead of copying files

The source is modular, but it cannot be *shipped* modular, for reasons verified against the
installed binary:

- this REFramework build has **no filesystem API** (`fs.*` is absent), so a script cannot locate
  its own directory
- it has **no game-directory accessor** (`get_game_directory` and friends are all absent), so
  `dofile` with a computed path is unavailable
- `require()` depends on `package.path`, which in this build embeds
  `...;.\?.lua;.\?\init.lua` — resolved against the process working directory, which we cannot rely on
- REFramework's ScriptRunner loads every `*.lua` in `autorun/`, so dropping fifteen module files
  there would execute each one as a standalone script

The bundler registers each module in `package.preload`, which Lua's `require()` consults **before**
any path-based searcher. That makes module resolution independent of `package.path`, the working
directory, and the load location. `tools/bundle.lua` documents this in full.

Edit files in `src/`, then re-run `tools/install.sh`.

---

## Launching

1. Launch RE7 through Steam.
2. Load into actual gameplay (not the main menu).
3. Press **Insert** to open the REFramework menu.
4. Find the **RE7 Personal Trainer** section.

The menu is also visible in the main menu, but game objects are not constructed until you are in
gameplay, so discovery results will be empty there. This is expected and the UI says so.

---

## Menu controls

```
RE7 Personal Trainer
  [x] Trainer enabled          <- master switch; off = nothing is modified

  Status
      Framework: Loaded
      Game:      RESIDENT EVIL 7 biohazard
      Trainer:   Ready
      Game state: gameplay / not in gameplay

  Player
      Infinite Health / God Mode     <- disabled until discovered

  Weapons
      Infinite Ammo                  <- disabled until discovered

  Inventory
      Infinite Items                 <- disabled until discovered

  Hotkeys
      God Mode        F6
      Infinite Ammo   F7
      Infinite Items  F8

  Developer
      [ ] Debug Mode
      [ ] Discovery Mode
      [ ] Log discovery output
      [ Run discovery dump ]
      ... subsystem discovery state, candidate type presence, maintenance
```

A toggle is only interactive once discovery has established that the cheat can actually run. Until
then it renders as a disabled line stating the reason. **This UI never offers a switch that
silently does nothing** — that is the property the whole design is built around.

Hotkeys route through the same `enable()` path the checkbox uses, so a hotkey cannot enable
something the UI would have refused. If the key API turns out to be unavailable in this build, the
trainer logs that once and disables hotkeys rather than failing every frame.

---

## Cheat behaviour

When implemented, each cheat follows the same rules:

- **Infinite Health** — prefer hooking the damage path so damage never applies; fall back to
  preserving the health value; restore-after-the-fact only as a last resort. Never write arbitrary
  memory.
- **Infinite Ammo** — firing leaves the count unchanged (12 stays 12, **not** 999999). Targets the
  magazine, not the reserve or the inventory stack.
- **Infinite Items** — using one of five herbs leaves five herbs. Never duplicates items. Never
  touches key or quest items. Refuses to enable at all unless discovery can positively distinguish
  a stackable consumable from a key item.

All cheats default to **off**. None persist unsafe runtime state.

---

## Documentation

| Document | Contents |
|---|---|
| [docs/DISCOVERY.md](docs/DISCOVERY.md) | The discovery workflow — what is already known, what to run, and what to send back |
| [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) | Verified environment, verified API list, and what to do when the build differs |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | When it does not load, does not appear, or does not work |

---

## Development

```bash
# Build the bundle
lua tools/bundle.lua src build/re7trainer.lua

# Syntax-check every source file
for f in $(find src -name '*.lua'); do luac -p "$f" || echo "FAIL $f"; done

# Run the offline self-test (stubs REFramework, executes the bundle)
lua tools/selfcheck.lua build/re7trainer.lua
```

`tools/selfcheck.lua` stands up a stubbed REFramework — a fake type database, imgui with the real
return-arity quirks, a logging sink — and executes the whole bundle against it. It verifies that
every module resolves, the menu draws, the frame loop runs, and discovery produces well-formed
output. It also fails on any read of an **undefined global**, which catches modules quietly
depending on state another script happened to set.

It does **not** prove any REFramework binding behaves as stubbed, and it does not prove any cheat
works — none are implemented yet.

### Repository layout

```
src/
  main.lua                 entry point; callback registration only
  config.lua               persistence (json.dump_file/load_file)
  logger.lua               prefixed, rate-limited logging
  state.lua                centralised state; prefs vs runtime
  ui/
    menu.lua               the trainer panel
    debug_menu.lua         developer panel
  cheats/
    health.lua             lifecycle-complete, functionally empty
    ammo.lua               lifecycle-complete, functionally empty
    inventory.lua          lifecycle-complete, functionally empty
  discovery/
    explorer.lua           type + singleton dump
    health_probe.lua       health/damage candidate members
    ammo_probe.lua         weapon/ammo candidate members
    inventory_probe.lua    inventory/item candidate members
  utils/
    safe_call.lua          pcall wrappers over every SDK call
    type_helpers.lua       read-only type-database reflection
    object_helpers.lua     live object lifetime + handle cache
    imgui_safe.lua         defensive imgui wrappers
tools/
  bundle.lua               src/ -> single autorun file via package.preload
  install.sh
  uninstall.sh
  selfcheck.lua            offline test harness
```

---

## Legal

For personal, offline, single-player use on a game you own. Not for distribution, not for
multiplayer, not for anything that touches another player's experience. No game files are included
or redistributed here.

MIT licensed — see [LICENSE](LICENSE).
