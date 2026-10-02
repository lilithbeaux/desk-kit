# 617 Browser Build Instructions

## Prerequisites

| Package | Version | Install |
|---------|---------|---------|
| FPC | 3.2.2 | `sudo apt install fp-compiler` |
| Lazarus | 4.4 | `sudo apt install lazarus` |
| CEF4Delphi | 131.4.1 | `/home/lilareyon/CEF4Delphi/` |
| libcef.so | 131.x | In CEF4Delphi Release/ directory |
| X11 | — | `sudo apt install libx11-dev libxext-dev` |

## Build

```bash
cd 617-browser/

# GUI mode (windowed with toolbar, tabs, address bar)
lazbuild 617_browser.lpi

# Headless mode (for Xvfb / automated use)
lazbuild 617_browser_headless.lpi
```

## Run

```bash
# GUI mode (requires X11 display)
./617_browser

# Headless mode (requires Xvfb)
xvfb-run -a ./617_browser_headless
```

## IPC Socket API

Both modes create a Unix domain socket for external control:

- **GUI:** `/tmp/617_browser.sock`
- **Headless:** `/tmp/617_headless.sock`

### Commands (JSON over socket)

```bash
# Navigate to URL
echo '{"cmd":"navigate","url":"https://example.com"}' | socat - /tmp/617_browser.sock

# Click at coordinates
echo '{"cmd":"click","x":100,"y":200}' | socat - /tmp/617_browser.sock

# Type text
echo '{"cmd":"type","text":"hello"}' | socat - /tmp/617_browser.sock

# Get page source
echo '{"cmd":"get_source"}' | socat - /tmp/617_browser.sock

# Take screenshot
echo '{"cmd":"take_screenshot","path":"/tmp/screenshot.png"}' | socat - /tmp/617_browser.sock

# Set proxy
echo '{"cmd":"set_proxy","proxy":"http://127.0.0.1:8080"}' | socat - /tmp/617_browser.sock

# Shutdown
echo '{"cmd":"shutdown"}' | socat - /tmp/617_browser.sock
```

## Project Structure

```
617-browser/
├── ucontrollerbrowser.pas          # Main controller (1000 lines)
├── interfaces.pas                  # CEF4Delphi interface implementations
├── ucontrollerbrowser.lfm          # Form layout (toolbar, tabs, status)
├── 617_browser.lpr                 # GUI entry point
├── 617_browser_headless.lpr        # Headless entry point
├── 617_browser.lpi                 # Lazarus project (GUI)
├── 617_browser_headless.lpi        # Lazarus project (headless)
├── SimpleBrowser.ico               # Application icon
└── README.md                       # This file
```

## Remote Debugging

Both modes enable Chrome DevTools Protocol on different ports:
- **GUI:** `--remote-debugging-port=9224`
- **Headless:** `--remote-debugging-port=9222`
