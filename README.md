# RE7 Personal Trainer

Three cheats for **Resident Evil 7: Biohazard** — infinite health, infinite ammo and infinite
items — delivered as a REFramework Lua mod.

Offline, single-player, no external process. It does not scan memory, use Cheat Engine, write to
fixed offsets, or touch save files. Everything it does goes through the game's own objects, using
routes that were read out of a running copy of RE7 rather than guessed at.

> **The rule this was built under:** do not invent RE7 APIs, and do not claim a cheat works unless
> it has been verified against the actual game. Everything below is written to that standard, which
> is why some of it is more cautious than you might expect.

---

## What it does

| Cheat | Key | How it works | In-game state |
|---|---|---|---|
| **Infinite Health** | `F6` | Holds your health at its maximum. Reads `get_maxHealth()` and writes the value back when it drops. | Confirmed working in game |
| **Infinite Ammo** | `F7` | Sets the game's own `IsLoadNumInfinity` flag on the gun. The gun does the rest — this is the game's own mechanism, not a value being faked. | Confirmed working in game |
| **Infinite Items** | `F8` | Intercepts `app.Inventory.reduceItem` and skips it for consumables, with a per-frame stack restore behind it for items that decrement without being removed. | Confirmed working in game |

All three default to **off**, every session. They are deliberately not persisted — see
[Safety design](#safety-design).

The game's own "unlimited ammo" in the menu is a different thing from this and is worth turning on
too if you want it.

---

## Requirements

- **Resident Evil 7: Biohazard** on Steam (AppID `418370`)
- **REFramework** v1.5.9 or newer, installed and confirmed working
- For the installer script: `bash`. On Windows that means Git Bash or WSL — or just copy the files
  by hand, which is [two steps](#installing-on-windows-by-hand).

Lua on your machine is **not** required to install or to play. It is only needed if you want to
build the bundle or run the offline self-test yourself.

### What it was built and verified against

| | |
|---|---|
| Game build | Steam buildid `22773795` |
| TDB version | 70 |
| REFramework | v1.5.9 (commit `5bae4701`) |
| Platform | Linux + Proton (Proton Experimental) |

**A TDB bump can invalidate this.** If Capcom ships a patch that changes the type database, the
routes can stop resolving. The trainer handles that the honest way: the affected toggle greys out
and states the reason, rather than switching on and silently doing nothing. See
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

Windows is not verified, but nothing here is Proton-specific — REFramework works natively there and
the mod uses no platform APIs.

---

## Installing

### 1. REFramework first

The trainer is a guest of REFramework and does nothing without it.

1. Download the latest release from <https://github.com/praydog/REFramework>.
2. Extract `dinput8.dll` into the folder containing `re7.exe` — usually
   `.../steamapps/common/RESIDENT EVIL 7 biohazard/` on Linux,
   `C:\Program Files (x86)\Steam\steamapps\common\RESIDENT EVIL 7 biohazard\` on Windows.
3. **On Linux / Proton only**, set the launch option in Steam → RE7 → Properties → Launch Options:

   ```
   WINEDLLOVERRIDES="dinput8.dll=n,b" %command%
   ```

4. Launch the game and press **Insert**. If the REFramework overlay opens, you are done.

Run REFramework at least once before installing the trainer — the installer checks that its
`reframework/` folder exists and refuses otherwise, which is a far better error than installing
into the wrong place.

### 2. The trainer

```bash
git clone https://github.com/Saffy69/re7-trainer-saffy.git
cd re7-trainer-saffy
./tools/install.sh "/path/to/RESIDENT EVIL 7 biohazard"
```

The path is the folder containing `re7.exe`. On Linux with a default Steam library that is:

```bash
./tools/install.sh "$HOME/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard"
```

The installer needs no Lua, copies the module tree into `reframework/autorun/re7trainer/`, and
writes a two-line loader at `reframework/autorun/re7trainer.lua`. It refuses to run against a
folder that has no `re7.exe`, so a typo cannot scatter files into an unrelated game.

### Installing on Windows by hand

The installer is a bash script, so on Windows either use Git Bash / WSL or do this in PowerShell —
it is the same thing the script does:

```powershell
$game = "C:\Program Files (x86)\Steam\steamapps\common\RESIDENT EVIL 7 biohazard"
$dest = "$game\reframework\autorun\re7trainer"

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Recurse -Force .\src\* $dest
Set-Content -Path "$game\reframework\autorun\re7trainer.lua" -Value 'return require("re7trainer.main")'
```

That last file matters: REFramework only auto-runs scripts directly inside `autorun/`, so the
one-line loader is the entry point and everything under `re7trainer/` is pulled in by `require()`.

---

## Using it

1. Launch RE7 and **load into actual gameplay**. The toggles read your live inventory and health,
   and those objects do not exist in the main menu.
2. Press **Insert** to open the REFramework menu.
3. Open the **RE7 Personal Trainer** section.
4. Tick **Trainer enabled**, then tick whichever cheat you want — or press `F6` / `F7` / `F8`.

```
RE7 Personal Trainer
  [x] Trainer enabled            <- master switch; off = nothing is modified

  Status      Framework: Loaded | Game: RESIDENT EVIL 7 biohazard | Trainer: Ready
  Player      [x] Infinite Health / God Mode
  Weapons     [x] Infinite Ammo
  Inventory   [x] Infinite Items
  Hotkeys     F6 / F7 / F8
  Developer   debug panel, discovery tools, conserved categories
```

The **Trainer enabled** switch is a panic button: turning it off disables all three cheats at once
without forgetting which ones you had ticked.

A cheat that cannot run on your build renders as a **greyed line carrying the specific reason**
instead of a checkbox. That is not the trainer being broken — it is the trainer refusing to offer
you a switch that would do nothing.

---

## Infinite Items, and what it will and will not touch

Using an item runs through a function called `reduceItem` that removes it from your inventory. The
cheat intercepts that call and skips it — but only for items it can positively identify as a
consumable.

**By default it conserves three categories**, and these were established by reading the values off
live items, not by guessing at the enum:

| Value | Category | Examples |
|---|---|---|
| 2 | `Shell` | Shotgun shells, grenade rounds |
| 3 | `Drug` | Herbs, first aid, chem fluid |
| 7 | `Material` | Gunpowder, repair kits |

**Key items, quest items and weapons are left alone by default**, on purpose. Duplicating a key
item can make a run unrecoverable, and that is a worse outcome than a cheat that does not cover
everything.

### Widening it: Conserved categories

If you want antique coins, lockpicks, or anything else to survive too, open
**Developer → Conserved categories**. It lists the category values actually present in your
inventory right now, with a sample item and a count, and each non-default one has a tick box:

```
Conserved categories
    [ ] conserve value 5  (3 items, e.g. AntiqueCoin)
    conserve value 2  (1 item, e.g. ShotgunShell)     always on
    conserve value 3  (4 items, e.g. RemedyM)         always on
    conserve value 7  (2 items, e.g. ChemicalM)       always on
```

Ticking one takes effect immediately. Three things to know:

- The three defaults **cannot be unticked** — switching one off would silently stop the cheat
  working for the items it was built for.
- It is **runtime-only** and does not survive a restart. You re-tick each session. That is
  deliberate: a saved-on cheat setting is how you end up with a checkbox reading "on" over a module
  that was never started.
- **Ticking a category that contains key items carries a real risk.** If the game removes something
  on purpose for a story beat and the removal is blocked, that script may not advance. Reloading a
  save fixes it. The panel says this; take it seriously.

---

## Safety design

These are the properties the project is built around, not aspirations:

- **No guessed APIs.** Every route into the game was read out of a live copy of RE7 with a
  discovery dump. There are no hardcoded offsets anywhere in this repository, deliberately — an
  offset is a fact about one build that silently becomes wrong on the next.
- **Every write is verified by re-reading.** A setter returning success is not evidence that it
  worked; RE7 has at least one that returns success and changes nothing. The health cheat is built
  around this.
- **Fail closed.** If an item's category cannot be read, it is treated as a key item and left
  alone. If a `reduceItem` call cannot be identified, it passes through untouched. The conservative
  direction is the one that keeps a save file intact.
- **Cheats default off and are never persisted.** A trainer that turns itself on when the game
  loads is a trainer that surprises you at the worst moment.
- **Nothing is modified outside gameplay.** The trainer only acts when a save is loaded.
- **It never touches save files**, `.pak` files, or anything outside `reframework/autorun/`.
- **Failures are inert and explained.** If something goes wrong, the trainer stays loaded but does
  nothing, and says why in the menu. It is not possible for this mod to stop the game running.

---

## Uninstalling

```bash
./tools/uninstall.sh "/path/to/RESIDENT EVIL 7 biohazard"
```

It removes only the files it installed, verified against a manifest, and prunes only directories
that become empty. It never touches `dinput8.dll`, `reframework/plugins/`, or any other mod. To
remove it by hand, delete `reframework/autorun/re7trainer.lua` and the
`reframework/autorun/re7trainer/` folder.

---

## Troubleshooting

Throughout this section, `GAME` is the folder containing `re7.exe`:

```bash
GAME="$HOME/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard"
```

**The trainer does not appear in the menu.** Check `reframework/autorun/re7trainer.lua` exists, and
check the REFramework log for Lua errors:

```bash
grep -aiE 'lua|script|error' "$GAME/re2_framework_log.txt" | tail -40
```

A syntax error in `autorun/` is a silent no-op — the script simply never runs. Reinstalling fixes
it.

**A toggle is greyed out.** Read the reason on the line. It names what to check — usually "load
into gameplay" if you are in the main menu.

**Infinite Items does not conserve something.** Check **Developer → Item classification**: each
item is listed with its observed category value and whether it is conserved, and the reason if not.
If it is a category you want, tick it under **Conserved categories**.

**Anything else** — [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) goes through the failure
modes one at a time.

---

## Building and testing

```bash
# Syntax-check every source file
for f in $(find src -name '*.lua'); do luac -p "$f" || echo "FAIL $f"; done

# Build the single-file bundle
lua tools/bundle.lua src build/re7trainer.lua

# Offline self-test: stubs REFramework, executes the whole thing
lua tools/selfcheck.lua build/re7trainer.lua                  # bundle mode
lua tools/selfcheck.lua --autorun <game>/reframework/autorun  # modular mode
```

`tools/selfcheck.lua` stands up a stubbed REFramework — a fake type database, a realistic imgui, a
logging sink — and runs every module against it. It also fails on any read of an **undefined
global**, which catches modules quietly depending on state another script happened to set.

It is a regression net, not evidence: it does not prove any REFramework binding behaves as stubbed,
and it does not prove a cheat works. Only the game does that.

Edit files in `src/`, then re-run `tools/install.sh` — the game does not read `src/`.

### Repository layout

```
src/
  main.lua                 entry point; callback registration and per-frame orchestration only
  config.lua               persistence (json.dump_file/load_file)
  logger.lua               prefixed, rate-limited logging
  state.lua                prefs (persisted) vs runtime (session facts)
  game.lua                 the ONLY module that knows RE7's object graph
  cheats/
    health.lua             read-and-restore against max health
    ammo.lua               the game's own IsLoadNumInfinity flag
    inventory.lua          reduceItem gate + stack restore
  ui/
    menu.lua               the trainer panel
    debug_menu.lua         developer panel, item classification, conserved categories
  discovery/               type dumps and the probes that established the routes
  utils/
    safe_call.lua          pcall wrappers over every SDK call, hook install + counters
    type_helpers.lua       read-only type-database reflection
    object_helpers.lua     live-object validity + handle cache
    imgui_safe.lua         defensive imgui wrappers
tools/
  install.sh               installer (modular by default, --bundle as a diagnostic)
  uninstall.sh             removes only files this trainer installed
  bundle.lua  selfcheck.lua
docs/
  DISCOVERY_RESULTS.md     RE7's real object graph, with the evidence
  COMPATIBILITY.md         the verified REFramework API surface, present and absent
  DISCOVERY.md             how the discovery workflow works
  TROUBLESHOOTING.md       when it does not load, appear, or work
```

`src/game.lua` is the only file that knows RE7's object graph. The cheats are written in terms of
"the inventory" and "the player", so when a route turns out to be wrong there is exactly one file
to fix.

---

## Legal

For personal, offline, single-player use on a game you own. Not for multiplayer, and not for
anything that touches another player's experience. No game files are included or redistributed
here, and REFramework is a separate project with its own licence.

MIT licensed — see [LICENSE](LICENSE).
