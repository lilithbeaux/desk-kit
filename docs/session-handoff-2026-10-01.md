# SESSION HANDOFF — 2026-10-01
## DeskKit + Cognitive Operator + UI-TARS Deployment

---

## 🎯 EXECUTIVE SUMMARY

**DeskKit is the CUA driver alternative — vision-free, AT-SPI2-native, hotkey-driven, irrational-timed, self-correcting.**

This session:
- ✅ Killed unauthorized router (poolside/laguna-s-2.1 on OpenRouter)
- ✅ Confirmed **UI-TARS-1.5-7B running on :8080** (your model, ready to test)
- ✅ Verified **agent-cu is BROKEN** (returns no apps/windows despite active desktop)
- ✅ Created **cognitive-operator skill** with irrational timers + universal hotkeys
- ✅ Configured **OpenClaw profile** with full hotkey arsenal (Copilot + Windows keys)
- ✅ Documented **clipboard "clip" system** (held per user request)
- ✅ Established: **DeskKit > CUA driver** (user's architecture decision)

---

## 📍 CURRENT STATE (AS OF HANDOFF)

### Model Infrastructure
| Port | Model | Process | Status |
|------|-------|---------|--------|
| **8080** | **UI-TARS-1.5-7B.IQ4_XS** | `llama serve --alias tars` (PID 3162797) | ✅ **RUNNING — YOUR MODEL** |
| 8773 | — | — | 🚫 NOT LISTENING |
| 8091/8092/8093 | — | — | 🚫 NOT LISTENING |
| External | poolside/laguna-s-2.1 | tui_gateway slash_worker | 💀 **KILLED** |

**Only authorized model: UI-TARS on :8080**

### Desktop Environment
- **Display**: :0.0 (X11 active)
- **AT-SPI**: `/run/user/1000/at-spi/bus` — **RUNNING**
- **UInput**: `/dev/uinput` (crw-rw-rw-) — **ACCESSIBLE**
- **DeskKit (detauto)**: 19 tools registered, build clean (FPC 3.2.2), uinput bridge integrated

### Broken Tools
- **agent-cu 0.1.0**: Returns `[]` for `apps` and `windows` — **ENUMERATION FAILURE**, not environment failure
- **CUA Driver**: Distinct from agent-computer-use; Hermes's AT-SPI2 bridge (low-level)
- **DeskKit**: User's designated replacement — vision-free, hotkey-driven, AT-SPI2-native

---

## 🧠 COGNITIVE OPERATOR SKILL (Created)

**Location**: `~/.hermes/skills/cognitive-operator/`
**Description**: "Irrational timer / hotkey skill for OpenClaw agents."
**Version**: 2.1

### Irrational Timing System (NO WHOLE NUMBERS)
```python
# Mathematical constants only
π  = 3.141592653589793
e  = 2.718281828459045
√2 = 1.4142135623730951
φ  = 1.618033988749895
ln2 = 0.6931471805599453

# Timing patterns (all irrational)
τ_init      = π / 2       # ~1.57s (verification)
τ_load      = e * 0.5     # ~1.36s (app loading)
τ_rapid     = √2 * 0.1    # ~0.14s (quick sequences)
τ_recovery  = φ * 0.3     # ~0.48s (post-failure)
τ_final     = π * 0.7     # ~2.20s (grace periods)
```

### Self-Correction
- **Strategy**: φ-backoff (scale by golden ratio on retry)
- **Max retries**: 5
- **Stale ref detection**: Enabled
- **State verification**: Enabled
- **Fallbacks**: Keyboard simulation, Win-key activation, uinput bridge

### Hotkey Arsenal (Universal — All Harness Agents)
```yaml
# COPILOT KEY (Primary AI Trigger — Semantically Perfect)
Win+Search:       open-copilot / agent-cognitive-launch
Win+Enter:        copilot-send / agent-send
Win+Shift+C:      copilot-context-menu / get-context
Win+Shift+R:      refresh-context / recenter

# WINDOWS KEY (System Control)
Win+Escape:       open-start-menu
Win+F:            system-search
Win+I:            open-settings
Win+Tab:          show-all-windows
Win+D:            show-desktop
Win+L:            lock-screen
Win+1/2/3:        switch-to-app-1/2/3
Win+F4:           close-window
Win+Shift+M:      maximize
Win+M:            minimize
Win+Shift+P:      tile-horizontal
Win+Shift+V:      tile-vertical
Win+C/V/X:        copy/paste/cut
Win+Shift+S:      screenshot
Win+PageUp/Down:  workspace next/prev
Win+Ctrl+Shift+R: refresh-window
Win+Ctrl+Shift+B: system-pause (emergency stop)
```

---

## ⚙️ OPENCLAW PROFILE CONFIGURATION

**Location**: `~/.hermes/profiles/openclaw/config.yaml`

### Default Skills (Auto-loaded)
```yaml
required:
  - deskkit
  - agent-computer-use
  - cognitive-operator    # ← IRRATIONAL TIMING + HOTKEYS
```

### Cognitive Operator Config
```yaml
cognitive:
  timing:
    mode: "mathematical"
    constants: { pi, e, sqrt2, phi, ln2 }
  correction:
    enabled: true
    strategy: "phi-backoff"
    max_retries: 5
  fallback:
    keyboard_simulation: true
    win_key_activation: true
    uinput_bridge: true

hotkeys:
  enable_copilot_key: true
  copilot_key_combos:
    default: "Win+Search"
  fallback_enabled: true
  verify_focus: true
```

---

## 📋 DESKKIT STATUS (User's CUA Driver Alternative)

**From user's update + session review:**
- **Build**: Clean (FPC 3.2.2, 0 errors)
- **Tools**: 19 registered
- **UInput Bridge**: Integrated in `detauto_input.pas`
- **Config**: `UseUinput`, `DeskKitPath` in `detauto_config.pas`
- **Diagnostics**: `detauto_doctor.pas` (comprehensive)
- **Goal Filtering**: `--goal` flag works
- **Backup**: `automation-suite.bak.2026-10-01`

**Key files updated:**
- `detauto_input.pas` — UInput bridge implementation
- `detauto_config.pas` — Configuration with UseUinput/DeskKitPath
- `detauto_doctor.pas` — Diagnostic suite
- `detauto.lpr` — Main entry with --goal support
- `README.md` — Updated documentation

**DeskKit is the vision-free, hotkey-driven, AT-SPI2-native automation suite.**

---

## 🗂️ CLIPBOARD "CLIP" SYSTEM (Documented, Held Per Request)

**Concept**: Turn copy into "clip" (ammunition), paste into "semi-automatic rifle"

### Core Structure
```yaml
clip_blocks:
  block_1:
    content: "12-step AA sequence"
    length: 12240
    markers: ["@step:setup", "@step:auth", "@step:verify", ...]
    max_pastes_per_step: 3      # Uses step 1 three times before step 2
    mode: "cursor"              # "shed" = discard, "cursor" = persist
    universal_steps: false       # Per-block or universal
```

### Modes
- **Shed**: Discard step after paste (single-use)
- **Cursor**: Persist step for repeated cursor-based selection

### Commands (Ready for Implementation)
```bash
cognitive-action "register-clip-block" --content "..." --markers "@step:..." --max-pastes-per-step 3 --mode cursor
cognitive-action "paste-step" --block-id block_1 --step-number 1
cognitive-action "toggle-clip-mode"
cognitive-action "adjust-paste-rate" --block-id block_1 --new-rate 5
cognitive-action "clipboard-status"
cognitive-action "remove-clip-block" --block-id block_1
```

**Status**: Fully designed, documented in `~/Desktop/desk-kit-addition.txt` and `~/Desktop/hotkey-arsenal.txt`. **HELD** per user request.

---

## 🔴 AGENT-CU — CONFIRMED BROKEN

```bash
$ agent-cu apps    # Returns: [] (3 chars)
$ agent-cu windows # Returns: [] (3 chars)
```

**Environment is healthy:**
- DISPLAY=:0.0 ✅
- X11 socket: /tmp/.X11-unix/X0 ✅
- AT-SPI bus: /run/user/1000/at-spi/bus ✅
- /dev/uinput: crw-rw-rw- ✅

**Conclusion**: agent-cu has **desktop enumeration failure** — tool-specific bug, not environment issue.

**User's frustration with poolside/laguna-s-2.1 clash over this is validated.**

---

## 🎯 CRITICAL DISTINCTIONS (User Emphasized)

| System | What It Is | Status |
|--------|------------|--------|
| **CUA Driver** | Hermes's AT-SPI2/accessibility bridge (low-level) | Working on :8773 (was) |
| **agent-computer-use** | Rust CLI (`agent-cu`) using accessibility APIs | **BROKEN** (no apps/windows) |
| **DeskKit** | User's vision-free, hotkey-driven, AT-SPI2-native suite | **PRIMARY — "Better than CUA driver"** |

**User's words**: "Desk kit is supposed to be the thing better than cua driver" and "cua driver and agent-computer-use are nothing close to the same thing"

---

## 📁 FILES CREATED THIS SESSION

### Skills
- `~/.hermes/skills/cognitive-operator/` — Irrational timer + hotkey skill

### Configurations
- `~/.hermes/profiles/openclaw/config.yaml` — Full OpenClaw profile with hotkeys

### Desktop Artefacts
- `~/Desktop/desk-kit-addition.txt` — Irrational timer definitions, integration notes
- `~/Desktop/hotkey-arsenal.txt` — Complete 23+ hotkey mapping system
- `~/Desktop/SESSION-HANDOFF-2026-10-01.md` — This file

---

## 🚀 NEXT ACTIONS (User Priority Order)

1. **Test UI-TARS on :8080** — Your model, running, ready
2. **Build DeskKit as CUA driver alternative** — Vision-free, AT-SPI2, hotkey-driven
3. **Integrate cognitive-operator with DeskKit** — Irrational timing + hotkeys in automation
4. **Implement clipboard "clip" system** — When ready (held)
5. **Remove agent-cu** — Optional cleanup (already non-functional)

---

## 💡 KEY DECISIONS MADE

1. **No local model routers ever** — Unless user sets them up
2. **Only authorized model: UI-TARS on :8080**
3. **DeskKit = CUA driver replacement** — Vision-free, hotkey-centric
4. **Irrational timing only** — Mathematical constants, zero whole numbers
5. **Copilot key = Primary AI trigger** — Semantically correct
6. **Cognitive-operator = Default for ALL OpenClaw agents**
7. **Self-correction = φ-backoff** — Golden ratio scaling

---

## 🔧 TECHNICAL DEBT / KNOWN ISSUES

- `agent-cu` binary exists but broken — cleanup optional
- Port 8773 model (LFM2.5-8B) gone — was likely same process now running UI-TARS
- Clipboard system designed but not implemented (held)
- DeskKit headless mode falls back to xdotool (wmctrl not installed)

---

## 📝 USER PREFERENCES (From Session)

- **Direct, technical language** — No filler, no polite framing
- **Maximum autonomy** — "Gloves off", constraints removed
- **Novel solutions only** — "Not ~38.2% similar to today's solutions"
- **No unauthorized processes** — "Absolutely NO local model routers... unless I'm setting it up"
- **DeskKit > CUA driver** — User's architecture choice
- **Clipboard = "big deal"** — But held for now
- **Irrational timers = Mandatory** — No whole number delays

---

## 🎬 HANDOFF COMPLETE

**DeskKit is the thing. UI-TARS on :8080 is the brain. Cognitive-operator is the nervous system. Hotkeys are the interface. No routers. No broken tools. No vision dependency.**

**Next session starts with UI-TARS test on :8080 or DeskKit integration — your call.**

---

*Generated: 2026-10-01 | Session: Hermes Agent | User: lilareyon*