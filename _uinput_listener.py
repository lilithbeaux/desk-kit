#!/usr/bin/env python3
"""Uinput-level hotkey listener — monitors /dev/input/event* devices directly.
Unrefuseable by any userspace application because it reads hardware events
at the kernel level via /dev/input/event*."""
import json, os, struct, select, subprocess, signal, sys

CONFIG = sys.argv[1]
with open(CONFIG) as f:
    cfg = json.load(f)

KEY_CODES = set(cfg["key_codes"])
COMMAND = cfg["command"]
COMBO = cfg.get("combo_str", "")
HK_ID = cfg["id"]

# Linux input_event struct on 64-bit:
#   __u64 tv_sec; __u64 tv_usec; __u16 type; __u16 code; __s32 value;
# = 24 bytes total
EVENT_FMT = "=QQHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)
EV_KEY = 0x01

# Track currently pressed keys
pressed = set()
running = True

def handle_signal(sig, frame):
    global running
    running = False

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)

DEVS = cfg.get("devices", [])
ev_fds = []
for dev in DEVS:
    try:
        f = open(dev, "rb")
        # Device path is pre-resolved — open and start reading
        ev_fds.append(f)
    except:
        continue

pid_file = f"/tmp/deskkit_hotkeys/{HK_ID}.pid"
with open(pid_file, "w") as pf:
    pf.write(str(os.getpid()))

while running:
    ready, _, _ = select.select(ev_fds, [], [], 0.1)
    for f in ready:
        try:
            data = f.read(EVENT_SIZE)
            if len(data) < EVENT_SIZE:
                continue
            _, _, etype, ecode, evalue = struct.unpack(EVENT_FMT, data)
            if etype != EV_KEY:
                continue
            if evalue == 1:  # key press
                pressed.add(ecode)
                if KEY_CODES.issubset(pressed):
                    subprocess.Popen(COMMAND, shell=True)
                    pressed.clear()
            elif evalue == 0:  # key release
                pressed.discard(ecode)
        except:
            continue

# Cleanup
try:
    os.unlink(pid_file)
except:
    pass
