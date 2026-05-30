# ReBar

**Percentage text overlays for the World of Warcraft Personal Resource Display (PRD).**

ReBar adds clean, readable percentage numbers on top of the health, power, and class/alternate resource bars that float beneath your character. It is intentionally small and focused — no menus you'll never use, no libraries, no bloat. Just percentages where you want them.

- **Game version:** World of Warcraft `12.0.5`
- **Dependencies:** None
- **Footprint:** A single Lua file, no embedded libraries

---

## Features

- Percentage text on the **health**, **power** (mana / energy / rage / focus / etc.), and **alternate / class resource** bars of the Personal Resource Display.
- **Fully click-through.** The overlays never intercept mouse input, so the PRD behaves exactly as it did before.
- **Lightweight and constant-cost.** ReBar only ever reads your *own* PRD bars. It never iterates party or raid members, so its cost is identical whether you are solo or in a 40-player raid.
- **Resilient on boss encounters.** Reads gracefully degrade when the game returns protected values, so the addon never errors during fights (see [Notes on "secret" values](#notes-on-secret-values)).
- **Simple in-game options panel** for toggling each bar, adjusting font size, and enabling debug output.
- **Login confirmation** message that tells you the addon loaded and reminds you of the slash command.

---

## Installation

1. Download the latest release.
2. Extract it so the folder lands in your AddOns directory:
   ```
   World of Warcraft/_retail_/Interface/AddOns/ReBar/
   ```
   The folder must contain `ReBar.toc` and `ReBar.lua`.
3. Restart the game, or reload your UI with `/reload`.
4. On login you will see a confirmation in chat:
   > `[ReBar] v3.3 loaded.  /rebar options   /rebar debug diagnose`

> **Note:** The Personal Resource Display must be enabled in-game for ReBar to have bars to overlay. You can turn it on under **Options → Combat → Personal Resource Display**.

---

## Usage

ReBar works automatically once installed — the percentages appear on your resource bars with no setup required.

### Slash commands

| Command | Description |
| --- | --- |
| `/rebar` | Open or close the options panel. |
| `/rebar debug` | Toggle debug mode and print diagnostic information to chat. |
| `/rebar scan` | Force the addon to re-locate the resource bars (rarely needed). |

### Options panel

The panel (`/rebar`) lets you:

- Enable or disable ReBar entirely.
- Toggle the percentage on the **Health**, **Power**, and **Alternate / Class** bars independently.
- Adjust the **font size**.
- Turn **debug mode** on or off.

---

## How it works

ReBar attaches a small text overlay to each of the Personal Resource Display's bars.

### Frame paths

The addon locates the bars through the game's Personal Resource Display frame:

| Bar | Frame path |
| --- | --- |
| PRD container | `PersonalResourceDisplayFrame` |
| Health | `PersonalResourceDisplayFrame.HealthBarsContainer.healthBar` |
| Power | `PersonalResourceDisplayFrame.PowerBar` |
| Alternate power | `PersonalResourceDisplayFrame.AlternatePowerBar` |

### Overlay model

Each overlay is a child frame parented directly to its bar, placed one frame level above it, with a single font string for the text. There are no strata overrides, no reparenting to `UIParent`, and no screen-coordinate math — the overlay simply tracks its parent bar.

The overlay reference is stored on the bar itself (for example, `bar.ReBarOverlay`). This means that when ReBar re-checks the bars, it updates the existing overlay in place rather than destroying and recreating frames, which keeps things efficient and avoids error churn.

---

## Notes on "secret" values

In some encounters the game returns protected ("secret") values from `UnitHealthPercent` and `UnitPowerPercent`. ReBar handles this safely:

- All value reads are protected so they cannot throw errors.
- When a precise percentage is available, it is used.
- When a value is protected and unusable, ReBar falls back to standard ratio math, and if even that is unavailable for a given update, the text simply isn't refreshed that tick instead of producing an error.

Because ReBar is display-only, this degradation is harmless — at worst, a number momentarily stops updating during specific boss mechanics.

---

## Compatibility

- Built and tested for World of Warcraft **12.0.5**.
- Uses only current, non-deprecated interface APIs.
- No external libraries are bundled or required.

---

## License

See the `LICENSE` file in this repository.

---

## Coding disclosure

This project was entirely vibe coded using Claude Opus 4.8. The addon — including its frame discovery, overlay logic, options panel, and documentation — was developed iteratively in conversation with the model rather than hand-written line by line.
