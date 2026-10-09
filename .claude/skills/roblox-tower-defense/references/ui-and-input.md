# UI and Input (cross-platform)

Sources: Creator Docs `ui/*`, `input/input-action-system.md`,
`production/game-design/ui-ux-design.md`, `projects/cross-platform.md`, API
reference (October 2026). Most Roblox players are on phones and tablets;
design for touch first, then mouse/keyboard and gamepad.

## Contents
1. UI structure
2. Layout that scales to every screen
3. Input: the Input Action System
4. Touch, mouse, gamepad specifics for TD
5. Feedback and juice
6. TD screens checklist
7. UI code organization

---

## 1. UI structure

- `ScreenGui`s live in `StarterGui` (copied to each player's `PlayerGui`)
  or are created by client code. Set `ResetOnSpawn = false` for HUDs that
  must survive respawns, `ZIndexBehavior = Sibling`, and `DisplayOrder` to
  stack screens (HUD < menus < modals < tutorial overlay).
- Safe areas: `ScreenGui.ScreenInsets` (e.g., `DeviceSafeInsets` for HUDs
  away from notches/top bar) and `ClipToDeviceSafeArea`;
  `GuiService.TopbarInset` gives the Roblox top-bar area to avoid.
- Core elements: `Frame`, `TextLabel`, `TextButton`, `ImageLabel`,
  `ImageButton`, `ScrollingFrame`, `ViewportFrame` (3D tower previews),
  `BillboardGui` (health bars over enemies), `SurfaceGui` (in-world signs,
  lobby boards).
- Modifiers: `UICorner`, `UIStroke`, `UIPadding`, `UIListLayout`,
  `UIGridLayout`, `UIFlexItem` (flex layouts), `UIScale`,
  `UIAspectRatioConstraint`, `UITextSizeConstraint`, `UIGradient`,
  `UIDragDetector`.

## 2. Layout that scales to every screen

- Position/size with **Scale** (fractions of the parent) for screen-relative
  layout, **Offset** (pixels) only for small fixed details; set
  `AnchorPoint` to the corner/edge you're aligning to.
- Lock shapes with `UIAspectRatioConstraint` (buttons, cards, icons).
- Use `TextScaled` with a `UITextSizeConstraint` max, or fixed sizes chosen
  per breakpoint; never let text overflow a button.
- Use layouts (`UIListLayout`, `UIGridLayout`, flex) instead of manual
  positions for lists (tower hotbar, shop grid).
- Test every screen in the **Device Emulator** at phone (portrait and
  landscape), tablet, desktop and console (10-foot) sizes.

## 3. Input: the Input Action System

The Input Action System (IAS) is fully released and is Roblox's recommended
way to bind actions across keyboard/mouse, gamepad and touch:

- `InputContext` — a group of actions (e.g., `MatchContext`,
  `MenuContext`); toggle with `.Enabled`; `Priority` and `Sink` decide
  which context consumes an input when several bind the same key.
- `InputAction` — one action (`PlaceTower`, `RotateTower`, `CancelPlacement`,
  `ToggleSpeed`). `Type`: `Bool` (press/release), `Direction1D`,
  `Direction2D` (camera pan), `Direction3D`, `ViewportPosition`.
  Events: `Pressed`, `Released`, `StateChanged`.
- `InputBinding` (children of the action) — one per device:
  `KeyCode` (e.g., `Enum.KeyCode.R`, `ButtonX`), composite `Up/Down/Left/
  Right` for WASD-style 2D, `UIButton` to bind an on-screen touch button,
  `Scale`, `PressedThreshold`.
- Build contexts in Studio (Input Action Manager, beta) under
  ReplicatedStorage or create them in code; connect handlers on the client.
- Set `Workspace.PlayerScriptsUseInputActionSystem = Enabled` so the
  default player scripts use IAS too (required for Server Authority).

`UserInputService` and `ContextActionService` still work (and existing
code uses them); `UserInputService.PreferredInput` tells you which input
style to show hints for (touch, keyboard/mouse, gamepad).

## 4. Touch, mouse, gamepad specifics for TD

- **Placement on touch**: no hover. Tap a tower card → ghost appears at
  screen center or under the finger → drag to position → explicit
  **Place** / **Cancel** buttons. Snap to grid and show valid/invalid
  color. Keep buttons ≥ ~44 px and away from the thumbstick/jump areas.
- **Placement on mouse**: ghost follows the cursor (raycast from
  `camera:ViewportPointToRay`), click to place, R to rotate, right-click or
  Esc to cancel, number keys 1–5 for the loadout.
- **Gamepad**: a virtual cursor or snapping between placement spots,
  shoulder buttons cycle towers, face buttons place/upgrade/sell; make
  every menu navigable with `GuiService.SelectedObject` and selection
  groups.
- **Camera**: top-down/isometric with pan (drag/right stick/WASD) and
  pinch/scroll zoom, clamped to the map bounds. Reset button.
- Selecting a placed tower opens its panel (upgrade, sell, targeting mode);
  tapping empty ground closes it.
- Show input-appropriate hints (key icons vs button icons) based on the
  preferred input.

## 5. Feedback and juice

- Every action responds instantly on the client (sound, button press
  animation, ghost snap) even before the server confirms; then reconcile
  (e.g., refund visual if the server rejected the placement).
- Cash popups on kills, damage numbers (optional, toggle in settings),
  hit flashes, death effects, wave start banner, boss warning, leak
  feedback (screen edge flash + base HP shake).
- Tween UI on the client (`TweenService`) — short (0.1–0.3 s), eased.
- Audio: separate `SoundGroup`s for music/SFX with volume settings saved
  in player data.

## 6. TD screens checklist

- HUD: cash, base HP, wave X/Y + countdown, speed toggle (1x/2x), skip
  wave / vote status, settings button.
- Tower hotbar (loadout) with icon, cost, placement count/limit, disabled
  state when unaffordable.
- Tower panel: name, level, owner, stats with upgrade deltas, upgrade cost,
  sell value, targeting mode selector.
- Wave preview (next enemies), boss health bar.
- Results screen: victory/defeat, waves survived, rewards, XP bar,
  "double rewards" ad offer, Play again / Lobby buttons.
- Lobby: play/queue panel (map, difficulty, party), inventory/loadout,
  shop (passes, products, skins, crates with odds), daily rewards, quests,
  codes, settings.
- Tutorial overlay (highlight + arrow + one-line instruction) that works on
  touch.
- Loading screen in `ReplicatedFirst` (`ReplicatedFirst:RemoveDefaultLoadingScreen()`
  then your own until assets/data are ready); keep it short.

## 7. UI code organization

- One client module per screen/panel with `mount()`, `update(state)`,
  `destroy()`; a small state store fed by server remotes; UI reads state,
  never decides game rules.
- Build UI in Studio (designer-friendly) and keep it in StarterGui/
  ReplicatedStorage, or build it in code. Libraries (React-lua, Fusion,
  Vide) help with large reactive UIs but aren't required.
- Localize strings (`LocalizationService` / auto-translation); avoid text
  baked into images.
