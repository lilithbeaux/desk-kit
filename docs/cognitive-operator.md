---
name: cognitive-operator
license: MIT
description: Irrational timer / hotkey skill for OpenClaw agents.
metadata:
  author: Hermes Agent
  version: "2.1"
  tags: ["cognitive", "keyboard-shortcuts", "hotkeys", "irrational-timing", "openclaw"]
  categories: ["productivity", "automation", "computer-use"]
  related_skills: ["agent-computer-use", "deskkit", "desktop-hotkeys"]
---

## When to Use
Use when an OpenClaw agent needs to operate desktop applications with irrational timing, universal hotkey support, and self-correction. Default for all OpenClaw agents.

# Enhanced Cognitive Operator (v2.1) — OpenClaw Default Skill

Assigned by default to all OpenClaw agents. Provides irrational mathematical-timer patterns, universal hotkey support (Microsoft Copilot + Windows), and intelligent self-correction.

## Features

### 🌉 Irrational Timing System (No Whole Numbers)
Uses mathematical constants for delays:
- `π / 2` → verification pulse (~1.57s)
- `e` → adaptive backoff (~2.72s)
- `√2` → rapid sequences (~0.14s)
- `φ` (Golden Ratio) → graceful recovery (~1.62s)
- `ln(2)` → cursor adjustments (~0.69s)

No `sleep(2)` or `sleep(3)` — all delays are irrational.

### ⌨️ Universal Hotkey Support
- **Copilot**: `Win+Search`, `Win+Enter`, `Win+Shift+C`
- **Windows System**: `Win+Escape`, `Win+F`, `Win+I`, `Win+L`, `Win+Tab`
- **App Switch**: `Win+1/2/3`
- **Window**: `Win+F4` (close), `Win+Shift+M` (maximize), `Win+Shift+P/V` (tile)
- **Clipboard**: `Win+C/V/X`
- **Screenshot**: `Win+Shift+S`
- **Workspaces**: `Win+PageUp/Down`

### 🧠 Self-Correction
- Auto-retry with `φ`-backoff scaling
- Smart state verification (stale refs detected)
- Knowledge-based fallback (AXPress → keyboard → focus)

### Integration Points
- `desk-kit-addition.txt` on Desktop — full reference
- Works with `agent-computer-use` / `deskkit` infrastructure
- Uses `UinputBridge` for fallback
- Light dependencies (core + bridge only)

## Usage (For All OpenClaw Agents by Default)
```bash
# Irrational action with correction
cognitive-action "click-element" --mode irrational --correct

# Hotkey mode
cognitive-action "switch-app-2" --hotkey --key "win2"

# Full enhancement (recommended)
cognitive-action "work-flow" --irrational --hotkey --correct

# View timing patterns
cognitive-action "timing-info" --constant "phi"

# Monitor
cognitive-action "timing-metrics"
```

## Key Principles (Built-in Constraints)
1. **No Whole Number Delays** — Always use mathematical constants
2. **Universal Hotkeys** — Copilot key + Windows key fully supported
3. **Self-Correcting** — Retries with intelligent backoff (φ-scaling)
4. **Less Dependencies** — Uses existing agent-computer-use / deskkit bridge
5. **Pitfall Workarounds** — Fallback for stale refs, missing elements, focus issues
6. **Versatile** — Works with openclaw, uniharness, and any harness that supports CLI

## Notes for Agent Harness Integration
- Skill is loaded by default for all OpenClaw agents
- Configure in `~/.hermes/profiles/openclaw/config.yaml`
- Full reference: `~/Desktop/desk-kit-addition.txt`
- The Copilot key (`Windows+Search` etc.) is appropriate — it is the designated AI-assistance key
- No additional routers needed; uses existing `agent-computer-use` / `UinputBridge`

This takes the DeskKit / automation project into its upper operating envelope — irrational, unpredictable, self-correcting, and fully harnessed.
