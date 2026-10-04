# detauto

A 100% deterministic, Pascal-based desktop automation driver that replaces
the Hermes-wrapped `computer-use-linux` CUA driver. Built on `uinput`,
X11, and `/dev/input/event*`, with multiple redundant interaction routes,
phantom-window trimming, active-window importance ranking, and focus control.

## Architecture

```
detauto (daemon)
 ├── TUinputBackend       ── kernel-level injection (/dev/uinput)
 ├── TInputEvtDaemon      ── below-X11 hotkey listener (/dev/input/event*)
 ├── TX11Backend          ── X11 window mgmt + X11-level hotkeys
 ├── TIpcServer           ── Unix socket IPC (/tmp/detauto.sock)
 └─ event loop           ── select() multiplexes IPC + X11 + epoll

detauto (CLI)
 ├── TIpcClient            ── connects to daemon, sends commands
 └── TCliApp               ── arg parser + dispatcher

CamoFox browser ──REST────┐
                         ├── detauto daemon
UI.Vision bridge ───────┘
```

### Triple input routing

All injection goes through uinput first (kernel-level, deterministic). If
uinput fails, falls back to X11-level operations via `xdotool`, and finally
to `ydotool` userspace injection.

### Hotkey layers

| Layer         | Source                | Unit                  |
|---------------|-----------------------|-----------------------|
| Below X11     | `/dev/input/event*`   | `detauto_inputevt.pas`|
| At X11        | `XGrabKey`            | `detauto_x11keys.pas` |
| Above X11     | `uinput` key injection  | `detauto_uinput.pas`   |

### Phantom window filtering

A window is treated as a phantom if it has **no WM_NAME** and **no WM_CLASS**.
Phantoms are force-unmapped via `XUnmapWindow` when trimmed.

### Window importance ranking

Windows are ranked by:
1. **Active window** (+1000) — currently focused
2. **Has WM_CLASS** (+200)
3. **Recent focus** (+100) — tracked via focus-change events
4. **Not phantom** (+50)
5. **Has _NET_WM_PID** (+50)
6. **Title non-empty** (+25)

Top-ranked windows are promoted to focus via `_NET_ACTIVE_WINDOW` +
`XSetInputFocus` + `XRaiseWindow`.

## Build

```bash
# Requires: fpc, libx11-dev, /dev/uinput access
make          # builds detauto binary in build/
sudo make install   # copies to /usr/local/bin/detauto
```

### Compiling individual units

```bash
fpc -Mobjfpc -Sh -Fuunits -FUbuild -c units/detauto_types.pas
fpc -Mobjfpc -Sh -Fuunits -FUbuild -c units/detauto_uinput.pas
fpc -Mobjfpc -Sh -Fuunits -FUbuild -c units/detauto_inputevt.pas
fpc -Mobjfpc -Sh -Fuunits -FUbuild -c units/detauto_x11keys.pas
fpc -Mobjfpc -Sh -Fuunits -FUbuild -c units/detauto_ipc.pas
fpc -Mobjfpc -Sh -Fuunits -FUbuild detauto.lpr
```

## Usage

### Daemon mode

```bash
sudo detauto --daemon &
```

Requires `sudo` for `/dev/uinput` and `/dev/input/event*` access.

### CLI commands

```
detauto ping                     Check daemon health
detauto hotkey Ctrl+Alt+T type:hello  Register a hotkey
detauto type Hello World           Type text via uinput
detauto mouse 1920 1080           Move pointer (relative)
detauto click 1                  Left click
detauto windows                  List all windows with importance
detauto focus Firefox            Focus window by name
detauto trim                     Unmap phantom windows
detauto quit                     Shut down daemon
```

### Coordination with CamoFox

```python
# CamoFox REST API drives the browser; detauto provides deterministic
# hotkeys and window management that work alongside it.
requests.post("http://localhost:9177/browser", json={"url": "..."})
# detauto --daemon handles Ctrl+Alt+T to type into the focused element
```

### Coordination with UI.Vision

UI.Vision runs in a browser tab; detauto's phantom-trimming and focus
commands ensure the correct window is active for UI.Vision playback.
The IPC socket lets UI.Vision's orchestrator trigger detauto commands
via simple HTTP-to-Unix-socket proxying.

## Files

| File                    | Purpose                          |
|-------------------------|----------------------------------|
| `detauto_types.pas`     | Shared types, constants, ParseKeyCombo |
| `detauto_uinput.pas`    | Kernel-level injection (/dev/uinput) |
| `detauto_inputevt.pas`  | Below-X11 event listener (/dev/input) |
| `detauto_x11keys.pas`   | X11 window mgmt + X11 hotkeys    |
| `detauto_ipc.pas`       | Unix socket IPC + CLI dispatcher |
| `detauto.lpr`           | Main program (daemon + CLI)      |
| `Makefile`              | Build system                     |

## Key ioctl values

| Macro           | Value         | Calculated via         |
|-----------------|---------------|------------------------|
| `UI_DEV_CREATE` | `_IO('U', 1)` | `_IOC_NONE, dir=0`     |
| `UI_SET_EVBIT`  | `_IOW('U',100)`| `_IOC_WRITE, dir=1`   |
| `UI_SET_KEYBIT` | `_IOW('U',101)`| `_IOC_WRITE, dir=1`   |
| `UI_SET_RELBIT` | `_IOW('U',102)`| `_IOC_WRITE, dir=1`   |
