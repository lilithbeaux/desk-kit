---
name: deskkit
license: MIT
description: Contextually-Aware Deterministic Desktop Automation Tool Suite — uinput input injection, hotkey listeners, phantom window filtering, 3-method focus, Always-On-Top, and MCP server for AI agent access.
metadata:
  author: lilareyon
  version: "1.0"
  tags: ["automation", "desktop", "uinput", "linux", "x11", "hotkeys", "mcp", "computer-use"]
  categories: ["automation", "computer-use", "desktop"]
  requires: ["xdotool", "xprop", "xclip", "xbindkeys", "sxhkd", "/dev/uinput"]
  python_deps: []  # No external Python deps; uses stdlib + ctypes
  node_deps: ["@modelcontextprotocol/sdk"]
  related_skills: ["cognitive-operator", "desktop-hotkeys", "agent-computer-use"]
---

## When to Use

Use when you need deterministic desktop automation on Linux X11 with:
- **uinput-level input** (unrefuseable by any userspace app)
- **Three independent window focus methods**
- **Three-tier hotkey registration** (sxhkd, xbindkeys, kernel-level)
- **Phantom window filtering** (removes 300+ X11 ghost windows)
- **Always-On-Top light-switch manipulation**

## Quick Reference

### Start the daemon
```bash
python3 deskkit.py run &
```

### List available tools
```bash
python3 deskkit.py list_tools
```

### Execute a tool
```bash
python3 deskkit.py focus_window "Firefox" method=auto
python3 deskkit.py send_keys "ctrl+t"
python3 deskkit.py type_text "hello world"
python3 deskkit.py register_hotkey "super+space" "rofi -show drun"
python3 deskkit.py set_always_on_top on
python3 deskkit.py click_at 500 500
```

### Via MCP (any AI agent)

Add to Claude Desktop config (`claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "deskkit": {
      "command": "node",
      "args": ["/abs/path/to/desk-kit/mcp/dist/deskkit-mcp.js"],
      "env": { "DESKKIT_PY": "/abs/path/to/desk-kit/deskkit.py" }
    }
  }
}
```

Then any MCP client can call: `list_windows`, `focus_window`, `click_at`,
`send_keys`, `type_text`, `register_hotkey`, `set_always_on_top`, etc.

## Architecture

```
InputRouter (tiered selection)
  ├── UinputBackend  (tier-1: /dev/uinput, UNREFUSEABLE)
  ├── YdotoolBackend (tier-2: ydotool daemon)
  └── XTestBackend   (tier-3: xdotool XTEST, fallback)

ContextDaemon (polls at 50ms, writes /tmp/deskkit_context.json)
  ├── get_active_window()   (xdotool + xprop)
  ├── get_cursor_pos()      (xdotool)
  ├── get_clipboard()       (xclip/xsel)
  ├── get_windows()         (xdotool + xprop WM_CLASS filter — phantom trimming)
  ├── detect_input_backends()  (probes /dev/uinput, xdotool, dbus AT-SPI)
  └── detect_atspi_focus()  (dbus AT-SPI GetFocus)
```

## Tool Contracts

Each tool self-declares context requirements via `"requires"` predicates.
The dispatcher only offers tools whose contracts are satisfied by the
current `/tmp/deskkit_context.json` state. A 2B model can drive this because:
- Context predicates are human-readable JSON paths
- Tools return deterministic structured output
- No free-text parsing required

## Requirements

- Linux (X11)
- Python 3.10+ (stdlib only — no pip deps)
- xdotool, xprop, xclip/xsel
- /dev/uinput access (add user to `input` group: `sudo usermod -aG input $USER`)
- xbindkeys (for X-level hotkeys)
- sxhkd (for sxhkd-level hotkeys, optional)
