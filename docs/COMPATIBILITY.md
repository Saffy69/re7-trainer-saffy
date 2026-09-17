# Compatibility

What this trainer was verified against, how to check your own install, and what happens when
something differs.

---

## Verified environment

Every value below was read from this machine, not assumed.

| | Value | Source |
|---|---|---|
| Game | RESIDENT EVIL 7 biohazard | Steam AppID `418370` |
| Game build | `22773795` | `appmanifest_418370.acf` |
| Build last updated | 2026-09-11 12:35 (+0545) | same manifest |
| Executable | `re7.exe`, 156,313,064 bytes | filesystem |
| REFramework tag | `v1.5.9` | `re2_framework_log.txt` |
| REFramework commit | `5bae4701396248a776c1de19f5be9552022295d5` | same |
| Commits past tag | 7 | same |
| Branch | `master` | same |
| Framework build date | 2025-03-05 06:48 | same |
| Type database version | **70** | same |
| Game module base | `0x140000000`, size `0x9a37000` | same |
| Menu key | VK 45 (Insert) | `re2_fw_config.txt` |
| Script log to disk | **false** | same |
| DLC content | `re_dlc_stm_564190.pak` | `dlc/` |

The framework writes its log as `re2_framework_log.txt` and its config as `re2_fw_config.txt`. That
`re2_` prefix is not a sign you have the wrong build — this single REFramework product line serves
RE2, RE3, RE7 and DMC5, and uses that prefix throughout.

### How to check your own install

```bash
GAME="$HOME/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard"

grep -aE 'Commit hash|Tag:|Commits past tag|Build date' "$GAME/re2_framework_log.txt"
grep -a 'TDB Version' "$GAME/re2_framework_log.txt"
grep -a '"buildid"' "$HOME/.local/share/Steam/steamapps/appmanifest_418370.acf"
```

---

## Verified REFramework Lua API

The whole project rests on this section. Rather than trusting documentation or memory, **every API
name used by this trainer was checked against the user's own installed `dinput8.dll`** — the actual
binary the game loads. Method:

```bash
GAME="$HOME/.local/share/Steam/steamapps/common/RESIDENT EVIL 7 biohazard"
strings -n 3 "$GAME/dinput8.dll" > dll_strings.txt

# exact whole-line match for a bare name:
grep -acx "on_frame" dll_strings.txt      # -> 1  means present
grep -acx "get_local_player" dll_strings.txt   # -> 0  means ABSENT
```

A count of `0` means the name does not appear in this build at all, and calling it would be an
error. Re-run these checks after any REFramework update.

### Callbacks — present

| Name | Used for |
|---|---|
| `re.on_draw_ui` | the trainer panel |
| `re.on_frame` | per-frame work, main thread |
| `re.on_script_reset` | dropping cached handles on reload |
| `re.on_config_save` | persisting preferences |
| `re.on_application_entry` | available; not currently used |
| `re.on_pre_application_entry` | available; not currently used |

### SDK — present

| Name | Notes |
|---|---|
| `sdk.get_managed_singleton` | primary route to game managers |
| `sdk.get_native_singleton` | available |
| `sdk.find_type_definition` | type lookup |
| `sdk.hook` | present; signature **not yet verified** — see below |
| `sdk.to_int64`, `sdk.to_float`, `sdk.to_double` | numeric normalisation |

### Type reflection — present

```
get_methods   get_fields    get_method     get_field      get_name
get_full_name get_parent_type  get_type   is_a           get_declaring_type
get_function  get_num_params   get_param_types  get_return_type
is_static     get_flags        get_type_definition     get_children
get_size      get_field
```

### Type reflection — ABSENT, must never be used

```
get_index   get_field_type   get_object_type   get_typename
get_types   get_num_fields   get_num_methods
```

### Support libraries — present

| Name | Notes |
|---|---|
| `log.info` / `log.warn` / `log.error` / `log.debug` | logging |
| `json.dump_file` / `json.load_file` | **the only route to disk** |
| `json.dump` / `json.load` | in-memory |
| `draw.text`, `draw.world_text`, `draw.filled_rect`, `draw.outline_rect`, `draw.line` | overlays |

### Support libraries — ABSENT

| Name | Consequence |
|---|---|
| `fs.*` | no filesystem API; `json.*` is the only way to write a file |
| `draw.screen_text` | use `draw.text` |

### Player / scene helpers — ABSENT

```
get_local_player   get_player   get_scene_manager   get_current_scene
get_game_directory get_game_dir  get_module_path    get_working_directory
```

**`sdk.get_local_player` does not exist in this build.** It is a newer REFramework API and is
frequently cited for other RE Engine titles. Do not use it here.

There is also **no game-directory accessor**, which is why the trainer cannot compute paths and
therefore ships as a single `package.preload` bundle — see [README](../README.md#why-the-installer-bundles-instead-of-copying-files).

### imgui — present

```
text   checkbox   button   same_line   separator   spacing   collapsing_header
tree_node   slider_int   slider_float   input_text   combo   progress_bar
push_id   pop_id   is_item_hovered   set_tooltip   begin_menu   menu_item
set_next_window_pos   set_next_window_size   set_next_item_width   is_key_pressed
is_key_down   is_key_released
```

### imgui — ABSENT

```
begin_child   bullet_text   colored_text
```

`begin_child` is commonly used for framed sub-panels and is **not available here**.
`colored_text` being absent is why the UI states status in plain text rather than with a coloured
dot — an indicator depending on a missing binding is worse than no indicator.

### Script loading — verified

How autorun scripts are found and how `require()` resolves was read out of `ScriptRunner.cpp` at
tag v1.5.9 and corroborated against the installed binary.

| Behaviour | Detail |
|---|---|
| Loader scope | `autorun/*.lua`, **non-recursive**. Subdirectories are ignored and their files are never auto-executed. |
| Load order | raw filesystem iteration order — **not sorted**. Do not depend on ordering between top-level scripts. |
| `package.path` | `reset_scripts()` appends `<autorun>/?.lua` and `<autorun>/?/init.lua` **before** running scripts |
| Module name mapping | dots in the `require` string become the platform separator, inserted at `?` |
| `re.on_script_reset` | fires during reset, after `on_config_save`, before the `lua_State` is destroyed |
| `re.on_config_save` | receives **no** config object; it is a notification only. There is no Lua-side `on_config_load` in this build. |

Binary corroboration — the `package.path` suffixes sit immediately after the `[ScriptState] Running
script {}...` string:

```bash
grep -n 'Running script\|^/?.lua$\|^/?/init.lua$\|^/?.dll$' dll_strings.txt
# 303609:[ScriptState] Running script {}...
# 303610:path
# 303611:/?.lua
# 303612:/?/init.lua
# 303613:/?.dll
```

**Consequence for this project:** the trainer installs a single top-level loader
(`autorun/re7trainer.lua`) and puts its modules in `autorun/re7trainer/`. The loader is the only
file auto-executed; the modules are pulled in by `require()`, which the framework's own
`package.path` setup makes resolve correctly.

### Object model — corrections that matter

The REManagedObject usertype does **not** expose the accessors it is commonly assumed to have. Verified
against the registration block in the installed binary (the sol2 names run contiguously at
`dll_strings.txt` lines 304706–304830, matching `src/mods/bindings/Sdk.cpp` at tag v1.5.9 line for line):

| Assumed | Reality |
|---|---|
| `obj:get_type()` | **does not exist** — use `obj:get_type_definition()` |
| `obj:get_method()` | **does not exist** — use `obj:call(name, ...)` or `obj:get_type_definition():get_method(name)` |
| `obj:get_name()` / `obj:get_full_name()` | **do not exist** — use `obj:get_type_definition():get_name()` |
| `obj:is_a("...")` | **does not exist on the object** — use `obj:get_type_definition():is_a(...)` |

`REManagedObject` in this build exposes: `get_type_definition`, `get_field`, `set_field`, `call`,
`get_address`, `get_object_size`, `get_reference_count`, `add_ref`, `release`, the raw `read_*`/`write_*`
pairs, and the `__index`/`__new_index` metamethods.

`RETypeDefinition:get_declaring_type` **does not exist** — that binding belongs to `REMethodDefinition`
and `REField`.

### Numeric conversion — only four helpers exist

```
sdk.to_int64   sdk.to_float   sdk.to_double   sdk.to_ptr
```

`to_sbyte`, `to_byte`, `to_int16`, `to_uint16`, `to_int32`, `to_uint32` **do not exist**. For a narrower
integer, mask the `to_int64` result.

### `get_methods()` is a FILTERED view — and this shapes the whole discovery procedure

`RETypeDefinition:get_methods()` is a custom binding that deliberately drops every method whose
`get_function()` is null, and every method whose code is still stub code.

RE Engine resolves managed methods lazily, on first call. **A method that has never been executed has a
null function pointer and therefore does not appear in the list at all.**

This is not a footnote. It means a dump taken from a freshly loaded save reports **zero methods for every
type**, while `get_parent_type()` still returns correct inheritance chains. That is exactly what the first
dump on this machine produced. The dump must be taken **after** the relevant gameplay has run — see
[DISCOVERY.md](DISCOVERY.md#running-the-discovery-dump).

Note the asymmetry: `get_method(name)` does **no** filtering and will return a descriptor for a method
`get_methods()` omits. So "it is not in the list" does not mean "it does not exist" — only that the engine
has not resolved it yet.

### `sdk.hook` — exact signature, from source

```lua
sdk.hook(method_definition, pre_callback, post_callback, ignore_jmp)
```

- **pre** receives **one** argument: a 1-indexed table of raw `void*` values.
  `args[1]` = `REThreadContext*`, `args[2]` = the `this` pointer, `args[3..]` = the parameters.
  **Mutating the table writes back to the real arguments.**
- Return `sdk.PreHookResult.SKIP_ORIGINAL` from pre to skip the original method.
- **post** receives one positional argument, `(void*)ret_val`. **Its return value replaces the original
  return value.**
- Any callback may be `nil`.

**Threading:** hooks run **synchronously on whatever game thread invoked the hooked method**, not on a
dedicated thread, and not on the main Lua thread. Access to the shared Lua state is serialized by a lock,
so callbacks never interleave — but each one **blocks the calling game thread**, meaning a slow hook
directly stalls the game. Keep hook bodies short; accumulate state and act in `re.on_frame`.

Hooks are silently bypassed during online play. Recursive hooks are warned about but not prevented.

### `sdk.get_managed_singleton` must be called fresh each time

It works by invoking the game's own static `get_Instance()`, which can legitimately return `nil`
mid-session — during a scene transition, a load, or while the owning system is rebuilt. **Never cache a
singleton pointer across frames.** `RETypeDefinition` objects, by contrast, are stable for the process
lifetime and are fine to cache.

### Master-only APIs — absent from this build

`refdocs.praydog.com` documents a newer REFramework than the one installed. All of these return `0` under
`grep -acx` against this binary and are **not present in v1.5.9**:

```
sdk.create_instance_global      sdk.create_userdata_global
RETypeDefinition:create_instance_gc_safe
```

The website also correctly confirms there is no `get_property`/`get_properties`/`get_derived_types`/
`get_attributes` API — property access goes through fields.

### Known unverified

| Item | Status |
|---|---|
| `sdk.hook` callback signature | present, but the exact pre/post argument shape is **not verified**. It must be read off the framework source for this tag before any hook is written. Getting this wrong is silent breakage. |
| Thread context of `on_draw_ui` vs `on_frame` | `on_frame` is assumed to be the main thread (the safe place to mutate game objects). Not proven. |
| Whether `imgui.is_key_pressed` works outside a draw callback | hotkeys are guarded and self-disable rather than assuming |
| Exact table holding the version accessors (`get_game_name`, `get_tag`) | probed across `re` / `reframework` / `sdk`, reported as unknown if absent |

---

## Startup detection

The trainer identifies its environment at load and reports it in the menu:

```
Status
    Framework: Loaded / NOT DETECTED
    Game:      <name, or "unknown">
    Trainer:   Ready / Initialising
```

If the SDK is unreachable, the trainer loads but **stays completely inert** and says so. It does not
attempt a reduced mode and it does not guess.

For any subsystem whose expected types are missing, the toggle renders as:

```
[ ] Infinite Health / God Mode  -- <reason>
```

rather than as a switch. The reason string is the specific failure — `"app.Item is not present in
this build"`, `"no inventory readable yet -- load into gameplay and try again"` — not a generic
message.

---

## When your build differs

REFramework updates and game updates both move these goalposts. If something stops working:

1. **Re-run the API presence checks** above. A name going from `1` to `0` is the fastest possible
   diagnosis.
2. **Check the TDB version** in the log. If it changed from `70`, the type database was rebuilt and
   the candidate type names may have moved.
3. **Re-run the discovery dump.** Member data is build-specific. Anything learned against build
   `22773795` should be re-checked against a new one rather than carried forward.
4. **Do not port an offset or a field index across builds.** This trainer deliberately stores none.
   A field index that was correct in one build silently points at different memory in another.

### TDB version history

| TDB version | Game build | Status |
|---|---|---|
| 70 | `22773795` | **verified — this is what the candidate lists were built against** |

If your TDB version is not 70, the candidate type lists in `src/discovery/explorer.lua` should be
treated as hypotheses. The discovery dump reports which of them are actually present, which is
exactly the information needed.

---

## What the trainer does not do

Stated plainly, because "it did not crash" is not the same as "it is supported":

- It does not write memory addresses.
- It does not use Cheat Engine or any external process.
- It does not use hardcoded offsets.
- It does not modify save files.
- It does not implement any cheat whose game API has not been verified.

See [DISCOVERY.md](DISCOVERY.md) for what is known and what remains outstanding.
