# Troubleshooting

Ordered by how likely each problem is, and how quickly it can be ruled out.

---

## The trainer does not appear in the REFramework menu

**Check the file is actually installed.**

```bash
GAME="$HOME/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard"
ls -la "$GAME/reframework/autorun/"
```

You should see `re7trainer.lua`. If it is missing, re-run `./tools/install.sh "<game path>"`.

**Check the file is valid Lua.**

```bash
luac -p "$GAME/reframework/autorun/re7trainer.lua" && echo "syntax OK"
```

A syntax error in `autorun/` is a **silent no-op** — the script simply never runs and REFramework
does not surface an obvious error. This is the single most common cause of "nothing happened".

**Check the log for Lua errors.**

```bash
grep -aiE 'lua|script|error' "$GAME/re2_framework_log.txt" | tail -40
```

**Check REFramework itself is loading.** If the REFramework menu (Insert) does not open either,
this is not a trainer problem. Confirm `dinput8.dll` is next to `re7.exe` and that the Steam launch
option is set:

```
WINEDLLOVERRIDES="dinput8.dll=n,b" %command%
```

---

## The menu appears but a cheat toggle is greyed out

A greyed toggle is not a bug — it is the UI refusing to offer a switch that would silently do
nothing. The line carries the **specific reason**, and the reason names what to check.

The common ones:

| Reason | What it means |
|---|---|
| `app.Item is not present in this build` | Your game build's type database differs from the one this was written against. See [COMPATIBILITY.md](COMPATIBILITY.md); nothing will work until the routes are re-derived against a dump from your build. |
| `app.ItemData missing, so item categories cannot be read safely` | Same class of problem, for Infinite Items specifically. The gate fails closed rather than guessing. |
| `no inventory readable yet -- load into gameplay and try again` | You are in the main menu. Load a save; game objects do not exist until you are in gameplay. |
| `none of the N carried items can be classified as a consumable` | You are in gameplay and the inventory reads, but nothing you carry is in a conserved category. Pick up an herb or some ammo and try again — or widen the categories from **Developer → Conserved categories**. |

To confirm the framework is alive independently of the cheats, open **Developer → Debug Mode** and
check that `SDK available` reads `true` and the frame counter is advancing.

If the build is genuinely mismatched, **Developer → Run discovery dump** (from inside gameplay) is
how a fresh set of routes gets derived. See [DISCOVERY.md](DISCOVERY.md).

---

## The discovery dump writes no file

**Cause 1 — you are in the main menu.** Game singletons are not constructed until you load into
gameplay. Launch a save, then run the dump.

The dump reports this rather than hiding it: `constructed: false` with `type_exists: true` means
"right build, not built yet". `constructed: 0` for every singleton almost always means you are on
the main menu.

**Cause 2 — the game directory is not writable.** The file is written relative to the process
working directory, which is normally the game folder. Check permissions:

```bash
GAME="$HOME/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard"
touch "$GAME/write_test" && echo "writable" && rm "$GAME/write_test"
```

On a Proton prefix the game folder is under your home directory and should be writable. If it is
not — an unusual library location, or a read-only mount — the trainer logs the failure and the
details stay in the in-game console instead.

**Cause 3 — `json` is unavailable.** If this build lacks `json.dump_file`, the trainer says so once
at startup and writes nothing. Check the log for `json.dump_file/load_file unavailable`.

---

## No Lua output in `re2_framework_log.txt`

**This is the current configuration, not a fault.** `re2_fw_config.txt` contains:

```
ScriptRunner_LogToDisk=false
```

With logging to disk off, Lua output goes to the in-game console (visible inside the REFramework
menu) but not to the file on disk.

This is precisely why the discovery dump writes its **own** JSON file via `json.dump_file` rather
than relying on the log. You do not need to change this setting to use the trainer.

If you want Lua output in the log file anyway, enable **Log to disk** in the REFramework menu under
the ScriptRunner settings, which rewrites that key to `true`.

---

## "Framework: NOT DETECTED" in the Status panel

The trainer loaded but could not reach the REFramework SDK table. It will stay inert — that is
intentional, since every meaningful action goes through `sdk`.

Verify the SDK is genuinely available by checking the binary:

```bash
GAME="$HOME/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard"
strings -n 3 "$GAME/dinput8.dll" | grep -acx "get_managed_singleton"   # expect 1
```

If that returns `0`, the installed REFramework is a different lineage than the RE2/RE3/RE7/DMC5
build this trainer targets. See [COMPATIBILITY.md](COMPATIBILITY.md).

---

## The game crashes

First, establish whether the trainer is responsible. Uninstall it and reproduce:

```bash
./tools/uninstall.sh "<game path>"
```

If the crash persists, it is not the trainer.

**If it is the trainer**, please capture:

```bash
ls -la "$GAME/reframework_crash.dmp"
tail -100 "$GAME/re2_framework_log.txt"
```

Note that `reframework_crash.dmp` and repeated `Present failed` errors in the log are **pre-existing**
on this machine — the crash dump present before this trainer was installed shows failures on the
`PRESENT` path under Wine 11.0, which is a Proton/vkd3d graphics issue and unrelated to Lua. Worth
ruling that out before attributing a crash to the mod.

The trainer is built so that it should be very hard to crash the game: every SDK call is wrapped in
`pcall`, object handles are validated before every use and dropped when stale, and no cheat writes
anything at all until discovery has verified a target. If it does crash, that is a bug worth
reporting with the log.

---

## Hotkeys do nothing

Hotkeys are guarded and self-disable. If `imgui.is_key_pressed` is unavailable or errors, the
trainer logs this **once** (not every frame) and stops trying:

```
imgui.is_key_pressed is unavailable; hotkeys are disabled. Use the menu toggles.
```

Check the log for that line. The menu toggles remain fully functional regardless — hotkeys are a
convenience, and the UI is the supported path.

Note also that a hotkey for a **disabled** cheat does nothing but log:

```
God Mode hotkey ignored: app.HealthInfo is not present in this build
```

The trailing reason is the same string the menu shows on the greyed toggle, so the log and the UI
never disagree about why something is unavailable.

That is deliberate. Hotkeys route through the same `enable()` path the checkbox uses, so a hotkey
can never enable something the UI would have refused.

---

## Settings are not saved

The config file is `re7trainer_config.json`, in the game folder. Check:

```bash
cat "$GAME/re7trainer_config.json"
```

If it does not exist, either the directory is not writable (see above) or `json.dump_file` is
unavailable. The trainer logs the reason once and continues running with defaults — losing
preferences never blocks the mod.

Note that **cheats always default to off**, deliberately. A trainer that switches itself on when the
game loads surprises you at the worst possible moment.

---

## The menu is slow or stutters

Discovery is the only expensive operation, and it never runs automatically — only from the button,
guarded against re-entry. If the menu itself stutters, check **Developer → Debug Mode** for the
cached-handle count; a large number means handles are not being released on scene change, which
would be a bug worth reporting.

---

## Reporting a problem usefully

The most useful report contains:

1. What you did, and where in the game you were.
2. What you expected, and what happened.
3. `re7trainer_discovery.json`, if the problem involves discovery.
4. The relevant tail of `re2_framework_log.txt`.
5. The environment block from **Developer → Debug Mode**.

Please **do not** report a cheat as "not working" without checking its toggle reason first — the
trainer is designed to state exactly why it cannot act, and that line is almost always the answer.
