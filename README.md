# DeskKit — Deterministic Desktop Automation & Input Stack

**A complete, documented automation stack: uinput-level input injection, X11/XRecord hotkey listeners, phantom window filtering, 3-method window focus, Always-On-Top manipulation, and the 617 Browser (CEF4Delphi native browser) — all accessible programmatically via MCP.**

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [DeskKit Core](#deskkit-core)
- [Input Backends](#input-backends)
- [Hotkeys](#hotkeys)
- [Window Management](#window-management)
- [617 Browser](#617-browser)
- [Cognitive Operator](#cognitive-operator)
- [MCP Server](#mcp-server)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
- [Documentation Index](#documentation-index)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                   AI Agents (MCP)                       │
│         ┌───────────────────────────────────┐            │
│         │  mcp/deskkit-mcp.ts               │            │
│         │  Exposes deskkit.py tools as MCP  │            │
│         └────────────┬─────────────────────┘            │
└────────────────────┼────────────────────────────────────┘
                     │
┌────────────────────┴────────────────────────────────────┐
│                 deskkit.py (ContextDaemon)              │
│  ┌──────────────────────────────────────────────────┐   │
│  │  InputRouter  →  UinputBackend (tier-1)          │   │
│  │              →  XTestBackend   (tier-2 fallback) │   │
│  │              →  AT-SPI        (tier-3, live)     │   │
│  └──────────────────────────────────────────────────┘   │
│                                                            │
│  ContextDaemon — polls window state, maintains cache      │
│  /tmp/deskkit_context.json                                │
└──────────────────────────────────────────────────────────┘
         │                            │
         ▼                            ▼
  /dev/input/event*           X11 (xdotool, xprop)
  (uinput listener)           (xbindkeys, sxhkd)
```

---

## DeskKit Core

**Files:**
- `deskkit.py` — Core automation engine (21 tools)
- `atspi_resolve.py` — AT-SPI perception/action layer (focus resolution, honest action results)
- `bin/deskkit` — CLI wrapper for one-shot commands
- `bin/deskkitd` — Daemon launcher for persistent mode
- `_uinput_listener.py` — Standalone uinput-level hotkey listener

### Tool Inventory (21 tools)

| Tool | Backend | Description | Notes |
|------|---------|-------------|-------|
| `focus_window` | xdotool | Focus by title/class (activate/focus/above) | |
| `list_windows` | xdotool | All X11 windows (phantom-filtered) | |
| `get_active_title` | xdotool | Currently active window title | |
| `get_window_info` | xdotool | Active window details (pid, class, title) | |
| `get_window_geometry` | xdotool | Active window geometry (x, y, w, h) | |
| `resize_window` | xdotool | Resize active window W×H | |
| `get_cursor_pos` | xdotool | Current mouse X/Y coordinates | |
| `move_cursor` | uinput | Move mouse to absolute coordinates | |
| `click_at` | uinput | Click at X/Y (button 1/2/3) | |
| `type_text` | uinput | Type string character-by-character | |
| `send_keys` | uinput | Send key combos (ctrl+c, alt+tab) | |
| `clipboard_get` | xclip | Read clipboard | |
| `clipboard_set` | xclip | Write to clipboard | |
| `register_hotkey` | sxhkd | Register global hotkey | |
| `unregister_hotkey` | sxhkd | Remove registered hotkey | |
| `register_hotkey_x` | xbindkeys | Register X11-level hotkey | |
| `register_hotkey_uinput` | uinput | Register kernel-level hotkey | |
| `set_always_on_top` | xprop | Toggle `_NET_WM_STATE_ABOVE` | |
| `get_focused_element` | atspi ✅ | Focused AT-SPI node (role, name, interfaces, bus/path) | Live — bounded walk, ~0.3s |
| `atspi_click` | atspi ✅ | Invoke the focused node's default AccessibleAction | Needs a focused node exposing `Action` |
| `atspi_read_text` | atspi ✅ | Read text from the focused node | Needs a focused node exposing `Text` |

> **Regenerating this table:** this table is derived from `GET /tools` (from the running API server) cross-checked against the `TOOLS` registry in `deskkit.py`. To refresh, run `curl -s http://127.0.0.1:8642/tools` and compare against the `TOOLS = [...]` list in `deskkit.py` — the two are the canonical source.

---

## Input Backends

DeskKit uses three input backends in priority order:

### 1. Uinput (Tier-1, Unrefuseable)

Direct kernel input injection via `/dev/uinput`. Opens a virtual input device,
writes `input_event` structs (format `"=QQHHi"`, 24 bytes on 64-bit).

**Mouse events:** EV_REL (relX/relY) + BTN_LEFT/RIGHT/MIDDLE (272/274/273)
**Keyboard events:** EV_KEY with full keycode mapping

**Why `"=QQHHi"`:** Matches the kernel's `struct input_event`:
```c
struct input_event {
    struct timeval time;  // __u64 tv_sec, __u64 tv_usec (8+8 bytes on 64-bit)
    __u16 type;           // 2 bytes
    __u16 code;           // 2 bytes
    __s32 value;          // 4 bytes
};
```
The old format `"LLHHl"` assumed 32-bit `timeval` (incorrect on 64-bit Linux).

**Requirement:** User in `input` group:
```bash
sudo usermod -aG input $USER  # then re-login
```

### 2. XTEST (Tier-2, Fallback)

X11 XTEST extension via `xtest` command. Used when uinput unavailable.

### 3. AT-SPI (Tier-3, accessibility)

Perception **and** action over the accessibility bus. Gives DeskKit the one
thing pixels cannot: the identity of the focused widget (`role`, `name`,
available `interfaces`) without vision, OCR or a screenshot.

Three tools: `get_focused_element` (read), `atspi_read_text` (read text),
`atspi_click` (invoke the node's default `AccessibleAction`).

**How focus is resolved** (measured on this host, ~0.3 s per walk):
registry → active window (by pid) → bounded walk of each app tree. The old
code asked the bus for `org.a11y.atspi0` — a name nothing ever owns — so the
probe always reported "unavailable" and gated all three tools shut. The live
implementation walks the real `org.a11y.atspi.Registry`.

Resolution runs on a background thread (`start_background_refresh`), so the
20 Hz context loop never blocks on D-Bus. `atspi_click` reports success
**only when the action actually landed**; with no focused node it returns an
error that says so.

### Keyboard Keycode Mapping

| Key | keycode | Shift keycode | Notes |
|-----|---------|---------------|-------|
| a-z | 30-56 | — | Standard QWERTY |
| 0-9 | 11-20 | — | Number row |
| space | 65 | — | |
| enter | 36 | — | |
| esc | 9 | — | |
| tab | 23 | — | |
| backspace | 22 | — | |
| ctrl | 37 | — | |
| alt | 104 | — | |
| shift | 50 | — | |

---

## Hotkeys

DeskKit provides three independent hotkey registration methods:

### register_hotkey (sxhkd)

X11-level via `sxhkd` daemon (`/usr/bin/sxhkd`).
Config at `~/.config/sxhkd/sxhkdrc`.

### register_hotkey_x (xbindkeys)

X11-level via `xbindkeys` v1.85. Uses uppercase modifier names:
`Control`, `Shift`, `Mod4` (Super), `Mod1` (Alt).

**Key alias mapping:**
```
ctrl → Control
shift → Shift
alt → Mod1
super → Mod4
mod4 → Mod4
meta → Mod4
win → Mod4
```

Uses shared config: `/tmp/deskkit_hotkeys/xbindkeys_config`
Killed with `pkill -x xbindkeys` (exact name match — avoids killing self).

### register_hotkey_uinput (kernel-level)

Reads `/dev/input/event*` directly. Uses `/sys/class/input` for device name
resolution (no root needed for names).

**Device enumeration:**
1. List `/sys/class/input/` → map `eventN` → `device/name`
2. Filter for keyboard devices (name contains "kbd", "keyboard", "AT")
3. Spawn `_uinput_listener.py` with JSON config containing device paths

**Listener script:** `_uinput_listener.py`
- Opens pre-resolved event device paths (no ioctl needed)
- Reads 24-byte `input_event` structs (format `=QQHHi`)
- Tracks pressed keys in a `set()`
- When all combo keys pressed, fires `subprocess.Popen(command, shell=True)`
- Writes PID file to `/tmp/deskkit_hotkeys/{id}.pid`

---

## Window Management

### Phantom Window Filtering

X11 creates "phantom" windows with no WM_CLASS or _NET_WM_NAME. DeskKit filters
them in two places:

1. `list_windows()` — calls `xprop _NET_WM_NAME` + `WM_CLASS` on each match;
   windows returning "not found" are excluded.
2. `ContextDaemon.get_windows()` — same filter, populates daemon cache.

**Result:** 410 total windows → 88 real windows.

### Three Focus Methods

`focus_window` supports `method=auto/activate/focus/above`:

| Method | Mechanism | Reliability | Notes |
|--------|-----------|-------------|-------|
| `activate` | EWMH `_NET_ACTIVE_WINDOW` | ✅ Always works | Primary method |
| `focus` | X11 `XSetInputFocus` | ⚠️ BadMatch error | Window must be mapped+viewable first; use after `activate` |
| `above` | `_NET_WM_STATE_ABOVE` toggle | ✅ Works | Flips Always-On-Top to bring to front |

### Always-On-Top Manipulation

`set_always_on_top` uses `_NET_WM_STATE` with `xprop`:
- **on:** `xprop -f _NET_WM_STATE 32a -set _NET_WM_STATE ABOVE`
- **off:** `xprop -f _NET_WM_STATE 32a -set _NET_WM_STATE` (empty value clears all)
- **toggle:** Checks current state, flips

---

## 617 Browser

A native CEF4Delphi browser based on the Dual Citizen Browser project,
renamed and reconfigured for the 617 Browser codebase.

### Toolchain

| Component | Path | Status |
|-----------|------|--------|
| FPC | 3.2.2 | ✅ Installed |
| Lazarus | 4.4 | ✅ Installed |
| CEF4Delphi source | `<CEF4Delphi-source>/source/` | ✅ Present |
| libcef.so | `<CEF4Delphi-source>/cef_binary_131.4.1+g437feba+chromium-131.0.6778.265_linux64/Release/libcef.so` | ✅ Present |
| CEF4Delphi LPI package | `<CEF4Delphi-source>/packages/CEF4Delphi_Lazarus.lpk` | ✅ Present |

### Build

```bash
cd 617-browser/
lazbuild 617_browser.lpi            # GUI mode (windowed)
lazbuild 617_browser_headless.lpi   # Headless mode (Xvfb)
```

### Socket API

Both modes use Unix domain sockets for IPC:
- GUI: `/tmp/617_browser.sock` → `/tmp/617_control.sock`
- Headless: `/tmp/617_headless.sock` → `/tmp/617_control.sock`

**Protocol:** JSON over Unix socket. Commands:
```json
{"cmd": "navigate", "url": "https://example.com"}
{"cmd": "click", "x": 100, "y": 200}
{"cmd": "type", "text": "hello world"}
{"cmd": "get_source", "url": "https://..."}
{"cmd": "set_proxy", "proxy": "http://127.0.0.1:8080"}
{"cmd": "take_screenshot", "path": "/tmp/617_screenshot.png"}
```

### Files

| File | Lines | Description |
|------|-------|-------------|
| `ucontrollerbrowser.pas` | 1,000 | Main controller + CEF event handlers |
| `interfaces.pas` | — | CEF4Delphi interface implementations |
| `ucontrollerbrowser.lfm` | 109 | Form layout (toolbar, tabs, status) |
| `617_browser.lpr` | 53 | GUI entry point |
| `617_browser_headless.lpr` | 46 | Headless entry point (Xvfb) |
| `617_browser.lpi` / `617_browser_headless.lpi` | — | Lazarus project files |
| `SimpleBrowser.ico` | — | Application icon |

---

## Cognitive Operator

**File:** `docs/cognitive-operator.md`

Default skill for OpenClaw agents. Provides:
- Irrational timing (π/2, e, √2, φ, ln(2) delays — never whole numbers)
- Universal hotkey support (Copilot key + Windows key)
- Self-correction with φ-backoff scaling
- Fallback chains (AXPress → keyboard → focus)

**Usage:**
```bash
cognitive-action "click-element" --mode irrational --correct
cognitive-action "switch-app-2" --hotkey --key "win2"
```

---

## MCP Server

**File:** `mcp/deskkit-mcp.ts`

Exposes DeskKit tools via the Model Context Protocol, allowing any
MCP-compatible AI agent to use DeskKit for desktop automation — the same
way Hermes uses `computer-use-linux`.

### Installation

```bash
cd mcp/
npm install
npm run build
```

### Claude Desktop Config

```json
{
  "mcpServers": {
    "deskkit": {
      "command": "node",
      "args": ["/absolute/path/to/desk-kit/mcp/dist/deskkit-mcp.js"]
    }
  }
}
```

### Available Tools

All 21 DeskKit tools are exposed as MCP tools, with parameters
auto-discovered from the JSON schema in DeskKit's tool definitions.

---

## Quick Start

```bash
# 1. Clone and enter
cd <desk-kit-repo>

# 2. Start the daemon (runs as background context daemon)
python3 deskkit.py run &

# 3. Use tools via CLI
python3 deskkit.py list_windows
python3 deskkit.py get_cursor_pos
python3 deskkit.py send_keys "ctrl+t"
python3 deskkit.py focus_window "Firefox" method=activate
python3 deskkit.py register_hotkey "ctrl+shift+f" "firefox --search"
python3 deskkit.py set_always_on_top "Mousepad" on

# 4. Build the 617 Browser
cd 617-browser/
lazbuild 617_browser.lpi

# 5. Start 617 Browser (requires X11 display)
./617_browser  # or use headless mode

# 6. Set up MCP server for AI agents
cd ../mcp/
npm install && npm run build
```

---

## API Reference

### Context JSON (`/tmp/deskkit_context.json`)

```json
{
  "backends": {
    "uinput": true,
    "xtest": true,
    "atspi": true
  },
  "windows": [
    {"id": "0x123456", "title": "Firefox", "class": "firefox"},
    ...
  ],
  "cursor": {"x": 960, "y": 540},
  "screen": {"width": 1920, "height": 1080},
  "active_window": "Firefox"
}
```

### Hotkey Registration

```
register_hotkey <key_combo> <command>           # sxhkd (X11 level)
register_hotkey_x <key_combo> <command>         # xbindkeys (X11 level)
register_hotkey_uinput <key_combo> <command>    # kernel level (/dev/input)
```

Key combos: `ctrl+shift+f1`, `super+space`, `alt+tab`, etc.
Modifiers are normalized: `ctrl→Control`, `shift→Shift`, `super→Mod4`.

---

## Documentation Index

| Document | Path | Description |
|----------|------|-------------|
| Cognitive Operator | `docs/cognitive-operator.md` | Irrational timing + hotkey skill |
| Hotkey Arsenal | `docs/hotkey-arsenol.md` | Full hotkey reference (aliases, notation) |
| DeskKit Addition | `docs/desk-kit-addition.md` | Extended desk-kit-addition reference |
| Session Handoff | `docs/session-handoff-2026-10-01.md` | 2026-10-01 session summary |
| OpenClaw Profile | `profiles/openclaw/config.yaml` | OpenClaw agent profile config |
| 617 Browser | `617-browser/` | CEF4Delphi browser project |
| MCP Server | `mcp/deskkit-mcp.ts` | Model Context Protocol server |
| GitHub Actions | `.github/workflows/build.yml` | CI workflow |
