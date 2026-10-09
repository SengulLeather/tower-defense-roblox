# Tooling and Workflow

How code gets from files into Roblox, how to verify it, and how an AI
agent can drive Studio. Sources: Creator Docs (studio/mcp.md,
scripting/sync.md, ai/coding-harness.md, studio/command-line-interface.md,
cloud guides), tool repositories (versions as of October 2026).

## Contents
1. Identify the project setup first
2. Rojo + Rokit (file-first projects)
3. Studio Script Sync (Studio-first projects)
4. Packages: Wally / pesde
5. Formatting, linting, type checking
6. Unit tests with Lune
7. Studio MCP server (agent drives Studio)
8. Studio command line
9. Open Cloud: publish places, run Luau headlessly
10. Working from a cloud container (no Studio)
11. Assets, models, and the Creator Store
12. Git hygiene

---

## 1. Identify the project setup first

| You see | Setup | Source of truth |
|---|---|---|
| `default.project.json`, `rokit.toml`/`aftman.toml`/`foreman.toml` | Rojo | Files on disk (code); place file for models/maps unless they're in the project |
| `wally.toml` / `pesde.toml` | Package manager | `Packages/` is generated — don't edit |
| Folders named `ServerScriptService/`, `ReplicatedStorage/`, `StarterPlayerScripts/` with no project.json | Studio Script Sync | Studio place + synced scripts |
| Only a `.rbxl`/`.rbxlx` | Studio-only | The place file (binary `.rbxl` isn't diffable) |
| `selene.toml`, `stylua.toml`, `.luaurc` | Lint/format/type config | Follow them |

Read the README and CLAUDE.md, then mirror the existing module layout and
style instead of introducing a new framework.

## 2. Rojo + Rokit (file-first projects)

- **Rokit** pins tool versions in `rokit.toml`; `rokit install` installs
  them; `rokit add rojo-rbx/rojo@7.7.1` adds/updates one. (This repo pins
  Rojo 7.6.1, StyLua 2.4.0, selene 0.30.1, Wally 0.3.2; latest Rojo is
  7.7.1.)
- **Rojo** commands:
  - `rojo serve` — live-sync into Studio (Rojo plugin → Connect).
  - `rojo build -o Game.rbxl` — build a place file from the project (use
    in CI to prove the project tree is valid; can be published via Open
    Cloud).
  - `rojo sourcemap -o sourcemap.json` — for luau-lsp to resolve
    `script.Parent.X` requires.
  - `rojo init` — new project skeleton.
- `default.project.json` maps folders to Instances:

```json
{
  "name": "TowerDefense",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Shared": { "$path": "src/shared" },
      "Packages": { "$path": "Packages" }
    },
    "ServerScriptService": { "Server": { "$path": "src/server" } },
    "StarterPlayer": {
      "StarterPlayerScripts": { "Client": { "$path": "src/client" } }
    },
    "Workspace": {
      "$properties": { "StreamingEnabled": false },
      "Maps": { "$path": "assets/maps" }
    }
  }
}
```

- File mapping: `x.luau` → ModuleScript, `x.server.luau` → Script,
  `x.client.luau` → LocalScript, `folder/init.luau` turns the folder into a
  ModuleScript (same for `init.server.luau`/`init.client.luau`),
  `x.rbxm`/`x.rbxmx` → model, `x.model.json` → Instances described in
  JSON, `x.json` → ModuleScript returning the data, `x.txt` → StringValue,
  `init.meta.json`/`x.meta.json` → properties/attributes for the Instance.
- Properties in `$properties` use Rojo's JSON property format
  (`"Ambient": [0.39, 0.39, 0.39]`); attributes via
  `"$attributes"`.
- Things Rojo doesn't manage (maps built in Studio) stay in the place file
  you serve into; keep a copy of that `.rbxl` somewhere safe (it's
  gitignored) or export maps to `.rbxm` under `assets/`.

## 3. Studio Script Sync (Studio-first projects)

Built into Studio (beta: File → Beta Features → Script Sync). Right-click a
service/folder → **Sync to…** a directory; scripts become `.luau` files
that sync both ways. Up to 10,000 scripts per synced root, 128 roots.
Only Scripts, LocalScripts, ModuleScripts and Folders sync (no models,
attributes or tags — don't sync scripts that carry attributes/tags).
Naming: `x.server.luau` = Script (Server), `x.client.luau` = **Script with
RunContext Client** (not a LocalScript), `x.local.luau` = LocalScript,
`x.legacy.luau` = Legacy Script, `x.plugin.luau` = plugin script.
Works with Team Create; avoid two people editing the same synced file.
Verify a script's sync with
`game:GetService("InstanceFileSyncService"):GetStatus(instance)`.

Rojo vs Script Sync: Rojo when the filesystem should be the source of truth
(CI, code review, tests); Script Sync when the team lives in Studio and only
wants code in git. Don't mix both on the same scripts.

## 4. Packages: Wally / pesde

- `wally.toml` lists dependencies (`[dependencies]` shared,
  `[server-dependencies]` server-only); `wally install` creates
  `Packages/` and `ServerPackages/` — map them in `default.project.json`.
- Run `wally-package-types` (or use pesde, which handles types) so
  luau-lsp sees package types.
- Useful packages for a TD game: ProfileStore (data), a cleanup helper
  (Trove/Janitor), a signal implementation, optionally Blink/Zap
  (networking codegen — these are CLIs, not Wally packages), a UI library
  (React-lua, Fusion, Vide) if the UI is large. Keep dependencies few.

## 5. Formatting, linting, type checking

```sh
stylua --check src            # formatting (config: stylua.toml)
stylua src                    # fix formatting
selene src                    # lint (config: selene.toml; std = "roblox")
rojo sourcemap -o sourcemap.json
luau-lsp analyze --platform=roblox \
  --definitions=@roblox=globalTypes.d.luau \
  --sourcemap=sourcemap.json src   # strict type checking like Studio
```

- selene's `roblox` std is generated from Roblox's API dump on first run
  (needs network access to Roblox's CDN). In a sandbox without it, fall back
  to `std = "luau"` plus a small custom std YAML for the globals you use.
- luau-lsp's Roblox definitions file (`globalTypes.d.luau`) comes with the
  luau-lsp release/VS Code extension; pass it explicitly to `analyze`.
- `scripts/check.sh` in this skill runs whichever of these tools are
  installed and reports the ones that are missing.

## 6. Unit tests with Lune

[Lune](https://github.com/lune-org/lune) is a standalone Luau runtime.
Pure-logic modules (no services/Instances) can be tested without Studio:

```sh
lune run .claude/skills/roblox-tower-defense/templates/tests/run.luau \
         .claude/skills/roblox-tower-defense/templates
```

- `templates/tests/TestKit.luau` provides `test/eq/near/truthy/throws` and
  `TestKit.load(path)`, which compiles a module with Roblox datatypes
  (`Vector3`, `CFrame`, `Color3`, `Vector2` from `@lune/roblox`) injected,
  so modules can use idiomatic Roblox math.
- Copy the pattern into the game: `tests/` folder + a `run.luau`; keep
  game rules (damage, economy, wave generation, targeting, placement
  validation math) in pure modules so they're testable.
- Lune ≥ 0.10 supports the modern Luau syntax used here (interpolation,
  `continue`, `//`, `buffer`, `math.isfinite`) but not `const`.
- For tests that need Instances or services, run them inside Studio (via
  MCP `execute_luau`/`run_script_in_play_mode`, the Studio CLI, or Open
  Cloud Luau Execution). Roblox's Jest-Lua is an option for in-engine
  test suites.

## 7. Studio MCP server (agent drives Studio)

Roblox Studio has a **built-in MCP server**. Enable it in Studio: open
**Assistant** → `⋯` → **Manage MCP Servers** → **Enable Studio as MCP
server**; use **Quick connect** for Claude Code / Claude Desktop / Cursor /
VS Code / Codex / Gemini CLI, or configure manually:

```sh
# macOS
claude mcp add Roblox_Studio -- /Applications/RobloxStudio.app/Contents/MacOS/StudioMCP
# Windows (from cmd)
claude mcp add Roblox_Studio -- cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat
```

(The older standalone `Roblox/studio-rust-mcp-server` repo is archived;
use the built-in server.) It runs locally over stdio — it is only usable
when Claude runs on the same machine as Studio, not from a cloud container.

Tools (every call takes a `studio_id`; get it from `list_roblox_studios`):

| Group | Tools |
|---|---|
| Scripts | `script_read`, `multi_edit` (creates if missing), `script_search`, `script_grep` |
| Explore | `search_game_tree`, `inspect_instance`, `subagent` (`explore`, `playtest`) |
| Run code | `execute_luau` (datamodel `Edit`, `Server`, or `Client`) |
| Playtest | `get_studio_state`, `start_stop_play`, `get_console_output`, `screen_capture` |
| Input simulation | `character_navigation`, `user_keyboard_input`, `user_mouse_input` |
| Assets | `search_asset`, `insert_asset`, `generate_mesh`, `generate_material`, `generate_procedural_model`, `wait_job_finished`, `upload_image`, `store_image` |
| Docs | `http_get` (Roblox docs only), `skill` |

A productive agent loop with MCP:
1. `list_roblox_studios` → pick the instance; `search_game_tree` to learn
   the place (maps, folders, tags) before editing.
2. Edit code on disk (Rojo/Script Sync) or with `multi_edit`.
3. `start_stop_play` → wait → `get_console_output` for errors.
4. Drive the game: `execute_luau` on the **Server** datamodel to call debug
   hooks (start wave, give cash, spawn a boss), `user_mouse_input` to click
   UI, `screen_capture` to look at the result.
5. Stop play, fix, repeat. Clean up test instances you created.

Caution: MCP clients can modify the open place — save/commit first. Assets
from `search_asset`/`insert_asset` can contain scripts; inspect before
keeping them.

## 8. Studio command line

```sh
# Run a Luau script against a local place file and quit (smoke tests)
RobloxStudio --task RunScript --localPlaceFile "/abs/Game.rbxl" \
  --runScriptFile "/abs/smoke.luau" --outputFile out.log --quitAfterExecution
# Open a published place for editing
RobloxStudio --task EditPlace --placeId <id> --universeId <id>
# Dump the API (JSON)
RobloxStudio --api api.json
```

Executable: macOS `/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio`,
Windows `%localappdata%\Roblox\Versions\<version>\RobloxStudioBeta.exe`.
Scripts run with command-bar permissions (edit mode, not a live server).

## 9. Open Cloud: publish places, run Luau headlessly

Create an API key in Creator Hub (Open Cloud → API Keys) with only the
scopes/experiences needed; send it in the `x-api-key` header; keep it in a
CI secret or env var — never in the repo or in game code.

- **Publish a place file** (e.g., from `rojo build`):
  `POST https://apis.roblox.com/universes/v1/{universeId}/places/{placeId}/versions?versionType=Published`
  with body = the `.rbxl` (`Content-Type: application/octet-stream`) or
  `.rbxlx` (`application/xml`). Use `versionType=Saved` to upload without
  publishing.
- **Luau Execution** (headless test/automation on Roblox servers):
  create a task with `POST /cloud/v2/universes/{universeId}/places/{placeId}/luau-execution-session-tasks`
  (or `.../places/{placeId}/versions/{versionId}/luau-execution-session-tasks`
  to pin a version), with the script in the body; poll the task until it
  completes; read its return values and logs. Limits: up to 5 minutes per
  task, 10 concurrent tasks per place. DataStores in these tasks are the
  experience's real stores. Reference implementation:
  `github.com/Roblox/place-ci-cd-demo`. Check the Luau Execution API
  reference for the exact request/response schema before scripting it.
- Other Open Cloud APIs: data stores, memory stores, messaging, assets,
  configs, experience notifications, secrets.

## 10. Working from a cloud container (no Studio)

When Claude runs in a remote container (like Claude Code on the web), there
is no Studio, no MCP connection, and usually no Roblox network access.
What still works:
- Writing code; `stylua`, `selene` (with a fallback std), `luau-lsp
  analyze` (with the definitions file), `rojo build` (validates the
  project tree), Lune unit tests.
- If the user provides an Open Cloud API key as a secret: publishing and
  Luau Execution.

Be explicit with the user about what was verified (format, lint, types,
unit tests, build) and what still needs a Studio playtest, and give them a
short manual test script (what to click, what they should see, what the
output should print).

Installing tools in a container without Rokit downloads: StyLua via npm
(`npm i @johnnymorganz/stylua-bin@<version>`), selene and Lune via
`cargo install` (selene from its git tag if the crates.io version lags),
luau-lsp by building from source with CMake (use clang if GCC's
`-Werror` trips).

## 11. Assets, models, and the Creator Store

- Build maps and models in Studio (parts, MeshParts, unions); keep the
  part count reasonable; anchor static geometry.
- Upload meshes/images/audio via Studio's Asset Manager or the Open Cloud
  Assets API; reference them by `rbxassetid://<id>`.
- **Free models are a security risk**: they can contain hidden scripts
  (`require(<assetId>)` backdoors, obfuscated code). Search inserted
  models for Script/LocalScript/ModuleScript descendants and remove what
  you don't understand.
- Use **Packages** to share models (tower models, UI) between the lobby
  and match places; update once, propagate everywhere.
- Audio and images uploaded by you are private to your experiences unless
  shared; asset permissions matter when a group owns the game.

## 12. Git hygiene

- Commit source (`src/`, project files, configs, tests). Ignore built
  places (`*.rbxl`, `*.rbxlx` unless intentionally tracked as XML),
  `Packages/`, `sourcemap.json`, local tool caches.
- Never commit API keys, webhook URLs, or `.ROBLOSECURITY` cookies.
- Keep generated IDs (game pass/product IDs, place IDs) in one config
  module; they are not secrets.
