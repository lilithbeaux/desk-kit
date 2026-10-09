#!/usr/bin/env python3
"""DeskKit — AT-SPI perception + action layer (DW-01b).

WHY THIS FILE EXISTS
--------------------
deskkit.py's original AT-SPI code could never work. It probed
`org.a11y.atspi0` on the accessibility bus, queried the path
`/org/a11y/atspi/accessible/desktop/0`, and called
`org.a11y.atspi.Accessible.GetFocus`. Measured on this host:

    org.a11y.atspi0                    -> boolean false  (no owner, ever)
    org.a11y.atspi.Registry            -> boolean true   (the real name)
    /org/a11y/atspi/accessible/root    -> role "desktop frame" (the real root)
    Accessible.GetFocus                -> UnknownMethod

Consequences: `input_backends.atspi` was permanently False, so the three tools
gated on it (get_focused_element, atspi_click, atspi_read_text) could never be
used; and `AtSpiClient.invoke_action()` returned True whenever dbus-send exited
0 -- reporting success for a call that never landed.

Also measured: `/run/user/<uid>/at-spi/bus` was hardcoded, so the whole layer
breaks on any other uid.

HOW IT WORKS NOW
----------------
1. X11 says which window is active and gives its `_NET_WM_PID` (cheap, already
   available to the daemon).
2. On the accessibility bus, `GetConnectionUnixProcessID` maps each registered
   app tree to a process -- that is the index into AT-SPI.
3. Walk that app's tree looking for STATE_FOCUSED (bit 12 of state word 0),
   bounded by node count and wall-clock budget; widen to every app tree only if
   the narrowed scope comes up empty.
4. Act on the resolved node only through interfaces it actually advertises
   (`org.a11y.atspi.Action`, `org.a11y.atspi.Text`), and report the real reply.

Transports: jeepney (pure-python D-Bus) when importable -- measured 3192
nodes/s against 214 nodes/s spawning dbus-send per node -- otherwise dbus-send.
No mandatory dependency, no vision, no guessing.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import threading
import time

IFACE = "org.a11y.atspi.Accessible"
REGISTRY = "org.a11y.atspi.Registry"
ROOT = "/org/a11y/atspi/accessible/root"
FOCUSED_BIT = 12  # at-spi2 StateType word 0: STATE_FOCUSED

_STRUCT = re.compile(r'string "([^"]+)"\s*\n\s*object path "([^"]+)"')
_UINT = re.compile(r"uint32 (\d+)")
_INT = re.compile(r"int32 (-?\d+)")
_STR = re.compile(r'string "([^"]*)"')


# ── transport ─────────────────────────────────────────────────────────────

def bus_address() -> str:
    """The accessibility bus for *this* user -- never hardcoded to one uid."""
    addr = os.environ.get("AT_SPI_BUS_ADDRESS")
    if addr:
        return addr.split(",")[0]
    return f"unix:path=/run/user/{os.getuid()}/at-spi/bus"


def _load_jeepney():
    """Import jeepney, looking in the vendored dir as well as site-packages."""
    try:
        import jeepney  # noqa: F401
        return jeepney
    except ImportError:
        pass
    candidates = [os.environ.get("DESKKIT_VENDOR_PY"),
                  os.path.expanduser("~/lilareyon/vendor/py"),
                  os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor")]
    for cand in candidates:
        if cand and os.path.isdir(cand) and cand not in sys.path:
            sys.path.append(cand)
            try:
                import jeepney  # noqa: F401
                return jeepney
            except ImportError:
                sys.path.remove(cand)
    return None


class _Conn:
    """One persistent connection, with a clean fallback to dbus-send."""

    def __init__(self):
        self._jeepney = _load_jeepney()
        self._conn = None
        self.transport = "dbus-send"

    def connect(self):
        with _LOCK:
            if not self._jeepney:
                return None
            if self._conn is not None:
                return self._conn
            try:
                from jeepney.io.blocking import open_dbus_connection
                self._conn = open_dbus_connection(bus_address(), enable_fds=False)
                self.transport = "jeepney"
            except Exception:
                self._conn = None
            return self._conn

    def close(self):
        with _LOCK:
            try:
                if self._conn is not None:
                    self._conn.close()
            except Exception:
                pass
            self._conn = None

    def call(self, dest, path, iface_method, args=(), signature=None, timeout=2.0):
        """Call a method, returning the raw first argument (or None on failure).

        The whole send->receive exchange is serialised under _LOCK. jeepney's
        blocking socket is NOT thread-safe: two threads issuing calls on it
        interleave and each consumes the other's reply, then both wait forever
        for a reply that was already delivered. That was the DW-01b daemon
        freeze (context.json stopped updating ~20s after the background AT-SPI
        thread came up alongside the 20Hz context loop).
        """
        with _LOCK:
            conn = self.connect()
            if conn is not None:
                try:
                    from jeepney import DBusAddress, new_method_call
                    iface, method = iface_method.rsplit(".", 1)
                    addr = DBusAddress(path, bus_name=dest, interface=iface)
                    if signature is None:
                        msg = new_method_call(addr, method)
                    else:
                        msg = new_method_call(addr, method, signature, args)
                    reply = conn.send_and_get_reply(msg, timeout=timeout)
                    body = reply.body
                    return body[0] if body else None
                except Exception:
                    # A dead/again-broken connection must not poison later calls
                    self.close()
        return self._call_subprocess(dest, path, iface_method, args, timeout)

    def _call_subprocess(self, dest, path, iface_method, args=(), timeout=2.0):
        cmd = ["dbus-send", f"--bus={bus_address()}", "--print-reply",
               f"--dest={dest}", "--type=method_call", path, iface_method]
        if args:
            cmd += [a if isinstance(a, str) else f"{a[0]}:{a[1]}" for a in args]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            return r.stdout if r.returncode == 0 else None
        except Exception:
            return None


_CONN = _Conn()
_LOCK = threading.RLock()


def _as_pairs(raw):
    """Normalise a GetChildren reply to [(bus, path)] from either transport."""
    if raw is None:
        return []
    if isinstance(raw, str):
        return _STRUCT.findall(raw)
    out = []
    for item in raw:
        try:
            out.append((str(item[0]), str(item[1])))
        except Exception:
            continue
    return out


def _as_uints(raw):
    if raw is None:
        return []
    if isinstance(raw, str):
        return [int(x) for x in _UINT.findall(raw)]
    if isinstance(raw, (list, tuple)):
        return [int(x) for x in raw]
    return [int(raw)]


def _as_str(raw):
    if raw is None:
        return None
    if isinstance(raw, str):
        m = _STR.search(raw.split("variant", 1)[-1])
        return m.group(1) if m else (raw or None)
    if isinstance(raw, (list, tuple)):
        # jeepney returns a D-Bus variant as (signature, value) -- unwrap it
        if len(raw) == 2 and isinstance(raw[0], str) and len(raw[0]) <= 4:
            return str(raw[1])
        return str(raw[0]) if raw else None
    return str(raw)


# ── bus / registry ────────────────────────────────────────────────────────

_AVAIL = {"v": None, "t": 0.0}


def available() -> bool:
    """True when the AT-SPI registry is owned on the accessibility bus.

    Cached for 30s: the 20Hz context loop calls this every cycle, and it is
    a static fact, so hitting the bus each time only multiplies contention
    with the background resolver.
    """
    now = time.time()
    if _AVAIL["v"] is not None and now - _AVAIL["t"] < 30.0:
        return _AVAIL["v"]
    raw = _CONN.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                     "org.freedesktop.DBus.NameHasOwner",
                     ("org.a11y.atspi.Registry",), signature="s")
    if isinstance(raw, bool):
        v = raw
    elif isinstance(raw, str):
        v = "boolean true" in raw.lower()
    else:
        v = bool(raw)
    _AVAIL["v"], _AVAIL["t"] = v, now
    return v


def app_trees():
    """[(bus_name, root_path)] for every application registered with AT-SPI."""
    return _as_pairs(_CONN.call(REGISTRY, ROOT, f"{IFACE}.GetChildren"))


def conn_pid(bus_name: str):
    raw = _CONN.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                     "org.freedesktop.DBus.GetConnectionUnixProcessID",
                     (bus_name,), signature="s")
    u = _as_uints(raw)
    return u[0] if u else None


def active_window_pid():
    """(pid, xprop text) for the window manager's active window."""
    try:
        wid = subprocess.run(["xdotool", "getactivewindow"],
                             capture_output=True, text=True, timeout=2).stdout.strip()
        if not wid:
            return None, None
        out = subprocess.run(["xprop", "-id", wid, "_NET_WM_PID", "WM_CLASS", "_NET_WM_NAME"],
                             capture_output=True, text=True, timeout=2).stdout
        m = re.search(r"_NET_WM_PID\(CARDINAL\) = (\d+)", out)
        return (int(m.group(1)) if m else None), out
    except Exception:
        return None, None


# ── node reads ────────────────────────────────────────────────────────────

def prop(dest, path, name):
    raw = _CONN.call(dest, path, "org.freedesktop.DBus.Properties.Get",
                     (IFACE, name), signature="ss")
    return _as_str(raw)


def state(dest, path):
    return _as_uints(_CONN.call(dest, path, f"{IFACE}.GetState"))


def children(dest, path):
    return _as_pairs(_CONN.call(dest, path, f"{IFACE}.GetChildren"))


def role_name(dest, path):
    return _as_str(_CONN.call(dest, path, f"{IFACE}.GetRoleName"))


def interfaces(dest, path):
    raw = _CONN.call(dest, path, f"{IFACE}.GetInterfaces")
    if isinstance(raw, (list, tuple)):
        return [str(x) for x in raw]
    return re.findall(r'interface "([^"]+)"', raw or "")


def extents(dest, path):
    raw = _CONN.call(dest, path, f"{IFACE}.GetExtents", (0,), signature="u")
    ints = [int(x) for x in _INT.findall(raw)] if isinstance(raw, str) else (
        [int(x) for x in raw] if isinstance(raw, (list, tuple)) else [])
    if len(ints) >= 4:
        return {"x": ints[0], "y": ints[1], "w": ints[2], "h": ints[3]}
    return None


def node_info(dest, path, deep=True):
    info = {"bus": dest, "path": path, "role": role_name(dest, path),
            "name": prop(dest, path, "Name")}
    if deep:
        info["interfaces"] = interfaces(dest, path)
        info["extents"] = extents(dest, path)
    return info


# ── the resolver ──────────────────────────────────────────────────────────

_CACHE = {"ts": 0.0, "result": None}


def _walk(scope, cap, budget, t0, per_app=None):
    """Breadth-first *within each app tree*, one app at a time.

    Measured on this host: a global breadth-first sweep spends its whole budget
    on the shallow top layers of all 29 registered apps and never reaches the
    focused widget; depth-first buries the budget in one branch of one app. The
    shape that actually finds focus is per-app BFS, apps in registration order.
    """
    walked = 0
    for entry in scope:
        queue, seen, local = [entry], set(), 0
        while queue and walked < cap and (time.time() - t0) < budget:
            dest, path = queue.pop(0)
            if (dest, path) in seen:
                continue
            seen.add((dest, path))
            walked += 1
            local += 1
            if per_app and local > per_app:
                break
            st = state(dest, path)
            if st and (st[0] >> FOCUSED_BIT) & 1:
                return walked, node_info(dest, path)
            for c in children(dest, path):
                if c not in seen:
                    queue.append(c)
    return walked, None


def resolve_focus(cap: int = 1500, budget: float = 2.0, widen: bool = True,
                  max_age: float = 0.0) -> dict:
    """Resolve the focused accessible node.

    max_age > 0 serves a cached result and refreshes at most that often -- the
    daemon path uses it so the 20 Hz context loop never blocks on AT-SPI.
    """
    if max_age > 0 and _CACHE["result"] is not None \
            and (time.time() - _CACHE["ts"]) < max_age:
        return _CACHE["result"]

    t0 = time.time()
    if not available():
        res = {"status": "error", "focus": None,
               "message": "AT-SPI registry is not owned on the accessibility bus "
                          f"({bus_address()}) -- no accessibility bridge running"}
        _CACHE.update(ts=time.time(), result=res)
        return res

    pid, xinfo = active_window_pid()
    trees = app_trees()
    narrowed = [(b, p) for (b, p) in trees if pid and conn_pid(b) == pid]

    walked, hit, scope_note = 0, None, ""
    if narrowed:
        w, hit = _walk(narrowed, cap, budget, t0)
        walked += w
        scope_note = f"active window pid {pid}"
    if hit is None and widen:
        remaining = max(cap - walked, 60)
        w, hit = _walk(trees, remaining, max(budget - (time.time() - t0), 0.3), t0)
        walked += w
        scope_note = (scope_note + " then whole registry") if scope_note else "whole registry"

    res = {
        "status": "ok" if hit else "error",
        "focus": hit,
        "message": None if hit else (
            "no accessible reported STATE_FOCUSED among "
            f"{len(trees)} registered app trees (walked {walked} nodes)"
            + (" — the active window's toolkit may not expose an accessibility tree"
               if narrowed else "")),
        "scope": scope_note or "whole registry",
        "nodes_walked": walked,
        "seconds": round(time.time() - t0, 3),
        "transport": _CONN.transport,
    }
    _CACHE.update(ts=time.time(), result=res)
    return res


def cached_focus() -> dict:
    """Daemon-friendly: cheap, at most one refresh every few seconds."""
    return resolve_focus(cap=250, budget=0.35, widen=False, max_age=3.0)


def current_focus() -> dict:
    """Latest resolved focus without ever touching the bus (daemon-safe)."""
    return _CACHE["result"] or {"status": "error", "focus": None,
                                "message": "AT-SPI focus not resolved yet"}


_REFRESH_THREAD = None


def start_background_refresh(interval: float = 2.0, cap: int = 1500,
                             budget: float = 2.0):
    """Resolve focus on a background thread so callers never block on D-Bus.

    Measured cost of one full resolution: ~0.30 s (jeepney). Doing that inline
    from the 20 Hz context loop would stall it; a thread keeps the loop free and
    `current_focus()` stays instant.
    """
    global _REFRESH_THREAD
    if _REFRESH_THREAD is not None and _REFRESH_THREAD.is_alive():
        return _REFRESH_THREAD

    def _loop():
        while True:
            try:
                resolve_focus(cap=cap, budget=budget, widen=True, max_age=0)
            except Exception:
                pass
            time.sleep(interval)

    import threading
    _REFRESH_THREAD = threading.Thread(target=_loop, name="atspi-focus", daemon=True)
    _REFRESH_THREAD.start()
    return _REFRESH_THREAD


# ── actions (honest about whether they landed) ────────────────────────────

def do_action(node, index: int = 0) -> dict:
    if not node:
        return {"status": "error", "message": "no AT-SPI target resolved"}
    ifaces = node.get("interfaces") or interfaces(node["bus"], node["path"])
    if "org.a11y.atspi.Action" not in ifaces:
        return {"status": "error",
                "message": f"target does not implement org.a11y.atspi.Action "
                           f"(role={node.get('role')!r}, has {len(ifaces)} interfaces)",
                "node": {k: node.get(k) for k in ("role", "name", "path")}}
    raw = _CONN.call(node["bus"], node["path"], "org.a11y.atspi.Action.DoAction",
                     (index,), signature="i")
    ok = raw is True or (isinstance(raw, str) and "boolean true" in raw.lower())
    if ok:
        return {"status": "ok", "method": "atspi", "action_index": index,
                "target": {"role": node.get("role"), "name": node.get("name")}}
    return {"status": "error",
            "message": f"DoAction({index}) was not accepted",
            "raw": (raw if isinstance(raw, str) else repr(raw))[:200] if raw is not None else None}


def read_text(node) -> dict:
    if not node:
        return {"status": "error", "message": "no AT-SPI target resolved"}
    ifaces = node.get("interfaces") or interfaces(node["bus"], node["path"])
    if "org.a11y.atspi.Text" not in ifaces:
        return {"status": "error",
                "message": f"target does not implement org.a11y.atspi.Text "
                           f"(role={node.get('role')!r})",
                "node": {k: node.get(k) for k in ("role", "name", "path")}}
    raw = _CONN.call(node["bus"], node["path"], "org.a11y.atspi.Text.GetText",
                     (0, -1), signature="ii")
    text = _as_str(raw)
    if text is None:
        return {"status": "error", "message": "GetText returned no string"}
    return {"status": "ok", "text": text, "length": len(text),
            "target": {"role": node.get("role"), "name": node.get("name")}}


def focused_element() -> dict:
    """Full read of the focused element, for the get_focused_element tool."""
    r = resolve_focus()
    if not r.get("focus"):
        return {"status": "error", "message": r.get("message"),
                "nodes_walked": r.get("nodes_walked")}
    f = r["focus"]
    return {"status": "ok", "element": f, "scope": r.get("scope"),
            "nodes_walked": r.get("nodes_walked"), "seconds": r.get("seconds")}


if __name__ == "__main__":
    import json
    print("bus:", bus_address(), "| transport:", _CONN.transport)
    print("registry available:", available())
    print("app trees:", len(app_trees()))
    print(json.dumps(resolve_focus(), indent=2)[:1400])
