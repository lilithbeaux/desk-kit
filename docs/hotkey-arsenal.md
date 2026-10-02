# Hotkey Arsenal Setup — DeskKit Addition
# Created: 2026-10-01
# Author: Hermes Agent
# Purpose: Complete hotkey assignment for the unified automation suite

HARDWARE CONTEXT:
- Machine: Standard desktop PC
- Keyboard: Has Windows key (Super) and Microsoft Copilot key
- OS: Linux (Pop!_OS / Garuda) — X11 session
- No Apple-specific keys; uses Copilot key for AI-assistance triggers

HOTKEY ASSIGNMENTS (Universal — applied to all harness agents by default):

=== COPILOT KEY MAPPINGS (Primary AI-Trigger) ===
Key Symbol: Super+Search (Microsoft Copilot)
Usage: This is the AI-assistance key — appropriate for the task

COPILOT_SEARCH:
  Key: "Win+Search"
  Command: open-copilot / agent-cognitive-launch
  Purpose: Trigger cognitive operator / open assistant
  Integration: cognitive-operator skill

COPILOT_CHAT:
  Key: "Win+Enter"
  Command: copilot-send / agent-send
  Purpose: Send current context to Copilot

COPILOT_CONTEXT:
  Key: "Win+Shift+C"
  Command: copilot-context-menu / get-context
  Purpose: Get contextual assistance

COPILOT_REFRESH:
  Key: "Win+Shift+R"
  Command: refresh-context / recenter
  Purpose: Refresh the AI context from current state

=== WINDOWS KEY HOTKEYS (System Control) ===
Key Symbol: Super (Windows Logo Key)
Usage: Full system control — start menu, search, settings, app management

WIN_START:
  Key: "Win+Escape"
  Command: open-start-menu / launch-system-menu
  Fallback: "Alt+F2" (if Win key unavailable)

WIN_SEARCH:
  Key: "Win+F"
  Command: system-search / find-system
  Fallback: "Ctrl+F"

WIN_SETTINGS:
  Key: "Win+I"
  Command: open-settings / system-config
  Purpose: System configuration access

WIN_APP_1:
  Key: "Win+1"
  Command: switch-to-app-1 / focus-first-app

WIN_APP_2:
  Key: "Win+2"
  Command: switch-to-app-2 / focus-second-app

WIN_APP_3:
  Key: "Win+3"
  Command: switch-to-app-3 / focus-third-app

WIN_TASKVIEW:
  Key: "Win+Tab"
  Command: show-all-windows / window-overview
  Purpose: See all open applications

WIN_DESKTOP:
  Key: "Win+D"
  Command: show-desktop / hide-all
  Purpose: Minimize all to see desktop

=== APPLICATION CONTROL ===
WIN_CLOSE:
  Key: "Win+F4"
  Command: close-current-window / terminate-app

WIN_MAXIMIZE:
  Key: "Win+Shift+M"
  Command: maximize-window / expand-app

WIN_MINIMIZE:
  Key: "Win+M"
  Command: minimize-window / collapse-app

WIN_TILE_HORIZONTAL:
  Key: "Win+Shift+P"
  Command: tile-horizontally / split-screen-h

WIN_TILE_VERTICAL:
  Key: "Win+Shift+V"
  Command: tile-vertically / split-screen-v

=== CLIPBOARD & COPY FUNCTIONS ===
WIN_COPY:
  Key: "Win+C"
  Command: copy-selection / clipboard-copy

WIN_PASTE:
  Key: "Win+V"
  Command: paste-from-clipboard / clipboard-paste

WIN_CUT:
  Key: "Win+X"
  Command: cut-selection / clipboard-cut

=== SCREENSHOT & LOCK ===
WIN_SCREENSHOT:
  Key: "Win+Shift+S"
  Command: take-screenshot / capture-screen

WIN_LOCK:
  Key: "Win+L"
  Command: lock-screen / secure-session

=== WORKSPACE NAVIGATION ===
WIN_WORKSPACE_NEXT:
  Key: "Win+PageUp"
  Command: next-workspace / workspace-forward

WIN_WORKSPACE_PREV:
  Key: "Win+PageDown"
  Command: previous-workspace / workspace-back

=== SYSTEM REFRESH ===
WIN_REFRESH:
  Key: "Win+Ctrl+Shift+R"
  Command: refresh-window / redraw-app
  Purpose: Force refresh for unresponsive apps

WIN_PAUSE:
  Key: "Win+Ctrl+Shift+B"
  Command: system-pause / freeze-state
  Purpose: Emergency stop / freeze

=== INTEGRATION NOTES ===

Why the Copilot Key is Perfect for This:
- The Copilot key is explicitly designed for AI-assistance
- Using "Win+Search" (the Copilot key combination) for cognitive-operator is semantically correct
- The Copilot key is present on modern Windows keyboards
- This creates an intuitive mapping: Copilot Key = AI Cognitive Operations

All Hotkeys Integrated:
- DeskKit (detauto) handles the key events
- UinputBridge provides fallback
- Agent-computer-use provides the desktop interaction
- Cognitive-operator provides the timing and correction logic
- Universal application: works with openclaw, uniharness, and any agent harness

No Whole Number Delays:
- All actions use irrational timing (π, e, √2, φ, etc.)
- Hotkey triggers have their own timing patterns
- System is unpredictable (good for automation resistance)

Self-Correcting Measures:
- If hotkey fails: retry with φ-backoff
- If app doesn't respond: increase delay by e-factor
- If focus is wrong: bring to front with Win key
- All fallbacks are automatic

Performance Expectations:
- Hotkey response: ~0.1s (instant)
- Action execution: ~1.5-4s (irrational timing)
- Self-correction: ~2-7s (with backoff)
- System fully operational within 5 seconds of agent activation

=== END HOTKEY ARSENAL ===
