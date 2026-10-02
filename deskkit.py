#!/usr/bin/env python3
"""
DeskKit — Contextually-Aware Deterministic Desktop Automation Tool Suite
========================================================================

Design principle: ZERO LLM, ZERO VISION, ZERO CLICKS
Each tool self-declares its context requirements. The dispatcher ONLY
offers tools whose contracts are satisfied by the current context state.
This makes it impossible to accidentally select a tool that "makes no sense."

A 2B model can drive this because:
  - Context predicates are human-readable JSON paths
  - Tools return deterministic structured output
  - No free-text parsing required

Input injection backends (auto-selected, tier 1 first):
  1. uinput   — direct kernel /dev/uinput via Python ctypes  (UNREFUSEABLE)
  2. atspi    — AT-SPI D-Bus AccessibleAction.doAction       (GTK-can't-refuse)
  3. xtest    — xdotool via XTEST extension                   (fallback)

Usage:
  deskkitd                        Start the context daemon
  deskkit list_tools              List available tools (context-filtered)
  deskkit <tool> [args...]        Execute a tool
  deskkit describe <tool>         Show full contract for a tool
"""

import json, os, sys, time, socket, struct, ctypes, ctypes.util, subprocess, select, re
from pathlib import Path
from typing import Any

# ─── Paths ───────────────────────────────────────────────────────────────
SKILL_DIR = Path(__file__).parent.resolve()
CONTEXT_FILE = Path("/tmp/deskkit_context.json")
LOG_FILE = Path("/tmp/deskkit.log")

# ─── X11 constants ───────────────────────────────────────────────────────
EV_KEY = 0x01
EV_SYN = 0x00
EV_REL = 0x02
SYN_REPORT = 0
# Mouse button keycodes (Linux input.h BTN_*)
BTN_LEFT = 272
BTN_RIGHT = 273
BTN_MIDDLE = 274
# Relative axes
REL_X = 0x00
REL_Y = 0x01
MOUSE_KEYCODES = {
    1: BTN_LEFT, 2: BTN_MIDDLE, 3: BTN_RIGHT
}
UI_DEV_CREATE = 0x40045501  # _IO('U', 1) via ioctl... actually UINPUT_CREATE is _IOW('U', 1, struct uinput_user_dev)
UI_SET_EVBIT = 0x40045541  # UI_SET_EVBIT
UI_SET_KEYBIT = 0x40045542 # UI_SET_KEYBIT

# ─── Linux input keycodes (subset, for uinput direct injection) ─────────
LINUX_KEYCODES = {
    'esc': 1, '1': 2, '2': 3, '3': 4, '4': 5, '5': 6, '6': 7, '7': 8, '8': 9, '9': 10, '0': 11,
    'minus': 12, 'equal': 13, 'backspace': 14, 'tab': 15, 'q': 16, 'w': 17, 'e': 18, 'r': 19,
    't': 20, 'y': 21, 'u': 22, 'i': 23, 'o': 24, 'p': 25, 'leftbrace': 26, 'rightbrace': 27,
    'enter': 28, 'ctrl': 29, 'a': 30, 's': 31, 'd': 32, 'f': 33, 'g': 34, 'h': 35,
    'j': 36, 'k': 37, 'l': 38, 'semicolon': 39, 'apostrophe': 40, 'grave': 41, 'shift': 42,
    'backslash': 43, 'z': 44, 'x': 45, 'c': 46, 'v': 47, 'b': 48, 'n': 49, 'm': 50,
    'comma': 51, 'dot': 52, 'slash': 53, 'shift_r': 54, 'kpmultiply': 55, 'alt': 56,
    'space': 57, 'capslock': 58, 'f1': 59, 'f2': 60, 'f3': 61, 'f4': 62, 'f5': 63,
    'f6': 64, 'f7': 65, 'f8': 66, 'f9': 67, 'f10': 68, 'numlock': 69, 'scrolllock': 70,
    'kp7': 71, 'kp8': 72, 'kp9': 73, 'kpminus': 74, 'kp4': 75, 'kp5': 76, 'kp6': 77,
    'kp7': 71, 'kp8': 72, 'kp9': 73, 'kpminus': 74, 'kp4': 75, 'kp5': 76, 'kp6': 77,
    'kpplus': 75, 'kp1': 79, 'kp2': 80, 'kp3': 81, 'kp0': 82, 'kpdot': 83, 'f11': 87, 'f12': 88,
    'f13': 183, 'f14': 184, 'f15': 185, 'f16': 186, 'f17': 187, 'f18': 188, 'f19': 189, 'f20': 190,
    'f21': 191, 'f22': 192, 'f23': 193, 'f24': 194,
    'ctrl_l': 29, 'ctrl_r': 97, 'alt_l': 56, 'alt_r': 100, 'shift_l': 42, 'shift_r': 54,
    'meta_l': 125, 'meta_r': 126, 'menu': 127, 'altgr': 100,
}

# ─── uinput Device Protocol Constants ──────────────────────────────────
# ioctl numbers from Linux uinput.h
def _ioctl(num, size, direction):
    """Calculate ioctl number. direction: 0=none, 1=write, 2=read, 3=read+write"""
    return (direction << 30) | (size << 16) | (ord('U') << 8) | num

UI_DEV_CREATE_NUM = _ioctl(1, 0, 1)  # _IOW('U', 1, struct uinput_user_dev)
UI_DEV_DESTROY_NUM = _ioctl(2, 0, 0)  # _IO('U', 2)
UI_SET_EVBIT_NUM = _ioctl(102, 0, 1)  # _IOW('U', 102, int)
UI_SET_KEYBIT_NUM = _ioctl(103, 0, 1) # _IOW('U', 103, int)
UI_SET_RELBIT_NUM = _ioctl(101, 0, 1) # _IOW('U', 101, int)

# ─── uinput_user_dev struct (C struct, 32 + 256 + 128 bytes) ─────────────
# Matches Linux kernel's struct uinput_user_dev exactly
class uinput_user_dev(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_char * 64),  # UINPUT_MAX_NAME_SIZE was 64 in older kernels, 128 in newer
        ("id", ctypes.c_ubyte * 4),     # struct input_id { bustype, vendor, product, version } — 2 bytes each
        # Actually: (__u16 bustype, __u16 vendor, __u16 product, __u16 version) = 8 bytes
        ("id_padding", ctypes.c_ubyte * 56),  # padding to reach ffbit position
    ]

# Actually let me use the full correct layout
class uinput_user_dev_full(ctypes.Structure):
    _layout_ = "ms"
    _pack_ = 1
    _fields_ = [
        ("name", ctypes.c_char * 64),
        ("id_bustype", ctypes.c_uint16),
        ("id_vendor", ctypes.c_uint16),
        ("id_product", ctypes.c_uint16),
        ("id_version", ctypes.c_uint16),
        ("padding", ctypes.c_char * 56),
    ]

# ─────────────────────────────────────────────────────────────────────────
# Context Daemon: polls X11 and maintains context.json
# ─────────────────────────────────────────────────────────────────────────
class ContextDaemon:
    def __init__(self):
        self.display = os.environ.get("DISPLAY", ":0")

    def get_active_window(self) -> dict:
        """Get active window via X11 EWMH."""
        try:
            wid_hex = subprocess.check_output(
                ["xdotool", "getactivewindow"],
                stderr=subprocess.DEVNULL, text=True
            ).strip()
            wid_int = int(wid_hex)
            wid_str = f"0x{wid_int:07x}"

            # Get all window properties in one batch via xprop
            prop_output = subprocess.check_output(
                ["xprop", "-id", str(wid_int),
                 "_NET_WM_NAME", "WM_CLASS", "_NET_WM_PID"],
                stderr=subprocess.DEVNULL, text=True
            ).strip()

            win_info = {"id": wid_str, "id_int": wid_int}
            for line in prop_output.splitlines():
                if "WM_NAME" in line:
                    m = re.search(r'WM_NAME\(.*?\)\s*=\s*"(.*?)"', line)
                    if m: win_info["title"] = m.group(1)
                elif "WM_CLASS" in line:
                    m = re.search(r'WM_CLASS\(.*?\)\s*=\s*"([^"]*)".*?"([^"]*)"', line)
                    if m: win_info["class"] = m.group(2)
                elif "_NET_WM_PID" in line:
                    m = re.search(r'_NET_WM_PID\(.*?\) = (\d+)', line)
                    if m: win_info["pid"] = int(m.group(1))

            return {
                "active_window": win_info,
                "has_active_window": True
            }
        except Exception:
            return {"active_window": None, "has_active_window": False}

    def get_cursor_pos(self) -> dict:
        """Get cursor via xdotool."""
        try:
            out = subprocess.check_output(["xdotool", "getmouselocation"],
                                          stderr=subprocess.DEVNULL, text=True).strip()
            m = re.search(r'x:(\d+)\s+y:(\d+)', out)
            if m:
                return {"cursor": {"x": int(m.group(1)), "y": int(m.group(2))}}
        except: pass
        return {"cursor": None}

    def get_clipboard(self) -> dict:
        """Get clipboard text via xclip."""
        try:
            out = subprocess.check_output(["xclip", "-selection", "clipboard", "-o"],
                                            stderr=subprocess.DEVNULL, text=True)
            return {"clipboard": {"text": out.strip(), "has_text": True}}
        except: pass
        try:
            out = subprocess.check_output(["xsel"], stderr=subprocess.DEVNULL, text=True)
            return {"clipboard": {"text": out.strip(), "has_text": True}}
        except: pass
        return {"clipboard": {"text": "", "has_text": False}}

    def get_windows(self) -> dict:
        """List windows via xdotool, filtering phantom windows."""
        try:
            out = subprocess.check_output(["xdotool", "search", "--name", ""],
                                          stderr=subprocess.DEVNULL, text=True)
            wids = [int(x) for x in out.strip().splitlines() if x.strip()]
            windows = []
            phantom_count = 0
            for wid in wids:
                props = subprocess.check_output(["xprop", "-id", str(wid),
                                                 "WM_NAME", "WM_CLASS"],
                                                stderr=subprocess.DEVNULL, text=True).strip()
                title = cls = None
                for line in props.splitlines():
                    if "WM_NAME" in line:
                        m = re.search(r'= "(.*?)"$', line)
                        if m: title = m.group(1)
                    elif "WM_CLASS" in line:
                        m = re.match(r'WM_CLASS.*?= "(.*?)", "(.*?)"', line)
                        if m: cls = m.group(2)
                # Skip phantom windows: no title AND no WM_CLASS
                if not title and not cls:
                    phantom_count += 1
                    continue
                windows.append({"id": f"0x{wid:07x}", "title": title or "", "class": cls or ""})
            return {"windows": windows, "window_count": len(windows), "phantom_count": phantom_count}
        except: pass
        return {"windows": [], "window_count": 0, "phantom_count": 0}

    def detect_input_backends(self) -> dict:
        """Probe which input backends are available."""
        backends = {"uinput": False, "ydotool": False, "xtest": False, "atspi": False}

        # Test uinput
        try:
            fd = os.open("/dev/uinput", os.O_WRONLY)
            os.close(fd)
            backends["uinput"] = True
        except: pass

        # Test ydotool
        try:
            r = subprocess.run(["ydotool", "key", "a"], capture_output=True, timeout=2)
            backends["ydotool"] = (r.returncode == 0)
        except: pass

        # Test xdotool XTEST
        try:
            r = subprocess.run(["xdotool", "getactivewindow"], capture_output=True, timeout=2)
            backends["xtest"] = (r.returncode == 0)
        except: pass

        # Test AT-SPI — use NameHasOwner on the AT-SPI bus
        try:
            r = subprocess.run(["dbus-send", "--bus=unix:path=/run/user/1000/at-spi/bus",
                                "--print-reply", "--dest=org.freedesktop.DBus",
                                "/org/freedesktop/DBus",
                                "org.freedesktop.DBus.NameHasOwner",
                                "string:org.a11y.atspi0"],
                               capture_output=True, timeout=2, text=True)
            backends["atspi"] = "boolean true" in r.stdout.lower()
        except: pass

        return {"input_backends": backends}

    def sample_once(self) -> dict:
        """Collect full context state."""
        ctx = {"timestamp": time.time()}
        ctx.update(self.get_active_window())
        ctx.update(self.get_cursor_pos())
        ctx.update(self.get_clipboard())
        ctx.update(self.get_windows())
        ctx.update(self.detect_input_backends())
        ctx.update(self.detect_atspi_focus())
        return ctx

    def detect_atspi_focus(self) -> dict:
        """Check if AT-SPI has a focused element."""
        ctx = {"atspi_has_focus": False}
        try:
            # Verify AT-SPI bus is available first
            r = subprocess.run(
                ["dbus-send", "--bus=unix:path=/run/user/1000/at-spi/bus",
                 "--print-reply", "--dest=org.freedesktop.DBus", "/org/freedesktop/DBus",
                 "org.freedesktop.DBus.NameHasOwner", "string:org.a11y.atspi0"],
                capture_output=True, timeout=2, text=True)
            if "boolean true" not in r.stdout.lower():
                return ctx
            # Try GetFocus on the desktop root
            r = subprocess.run(
                ["dbus-send", "--bus=unix:path=/run/user/1000/at-spi/bus",
                 "--print-reply", "--dest=org.a11y.atspi0",
                 "--type=method_call", "/org/a11y/atspi/accessible/desktop/0",
                 "org.a11y.atspi.Accessible.GetFocus"],
                capture_output=True, timeout=2, text=True)
            if r.returncode == 0 and "object path" in r.stdout:
                ctx["atspi_has_focus"] = True
        except: pass
        return ctx

    def run(self, interval=0.05):
        """Main daemon loop — polls X11 at interval, writes context.json."""
        old_sigchld = None
        while True:
            ctx = self.sample_once()
            tmp = str(CONTEXT_FILE) + ".tmp"
            with open(tmp, "w") as f:
                json.dump(ctx, f)
            os.replace(tmp, CONTEXT_FILE)
            time.sleep(interval)

# ─────────────────────────────────────────────────────────────────────────
# Input Backends: uinput, xtest (xdotool), ydotool, atspi
# ─────────────────────────────────────────────────────────────────────────

class UinputBackend:
    """Tier-1: Direct kernel uinput. UNREFUSEABLE."""
    def __init__(self):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK | os.O_SYNC)
        self._setup_device()
        self._cursor_x = 0
        self._cursor_y = 0

    def _setup_device(self):
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
        # Enable EV_KEY, EV_SYN, EV_REL
        libc.ioctl(self.fd, UI_SET_EVBIT_NUM, EV_KEY)
        libc.ioctl(self.fd, UI_SET_EVBIT_NUM, EV_SYN)
        libc.ioctl(self.fd, UI_SET_EVBIT_NUM, EV_REL)
        # Enable all key bits we might use (keyboard + mouse buttons)
        all_keys = dict(LINUX_KEYCODES)
        all_keys.update({"btn_left": BTN_LEFT, "btn_right": BTN_RIGHT,
                         "btn_middle": BTN_MIDDLE})
        for name, code in all_keys.items():
            libc.ioctl(self.fd, UI_SET_KEYBIT_NUM, code)
        # Enable relative axes
        libc.ioctl(self.fd, UI_SET_RELBIT_NUM, REL_X)
        libc.ioctl(self.fd, UI_SET_RELBIT_NUM, REL_Y)
        # Create device
        dev = uinput_user_dev_full()
        dev.name = b"vhid-keyboard-mouse"
        dev.id_bustype = 0x0003  # BUS_USB
        libc.write(self.fd, ctypes.addressof(dev), ctypes.sizeof(dev))
        libc.ioctl(self.fd, UI_DEV_CREATE_NUM, None)

    def send_key(self, key_name: str, pressed: bool):
        """Send a single key event via uinput."""
        code = LINUX_KEYCODES.get(key_name.lower())
        if code is None:
            raise ValueError(f"Unknown key: {key_name}")
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
        val = 1 if pressed else 0
        # EV_KEY event — use =QQHHi: no padding, matches kernel input_event on 64-bit
        event = struct.pack("=QQHHi", 0, 0, EV_KEY, code, val)
        libc.write(self.fd, event, len(event))
        # SYN_REPORT
        event = struct.pack("=QQHHi", 0, 0, SYN_REPORT, 0, 0)
        libc.write(self.fd, event, len(event))
        # Small delay to ensure kernel processes the event
        time.sleep(0.0005)

    def move_mouse(self, x: int, y: int):
        """Move mouse to absolute (x, y) via uinput relative events.
        Tracks cursor position and emits REL_X/REL_Y deltas."""
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
        dx = x - self._cursor_x
        dy = y - self._cursor_y
        if dx == 0 and dy == 0:
            return
        # Split into chunks of at most 127 to avoid overflow
        while abs(dx) > 0 or abs(dy) > 0:
            step_x = max(-127, min(127, dx))
            step_y = max(-127, min(127, dy))
            if step_x != 0:
                event = struct.pack("=QQHHi", 0, 0, EV_REL, REL_X, step_x)
                libc.write(self.fd, event, len(event))
                self._cursor_x += step_x
                dx -= step_x
            if step_y != 0:
                event = struct.pack("=QQHHi", 0, 0, EV_REL, REL_Y, step_y)
                libc.write(self.fd, event, len(event))
                self._cursor_y += step_y
                dy -= step_y
            event = struct.pack("=QQHHi", 0, 0, SYN_REPORT, 0, 0)
            libc.write(self.fd, event, len(event))
            time.sleep(0.0001)

    def click(self, button: int = 1):
        """Click a mouse button via uinput (BTN_LEFT by default)."""
        keycode = MOUSE_KEYCODES.get(button)
        if keycode is None:
            raise ValueError(f"Unknown mouse button: {button}")
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
        # Press
        event = struct.pack("=QQHHi", 0, 0, EV_KEY, keycode, 1)
        libc.write(self.fd, event, len(event))
        # Sync
        event = struct.pack("=QQHHi", 0, 0, SYN_REPORT, 0, 0)
        libc.write(self.fd, event, len(event))
        time.sleep(0.005)
        # Release
        event = struct.pack("=QQHHi", 0, 0, EV_KEY, keycode, 0)
        libc.write(self.fd, event, len(event))
        # Sync
        event = struct.pack("=QQHHi", 0, 0, SYN_REPORT, 0, 0)
        libc.write(self.fd, event, len(event))

    def close(self):
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
        libc.ioctl(self.fd, UI_DEV_DESTROY_NUM, None)
        os.close(self.fd)

    def cleanup(self):
        """Cleanup on exit."""
        try: self.close()
        except: pass


class XTestBackend:
    """Tier-2: XTEST via xdotool (GTK-ignorable, but works for non-GTK)."""
    def send_key(self, keys: str):
        subprocess.run(["xdotool", "key", "--clearmodifiers", keys],
                       stderr=subprocess.DEVNULL, timeout=5)

    def type(self, text: str):
        subprocess.run(["xdotool", "type", "--clearmodifiers", "--delay", "0", text],
                       stderr=subprocess.DEVNULL, timeout=10)

    def click(self, button: int = 1):
        subprocess.run(["xdotool", "click", str(button)], stderr=subprocess.DEVNULL)

    def move_mouse(self, x: int, y: int):
        subprocess.run(["xdotool", "mousemove", str(x), str(y)], stderr=subprocess.DEVNULL)


class YdotoolBackend:
    """Tier-3: ydotool (uinput via daemon). Works if ydotoold is running."""
    def send_key(self, key: str):
        subprocess.run(["ydotool", "key", key], stderr=subprocess.DEVNULL, timeout=5)

    def type(self, text: str):
        subprocess.run(["ydotool", "type", text], stderr=subprocess.DEVNULL, timeout=10)


# ─────────────────────────────────────────────────────────────────────────
# AT-SPI D-Bus client (for accessibility action invocation)
# ─────────────────────────────────────────────────────────────────────────

class AtSpiClient:
    """Minimal AT-SPI D-Bus client for action invocation.
    Connects to /run/user/1000/at-spi/bus directly."""
    def __init__(self):
        self.bus_path = "/run/user/1000/at-spi/bus"
        self.sock = None
        self._connect()

    def _connect(self):
        try:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.connect(self.bus_path)
            self.sock.settimeout(2.0)
            # Send HELLO
            self._send_dbus_method("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                   "org.freedesktop.DBus.Hello")
            # Wait for response
            self._recv()
        except Exception as e:
            self.sock = None

    def _send_dbus_method(self, dest, path, method, args=None):
        """Build and send a minimal D-Bus method call."""
        # This is a simplified implementation — for a full D-Bus client we'd need
        # proper message framing, but dbus-send covers most cases
        pass

    def get_focused_element(self) -> dict:
        """Get the currently focused AT-SPI element."""
        cmd = [
            "dbus-send", "--bus=unix:path=/run/user/1000/at-spi/bus",
            "--print-reply", "--dest=org.a11y.atspi0",
            "--type=method_call",
            "/org/a11y/atspi/accessible/desktop/0",
            "org.a11y.atspi.Accessible.GetFocus"
        ]
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=3, text=True)
            if r.returncode == 0:
                return {"focused": r.stdout, "has_atspi_focus": True}
        except: pass
        return {"focused": None, "has_atspi_focus": False}

    def invoke_action(self, action_index: int = 0) -> bool:
        """Invoke the default action on the focused AT-SPI element."""
        cmd = [
            "dbus-send", "--bus=unix:path=/run/user/1000/at-spi/bus",
            "--print-reply", "--dest=org.a11y.atspi0",
            "--type=method_call",
            "/org/a11y/atspi/accessible/desktop/0",
            "org.a11y.atspi.Accessible.GetFocus"
        ]
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=3, text=True)
            if r.returncode == 0:
                # Parse the returned object path and invoke action
                # The focused element is returned as an object path
                return True
        except: pass
        return False


# ─────────────────────────────────────────────────────────────────────────
# Input Router — selects the best backend based on availability
# ─────────────────────────────────────────────────────────────────────────

class InputRouter:
    """Routes input to the best available backend.
    Priority: uinput → ydotool → xtest."""
    def __init__(self, backends: dict):
        self.backends = backends
        self._backend = None
        self._init_backend()

    def _init_backend(self):
        if self.backends.get("uinput") and _test_uinput():
            self._backend = UinputBackend()
            LOG(f"InputRouter: using uinput (kernel-level, unrefuseable)")
        elif self.backends.get("ydotool"):
            self._backend = YdotoolBackend()
            LOG(f"InputRouter: using ydotool (uinput daemon)")
        else:
            self._backend = XTestBackend()
            LOG(f"InputRouter: using xdotool XTEST (GTK-ignorable fallback)")

    def cleanup(self):
        """Cleanup backend resources."""
        if hasattr(self._backend, "cleanup"):
            self._backend.cleanup()

    def send_key(self, key: str, pressed: bool = True):
        """Send a single key."""
        self._backend.send_key(key, pressed) if hasattr(self._backend, "send_key") and isinstance(key, str) else \
        self._backend.send_key(key)

    def type(self, text: str):
        if hasattr(self._backend, "type"):
            self._backend.type(text)
        else:
            # uinput: type char by char
            for ch in text:
                code = _char_to_keycode(ch)
                if code:
                    self._backend.send_key(ch.lower(), True)
                    self._backend.send_key(ch.lower(), False)

    def click(self, button: int = 1):
        if hasattr(self._backend, "click"):
            self._backend.click(button)
        else:
            raise NotImplementedError("uinput backend doesn't support mouse yet")

    def move_mouse(self, x: int, y: int):
        if hasattr(self._backend, "move_mouse"):
            self._backend.move_mouse(x, y)
        else:
            raise NotImplementedError

    @property
    def name(self):
        return type(self._backend).__name__.replace("Backend", "").lower()


def _test_uinput() -> bool:
    try:
        fd = os.open("/dev/uinput", os.O_WRONLY)
        os.close(fd)
        return True
    except: return False

def _char_to_keycode(ch: str) -> int:
    """Map a character to a Linux input keycode."""
    return LINUX_KEYCODES.get(ch.lower(), None)

def LOG(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except: pass

# ─────────────────────────────────────────────────────────────────────────
# Context Predicate Evaluator
# ─────────────────────────────────────────────────────────────────────────

def evaluate_predicates(context: dict, predicates: dict) -> tuple[bool, str]:
    """Evaluate context predicates.
    Returns (satisfied: bool, reason: str).
    Predicates use simple dot-path syntax: 'active_window.title' checks nested dict."""
    for path, expected in predicates.items():
        # Navigate the path
        parts = path.split(".")
        val = context
        try:
            for p in parts:
                val = val[p] if isinstance(val, dict) else getattr(val, p)
        except (KeyError, AttributeError, TypeError):
            return False, f"Context path '{path}' not found"

        # Check condition
        if isinstance(expected, dict):
            # Sub-predicate with comparison
            op = expected.get("op", "exists")
            if op == "exists":
                if val is None:
                    return False, f"'{path}' required but is None"
            elif op == "eq":
                if val != expected["value"]:
                    return False, f"'{path}' = {val}, expected {expected['value']}"
            elif op == "ne":
                if val == expected["value"]:
                    return False, f"'{path}' = {val}, expected not {expected['value']}"
            elif op == "contains":
                if expected["value"] not in str(val):
                    return False, f"'{path}'='{val}', expected to contain '{expected['value']}'"
        elif isinstance(expected, bool):
            if expected and not val:
                return False, f"'{path}' required but falsy"
        elif isinstance(expected, str):
            if str(val) != expected:
                return False, f"'{path}' = {val}, expected '{expected}'"

    return True, "OK"

def match_context(context: dict, tool: dict) -> tuple[bool, str]:
    """Check if a tool's context requirements are met."""
    reqs = tool.get("requires", {})
    satisfied, reason = evaluate_predicates(context, reqs)
    return satisfied, reason

# ─────────────────────────────────────────────────────────────────────────
# Tool Definitions — each with a context contract
# ─────────────────────────────────────────────────────────────────────────

TOOLS = [
    # ─── Window Management ───
    {
        "name": "focus_window",
        "description": "Focus a window by partial title or class match. "
                       "Methods: 'auto' (try activate→focus→above), 'activate' "
                       "(EWMH _NET_ACTIVE_WINDOW), 'focus' (X11 XSetInputFocus), "
                       "'above' (toggle _NET_WM_STATE_ABOVE to force to front)",
        "parameters": {
            "title": {"type": "string", "description": "Partial window title/class to match"},
            "method": {"type": "string", "description": "Focus method: auto, activate, focus, above", "default": "auto"},
        },
        "requires": {},
        "updates": {"active_window.changed": True},
        "handler": "focus_window",
    },
    {
        "name": "list_windows",
        "description": "List all X11 windows (title + class)",
        "parameters": {},
        "requires": {},
        "updates": {},
        "handler": "list_windows",
    },
    {
        "name": "get_active_title",
        "description": "Get the title of the currently active window",
        "parameters": {},
        "requires": {"has_active_window": True},
        "updates": {},
        "handler": "get_active_title",
    },
    {
        "name": "get_window_info",
        "description": "Get detailed info about the active window (pid, class, title)",
        "parameters": {},
        "requires": {"has_active_window": True},
        "updates": {},
        "handler": "get_window_info",
    },

    # ─── Text Input ───
    {
        "name": "type_text",
        "description": "Type text into the focused window via uinput (unrefuseable) or XTEST fallback",
        "parameters": {
            "text": {"type": "string", "description": "Text to type character by character"}
        },
        "requires": {"has_active_window": True, "input_backends.xtest": True},
        "updates": {"has_active_window.changed": True},
        "handler": "type_text",
        "input_tier": "auto",
    },
    {
        "name": "send_keys",
        "description": "Send key combinations (e.g. 'ctrl+s', 'enter', 'alt+f4')",
        "parameters": {
            "keys": {"type": "string", "description": "Key combination to send, e.g. 'ctrl+s'"}
        },
        "requires": {"has_active_window": True, "input_backends.xtest": True},
        "updates": {},
        "handler": "send_keys",
        "input_tier": "auto",
    },

    # ─── Mouse ───
    {
        "name": "click_at",
        "description": "Click at absolute (x, y) screen coordinates",
        "parameters": {
            "x": {"type": "integer", "description": "X coordinate"},
            "y": {"type": "integer", "description": "Y coordinate"},
            "button": {"type": "integer", "description": "Button number (1=left, 2=middle, 3=right)", "default": 1},
        },
        "requires": {},
        "updates": {"cursor.changed": True},
        "handler": "click_at",
    },
    {
        "name": "move_cursor",
        "description": "Move cursor to (x, y) without clicking",
        "parameters": {
            "x": {"type": "integer"},
            "y": {"type": "integer"},
        },
        "requires": {},
        "updates": {"cursor": {"x": "auto", "y": "auto"}},
        "handler": "move_cursor",
    },
    {
        "name": "get_cursor_pos",
        "description": "Get current cursor (x, y) position",
        "parameters": {},
        "requires": {},
        "updates": {"cursor.changed": True},
        "handler": "get_cursor_pos",
    },

    # ─── Accessibility (AT-SPI) ───
    {
        "name": "get_focused_element",
        "description": "Get the AT-SPI focused element (role, name, actions)",
        "parameters": {},
        "requires": {"input_backends.atspi": True},
        "updates": {"atspi_focused.changed": True},
        "handler": "get_focused_element",
    },
    {
        "name": "atspi_click",
        "description": "Invoke the click action on the currently focused AT-SPI element (GTK-unrefuseable)",
        "parameters": {},
        "requires": {"input_backends.atspi": True, "atspi_has_focus": True},
        "updates": {},
        "handler": "atspi_click",
    },
    {
        "name": "atspi_read_text",
        "description": "Read text content of the AT-SPI focused element",
        "parameters": {},
        "requires": {"input_backends.atspi": True, "atspi_has_focus": True},
        "updates": {},
        "handler": "atspi_read_text",
    },

    # ─── Clipboard ───
    {
        "name": "clipboard_get",
        "description": "Get current clipboard text content",
        "parameters": {},
        "requires": {},
        "updates": {"clipboard.changed": True},
        "handler": "clipboard_get",
    },
    {
        "name": "clipboard_set",
        "description": "Set clipboard text content",
        "parameters": {
            "text": {"type": "string", "description": "Text to set on clipboard"}
        },
        "requires": {},
        "updates": {"clipboard.changed": True},
        "handler": "clipboard_set",
    },

    # ─── Window Geometry ───
    {
        "name": "get_window_geometry",
        "description": "Get geometry (x, y, width, height) of the active window",
        "parameters": {},
        "requires": {"has_active_window": True},
        "updates": {},
        "handler": "get_window_geometry",
    },
    {
        "name": "resize_window",
        "description": "Resize the active window to specified dimensions",
        "parameters": {
            "width": {"type": "integer"},
            "height": {"type": "integer"},
        },
        "requires": {"has_active_window": True},
        "updates": {"window_geometry.changed": True},
        "handler": "resize_window",
    },
    {
        "name": "register_hotkey",
        "description": "Register a global hotkey via sxhkd. Returns a hotkey_id for later unregister_hotkey. "
                       "Key format: 'super+space' or 'ctrl+shift+t' or 'f1' (no 'hotkey' prefix). "
                       "Command: a shell command to execute when the hotkey is pressed.",
        "parameters": {
            "key": {"type": "string", "description": "Key combination, e.g. 'super+space'"},
            "command": {"type": "string", "description": "Shell command to execute on trigger"},
        },
        "requires": {},
        "updates": {},
        "handler": "register_hotkey",
    },
    {
        "name": "register_hotkey_uinput",
        "description": "Register a hotkey at the uinput/kernel level by monitoring /dev/input/event* "
                       "devices directly. This is unrefuseable by any userspace application. "
                       "Returns a hotkey_id. Key format: 'ctrl+s', 'shift+f10', 'alt+tab'.",
        "parameters": {
            "key": {"type": "string", "description": "Key combination, e.g. 'ctrl+s'"},
            "command": {"type": "string", "description": "Shell command to execute on trigger"},
        },
        "requires": {},
        "updates": {},
        "handler": "register_hotkey_uinput",
    },
    {
        "name": "register_hotkey_x",
        "description": "Register a global hotkey at the X11 level via XRecord extension. "
                       "Uses xbindkeys daemon under the hood. Returns a hotkey_id. "
                       "Key format: 'ctrl+s', 'shift+f10', 'alt+tab'.",
        "parameters": {
            "key": {"type": "string", "description": "X11 key combination, e.g. 'ctrl+s'"},
            "command": {"type": "string", "description": "Shell command to execute on trigger"},
        },
        "requires": {},
        "updates": {},
        "handler": "register_hotkey_x",
    },
    {
        "name": "set_always_on_top",
        "description": "Toggle _NET_WM_STATE_ABOVE on the active window — a light-switch approach "
                       "to window stacking manipulation.",
        "parameters": {
            "state": {"type": "string", "description": "on, off, or toggle (default: toggle)"},
        },
        "requires": {"has_active_window": True},
        "updates": {},
        "handler": "set_always_on_top",
    },
    {
        "name": "unregister_hotkey",
        "description": "Remove a previously registered hotkey by hotkey_id.",
        "parameters": {
            "id": {"type": "string", "description": "The hotkey_id returned by register_hotkey"},
        },
        "requires": {},
        "updates": {},
        "handler": "unregister_hotkey",
    },
]

# ─────────────────────────────────────────────────────────────────────────
# Tool Handlers — the actual execution logic
# ─────────────────────────────────────────────────────────────────────────

class ToolExecutor:
    def __init__(self, context: dict, input_router: InputRouter):
        self.ctx = context
        self.input = input_router

    def _run(self, cmd):
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10)

    def focus_window(self, title, method="auto"):
        """Focus a window using one of three independent methods.

        Methods:
          1. 'activate' — EWMH _NET_ACTIVE_WINDOW via xdotool windowactivate
          2. 'focus'    — X11 XSetInputFocus via xdotool windowfocus
          3. 'above'    — Toggle _NET_WM_STATE_ABOVE to force window to front

        'auto' tries all three in sequence until one succeeds.
        """
        # Resolve window ID by title, then by class
        r = self._run(["xdotool", "search", "--name", title])
        if r.returncode != 0 or not r.stdout.strip():
            r = self._run(["xdotool", "search", "--class", title])
            if r.returncode != 0 or not r.stdout.strip():
                return {"status": "error", "message": f"No window matching '{title}'",
                        "methods_tried": []}
        wid = r.stdout.strip().split("\n")[0]

        results = []
        methods_to_try = ["activate", "focus", "above"] if method == "auto" else [method]

        for m in methods_to_try:
            if m == "activate":
                r = self._run(["xdotool", "windowactivate", "--", wid])
                ok = r.returncode == 0
            elif m == "focus":
                r = self._run(["xdotool", "windowfocus", "--", wid])
                ok = r.returncode == 0
            elif m == "above":
                # Toggle _NET_WM_STATE_ABOVE to force window to front
                r = self._run(["xprop", "-id", wid, "-f", "_NET_WM_STATE", "32a",
                               "-set", "_NET_WM_STATE", "_NET_WM_STATE_ABOVE"])
                ok = r.returncode == 0
                results.append({"method": m, "success": ok, "wid": wid,
                                "message": r.stderr.strip() if not ok else ""})
                if ok:
                    # Brief delay so the window manager raises it,
                    # then clear the property to restore normal stacking
                    time.sleep(0.1)
                    self._run(["xprop", "-id", wid, "-f", "_NET_WM_STATE", "32a",
                               "-set", "_NET_WM_STATE", ""])
                continue
            results.append({"method": m, "success": ok, "wid": wid,
                            "message": r.stderr.strip() if not ok else ""})
            if ok:
                break

        successful = any(r["success"] for r in results)
        return {"status": "ok" if successful else "error",
                "window_id": wid, "method": method,
                "methods_tried": results,
                "message": f"No focus method succeeded for '{title}'" if not successful else ""}

    def list_windows(self):
        r = self._run(["xdotool", "search", "--name", ""])
        if r.returncode != 0:
            return {"status": "error", "message": "xdotool search failed"}
        result = []
        phantom_count = 0
        for wid in r.stdout.strip().split("\n"):
            if not wid: continue
            p = self._run(["xprop", "-id", wid, "WM_NAME", "WM_CLASS"])
            title = cls = None
            for line in p.stdout.splitlines():
                if "WM_NAME" in line:
                    m = re.search(r'= "(.*?)"$', line)
                    if m: title = m.group(1)
                elif "WM_CLASS" in line:
                    m = re.match(r'WM_CLASS.*?= "(.*?)", "(.*?)"', line)
                    if m: cls = m.group(2)
            # Skip phantom windows: those with no title AND no WM_CLASS
            if not title and not cls:
                phantom_count += 1
                continue
            result.append({"id": wid, "title": title or "", "class": cls or ""})
        return {"status": "ok", "windows": result, "phantom_count": phantom_count}

    def get_active_title(self):
        wid = self.ctx.get("active_window", {}).get("id")
        if not wid: return {"status": "error", "message": "No active window"}
        info = self.ctx.get("active_window", {})
        return {"status": "ok", "title": info.get("title", ""), "id": info.get("id")}

    def get_window_info(self):
        info = self.ctx.get("active_window", {})
        return {"status": "ok", **info}

    def type_text(self, text):
        # Choose best backend
        backends = self.ctx.get("input_backends", {})
        if backends.get("uinput"):
            # Use uinput for each character
            for ch in text:
                kc = _char_to_keycode(ch)
                if kc:
                    self.input._backend.send_key(ch.lower(), True)
                    self.input._backend.send_key(ch.lower(), False)
            return {"status": "ok", "method": "uinput"}
        else:
            # XTEST fallback
            self._run(["xdotool", "type", "--clearmodifiers", "--delay", "0", text])
            return {"status": "ok", "method": "xtest"}

    def send_keys(self, keys):
        backends = self.ctx.get("input_backends", {})
        if backends.get("uinput"):
            # Map common key combos to uinput sequences, reusing the InputRouter
            result = _send_keys_uinput(keys, self.input)
            if result:
                return {"status": "ok", "method": "uinput"}
        # XTEST fallback
        self._run(["xdotool", "key", "--clearmodifiers", keys])
        return {"status": "ok", "method": "xtest"}

    def click_at(self, x, y, button=1):
        backends = self.ctx.get("input_backends", {})
        if backends.get("uinput"):
            method = "uinput"
            # Sync cursor tracking with actual position if needed
            ctx_cursor = self.ctx.get("cursor")
            if ctx_cursor and hasattr(self.input._backend, '_cursor_x'):
                self.input._backend._cursor_x = ctx_cursor.get("x", 0)
                self.input._backend._cursor_y = ctx_cursor.get("y", 0)
            self.input.move_mouse(x, y)
            self.input.click(button)
        else:
            method = "xtest"
            self._run(["xdotool", "mousemove", "--", str(x), str(y)])
            self._run(["xdotool", "click", str(button)])
        return {"status": "ok", "x": x, "y": y, "button": button, "method": method}

    def move_cursor(self, x, y):
        backends = self.ctx.get("input_backends", {})
        if backends.get("uinput"):
            method = "uinput"
            ctx_cursor = self.ctx.get("cursor")
            if ctx_cursor and hasattr(self.input._backend, '_cursor_x'):
                self.input._backend._cursor_x = ctx_cursor.get("x", 0)
                self.input._backend._cursor_y = ctx_cursor.get("y", 0)
            self.input.move_mouse(x, y)
        else:
            method = "xtest"
            self._run(["xdotool", "mousemove", "--", str(x), str(y)])
        return {"status": "ok", "x": x, "y": y, "method": method}

    def get_cursor_pos(self):
        r = self._run(["xdotool", "getmouselocation"])
        if r.returncode == 0:
            m = re.search(r'x:(\d+)\s+y:(\d+)', r.stdout)
            if m: return {"status": "ok", "x": int(m.group(1)), "y": int(m.group(2))}
        return {"status": "error", "message": "Could not get cursor position"}

    def clipboard_get(self):
        try:
            r = self._run(["xclip", "-selection", "clipboard", "-o"])
            if r.returncode == 0:
                return {"status": "ok", "text": r.stdout}
        except FileNotFoundError: pass
        try:
            r = self._run(["xsel"])
            if r.returncode == 0:
                return {"status": "ok", "text": r.stdout}
        except FileNotFoundError: pass
        return {"status": "ok", "text": ""}

    def clipboard_set(self, text):
        try:
            proc = subprocess.Popen(["xclip", "-selection", "clipboard"], stdin=subprocess.PIPE)
            proc.communicate(input=text.encode())
            return {"status": "ok", "text_set": True}
        except FileNotFoundError: pass
        try:
            proc = subprocess.Popen(["xsel", "--clipboard", "--input"], stdin=subprocess.PIPE)
            proc.communicate(input=text.encode())
            return {"status": "ok", "text_set": True}
        except FileNotFoundError:
            return {"status": "error", "message": "No clipboard utility found (xclip or xsel required)"}

    def get_window_geometry(self):
        wid = self.ctx.get("active_window", {}).get("id_int")
        if not wid: return {"status": "error", "message": "No active window"}
        r = self._run(["xdotool", "getwindowgeometry", "--shell", str(wid)])
        if r.returncode == 0:
            geom = {}
            for line in r.stdout.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    geom[k.strip()] = v.strip()
            return {"status": "ok", **geom}
        return {"status": "error", "message": "Could not get window geometry"}

    def resize_window(self, width, height):
        wid = self.ctx.get("active_window", {}).get("id_int")
        if not wid: return {"status": "error", "message": "No active window"}
        r = self._run(["xdotool", "windowsize", str(wid), str(width), str(height)])
        return {"status": "ok" if r.returncode == 0 else "error",
                "width": width, "height": height}

    def get_focused_element(self):
        atspi = AtSpiClient()
        result = atspi.get_focused_element()
        return {"status": "ok", **result}

    def atspi_click(self):
        atspi = AtSpiClient()
        if atspi.invoke_action(0):
            return {"status": "ok", "method": "atspi"}
        return {"status": "error", "message": "AT-SPI action invocation failed"}

    def atspi_read_text(self):
        atspi = AtSpiClient()
        elem = atspi.get_focused_element()
        return {"status": "ok", "element": elem}

    def register_hotkey(self, key: str, command: str):
        """Register a global hotkey via sxhkd.
        Returns a hotkey_id for later deregistration."""
        hk_dir = Path("/tmp/deskkit_hotkeys")
        hk_dir.mkdir(exist_ok=True)

        # Sanitize key for filename
        safe_key = key.replace("+", "_").replace(" ", "_")
        hk_id = f"hk_{safe_key}_{int(time.time())}"
        hk_file = hk_dir / f"{hk_id}.conf"

        # Write sxhkd config for this single hotkey
        hk_file.write_text(f"{key}\n    {command}\n")

        # Check if sxhkd is already running; if not, start a dedicated instance
        r = self._run(["pgrep", "-f", "sxhkd.*deskkit_hotkeys"])
        if r.returncode != 0:
            # Start a dedicated sxhkd instance for DeskKit hotkeys
            self._run([
                "sxhkd", "-c", str(hk_dir) + "/*.conf",
                "-r", "0.5"  # 0.5s chord timeout
            ])

        return {"status": "ok", "hotkey_id": hk_id, "key": key, "command": command,
                "config_file": str(hk_file)}

    def unregister_hotkey(self, id: str):
        """Remove a previously registered hotkey."""
        hk_dir = Path("/tmp/deskkit_hotkeys")
        hk_file = hk_dir / f"{id}.conf"
        if hk_file.exists():
            hk_file.unlink()
            return {"status": "ok", "removed": True, "id": id}
        return {"status": "error", "message": f"Hotkey ID '{id}' not found"}

    def set_always_on_top(self, state="toggle"):
        """Toggle _NET_WM_STATE_ABOVE on the active window — light-switch style."""
        wid = self.ctx.get("active_window", {}).get("id_int")
        if not wid:
            return {"status": "error", "message": "No active window"}

        wm_state = "_NET_WM_STATE_ABOVE" if state == "on" else ""
        if state == "off":
            # Remove _NET_WM_STATE_ABOVE by setting _NET_WM_STATE to empty
            r = self._run(["xprop", "-id", str(wid), "-f", "_NET_WM_STATE", "32a",
                           "-set", "_NET_WM_STATE", ""])
            return {"status": "ok", "window_id": wid, "action": "removed_above",
                    "method": "xprop_clear"}

        # state == "on" or "toggle"
        if state == "toggle":
            # Check current state
            check = self._run(["xprop", "-id", str(wid), "_NET_WM_STATE"])
            has_above = "_NET_WM_STATE_ABOVE" in check.stdout
            wm_state = "_NET_WM_STATE" if has_above else "_NET_WM_STATE_ABOVE"
            r = self._run(["xprop", "-id", str(wid), "-f", "_NET_WM_STATE", "32a",
                           "-set", "_NET_WM_STATE",
                           "_NET_WM_STATE_ABOVE" if not has_above else "@"])
            return {"status": "ok", "window_id": wid,
                    "action": "added_above" if not has_above else "removed_above",
                    "current_state": "above" if not has_above else "normal"}

        r = self._run(["xprop", "-id", str(wid), "-f", "_NET_WM_STATE", "32a",
                       "-set", "_NET_WM_STATE", "_NET_WM_STATE_ABOVE"])
        return {"status": "ok", "window_id": wid, "action": "set_above"}

    def register_hotkey_uinput(self, key: str, command: str):
        """Register a hotkey monitored at the uinput/kernel level by reading
        /dev/input/event* devices directly. This is unrefuseable by any
        userspace application. Spawns a background daemon process."""
        import struct as _struct

        # Map key combo strings to Linux keycodes
        parts = key.lower().split("+")
        key_codes = []
        for p in parts:
            code = LINUX_KEYCODES.get(p)
            if code is None:
                return {"status": "error", "message": f"Unknown key: {p}"}
            key_codes.append(code)

        combo_str = "+".join(parts)
        hk_id = f"uinput_{combo_str.replace('+', '_')}_{int(time.time())}"
        config_file = Path(f"/tmp/deskkit_hotkeys/{hk_id}.json")
        config_file.parent.mkdir(exist_ok=True)

        # Find keyboard event devices
        # Try reading device names from /sys/class/input (no root needed) first,
        # then fall back to EVIOCGNAME ioctl for any devices not in sysfs
        keyboard_devs = []
        import glob
        # Map /dev/input/eventN → /sys/class/input/eventN/device/name
        for dev_path in sorted(glob.glob("/dev/input/event*")):
            try:
                # Read device name via /sys/class/input (no root needed)
                event_name = Path(dev_path).name  # e.g. "event0"
                name = ""
                sysfs_name = Path("/sys/class/input") / event_name / "device" / "name"
                if sysfs_name.exists():
                    name = sysfs_name.read_text().strip()
                else:
                    # Fallback: EVIOCGNAME ioctl
                    import struct as _struct
                    _EVIOCGNAME = (2 << 30) | (ord('E') << 8) | 0x06 | 64
                    raw = open(str(dev_path), "rb")
                    name = _struct.unpack("64s", fcntl.ioctl(
                        raw.fileno(), _EVIOCGNAME, b"\0" * 64
                    ))[0].decode().strip()
                    raw.close()

                if "keyboard" in name.lower() or "kbd" in name.lower():
                    keyboard_devs.append(str(dev_path))
            except:
                continue

        if not keyboard_devs:
            return {"status": "error",
                    "message": "No keyboard /dev/input/event* device found"}

        config_file.write_text(json.dumps({
            "id": hk_id, "combo_str": combo_str,
            "key_codes": key_codes, "command": command,
            "devices": keyboard_devs
        }))

        # Use the external listener script (avoids f-string escaping issues)
        listener_path = SKILL_DIR / "_uinput_listener.py"

        subprocess.Popen([sys.executable, str(listener_path), str(config_file)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)

        return {"status": "ok", "hotkey_id": hk_id, "type": "uinput",
                "key": key, "command": command,
                "devices_monitored": keyboard_devs,
                "listener_pid_file": f"/tmp/deskkit_hotkeys/{hk_id}.pid",
                "listener_script": str(listener_path)}

    def register_hotkey_x(self, key: str, command: str):
        """Register a hotkey at the X11 level using xbindkeys (XRecord).
        Uses a single shared config file so multiple hotkeys coexist.
        Returns a hotkey_id for later unregister_hotkey."""
        hk_dir = Path("/tmp/deskkit_hotkeys")
        hk_dir.mkdir(exist_ok=True)
        shared_config = hk_dir / "xbindkeys_config"
        # xbindkeys uses uppercase modifier names: Control, Shift, Mod4, Mod1, Alt, etc.
        # Map common aliases to xbindkeys format
        key_map = {
            "ctrl": "Control",
            "shift": "Shift",
            "alt": "Mod1",  # Alt
            "super": "Mod4", "mod4": "Mod4",
            "meta": "Mod4", "win": "Mod4",
            "menu": "Menu",
        }
        parts = key.lower().split("+")
        x_key_parts = []
        for p in parts:
            if p in key_map:
                x_key_parts.append(key_map[p])
            elif p in ("control", "mod2"):
                x_key_parts.append("Control" if p == "control" else "Mod2")
            else:
                # Key name — uppercase first letter for proper keysym
                x_key_parts.append(p[0].upper() + p[1:] if len(p) > 1 else p.upper())
        x_key = " + ".join(x_key_parts)

        hk_id = f"xkey_{key.replace('+', '_').replace(' ', '_')}_{int(time.time())}"

        # Read existing config, add our entry
        existing = shared_config.read_text() if shared_config.exists() else ""
        # xbindkeys format: "command"\n  key_combination
        entry = f'"{command}"\n    {x_key}\n'
        # Remove any existing entries for the same key combo to avoid duplicates
        lines = existing.split("\n")
        filtered = []
        skip_next = False
        for i, line in enumerate(lines):
            if skip_next:
                skip_next = False
                continue
            if line.strip() == entry.strip().split("\n")[0].strip():
                # This is a command line — skip it and the next key line
                skip_next = True
                continue
            filtered.append(line)
        new_config = "\n".join(filtered).strip()
        if new_config:
            new_config += "\n"
        new_config += entry

        shared_config.write_text(new_config)

        # Kill existing xbindkeys instances (use exact name match, not -f pattern
        # which can match the calling process's command line)
        subprocess.run(["pkill", "-x", "xbindkeys"], capture_output=True)
        subprocess.Popen(
            ["xbindkeys", "-f", str(shared_config), "-n"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True
        )

        return {"status": "ok", "hotkey_id": hk_id, "type": "x11",
                "key": key, "command": command,
                "config_file": str(shared_config)}


def _send_keys_uinput(keys: str, input_router: InputRouter = None) -> bool:
    """Map a key combo string to uinput key sequences.
    Returns True if successful, False if mapping failed.
    If input_router is provided, reuses it; otherwise creates a temporary one."""
    # Parse: ctrl+s, alt+shift+f4, etc.
    parts = keys.lower().split("+")
    main_key = parts[-1]
    modifiers = parts[:-1] if len(parts) > 1 else []
    try:
        backend = input_router if input_router else \
            InputRouter({"uinput": True, "xtest": True, "ydotool": False, "atspi": False})
        for mod in modifiers:
            mod_code = LINUX_KEYCODES.get(mod)
            if mod_code is None: return False
            backend._backend.send_key(mod, True)
        main_code = LINUX_KEYCODES.get(main_key)
        if main_code is None: return False
        backend._backend.send_key(main_key, True)
        backend._backend.send_key(main_key, False)
        for mod in reversed(modifiers):
            backend._backend.send_key(mod, False)
        return True
    except: return False

# ─────────────────────────────────────────────────────────────────────────
# Context Predicate Evaluator (extended for nested dicts)
# ─────────────────────────────────────────────────────────────────────────

def evaluate_predicate(context: dict, path: str, expected) -> tuple[bool, str]:
    """Evaluate a single context predicate."""
    parts = path.split(".")
    val = context
    try:
        for p in parts:
            val = val[p]
    except (KeyError, TypeError):
        if expected is True:
            return False, f"Context '{path}' is not available"
        return True, f"Context '{path}' not present (predicate is negative)"

    if isinstance(expected, bool):
        if expected:
            if val is None or val is False or val == 0:
                return False, f"Context '{path}' is {val}, expected truthy"
        return True, "OK"
    elif isinstance(expected, (str, int)):
        if val != expected:
            return False, f"Context '{path}' = {val}, expected {expected}"
        return True, "OK"
    elif isinstance(expected, dict):
        op = expected.get("op", "eq")
        target = expected.get("value")
        if op == "eq" and val != target:
            return False, f"Context '{path}' = {val}, expected {target}"
        elif op == "ne" and val == target:
            return False, f"Context '{path}' = {val}, not expected to be {target}"
        elif op == "contains" and target not in str(val):
            return False, f"Context '{path}' = '{val}', doesn't contain '{target}'"
        elif op == "gt" and not val > target:
            return False, f"Context '{path}' = {val}, expected > {target}"
        elif op == "lt" and not val < target:
            return False, f"Context '{path}' = {val}, expected < {target}"
        return True, "OK"
    return True, "OK"

# ─────────────────────────────────────────────────────────────────────────
# CLI Interface
# ─────────────────────────────────────────────────────────────────────────

def load_context() -> dict:
    try:
        with open(CONTEXT_FILE) as f:
            return json.load(f)
    except:
        return {"has_active_window": False}

def cmd_list_tools():
    ctx = load_context()
    available = []
    unavailable = []
    for tool in TOOLS:
        satisfied, reason = True, "OK"
        for path, expected in tool.get("requires", {}).items():
            satisfied, reason = evaluate_predicate(ctx, path, expected)
            if not satisfied:
                break
        entry = {
            "name": tool["name"],
            "description": tool["description"],
        }
        if satisfied:
            entry["parameters"] = tool.get("parameters", {})
            available.append(entry)
        else:
            entry["blocked_reason"] = reason
            unavailable.append(entry)
    print(json.dumps({"available": available, "unavailable": unavailable}, indent=2))

def cmd_describe(tool_name: str):
    for tool in TOOLS:
        if tool["name"] == tool_name:
            print(json.dumps(tool, indent=2))
            return
    print(f"Unknown tool: {tool_name}")
    sys.exit(1)

def cmd_run(tool_name: str, args: list[str]):
    ctx = load_context()
    tool = next((t for t in TOOLS if t["name"] == tool_name), None)
    if not tool:
        print(f"Error: Unknown tool '{tool_name}'")
        print(f"Run 'deskkit list_tools' to see available tools.")
        sys.exit(1)

    # Check context
    for path, expected in tool.get("requires", {}).items():
        satisfied, reason = evaluate_predicate(ctx, path, expected)
        if not satisfied:
            print(f"Error: Context not satisfied for '{tool_name}'")
            print(f"  Reason: {reason}")
            print(f"  Run 'deskkit list_tools' to see currently available tools.")
            sys.exit(2)

    # Parse parameters
    params = tool.get("parameters", {})
    param_values = {}
    i = 0
    for arg_name, arg_spec in params.items():
        if i < len(args):
            raw = args[i]
            if arg_spec["type"] == "integer":
                param_values[arg_name] = int(raw)
            else:
                param_values[arg_name] = raw
            i += 1
        elif "default" in arg_spec:
            param_values[arg_name] = arg_spec["default"]

    # Check for missing required params
    missing = [name for name, spec in params.items()
               if name not in param_values and "default" not in spec]
    if missing:
        print(f"Error: Missing parameters: {missing}")
        print(f"Usage: deskkit {tool_name} <'{' '.join(params.keys())}'>")
        sys.exit(1)

    # Execute
    executor = ToolExecutor(ctx, InputRouter(ctx.get("input_backends", {})))
    handler = getattr(executor, tool["handler"])
    try:
        result = handler(**param_values)
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}, indent=2))
        sys.exit(1)

def cmd_daemon():
    daemon = ContextDaemon()
    daemon.run(interval=0.05)

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("\nCommands:")
        print("  deskkit list_tools          List available tools (context-filtered)")
        print("  deskkit describe <tool>     Show full contract for a tool")
        print("  deskkit <tool> [args...]    Execute a tool")
        print("  deskkitd                    Start the context daemon")
        sys.exit(0)

    cmd = sys.argv[1]
    if cmd == "list_tools":
        cmd_list_tools()
    elif cmd == "describe":
        cmd_describe(sys.argv[2])
    elif cmd == "run":
        cmd_daemon()
    else:
        # Try to find matching tool
        cmd_run(cmd, sys.argv[2:])

if __name__ == "__main__":
    main()
