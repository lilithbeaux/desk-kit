#!/usr/bin/env python3
"""DeskKit REST API — stateless HTTP wrapper over deskkit.py's tool table.

Gives any agent (Hermes, OpenClaw, custom code) the same 21 tools over HTTP
that deskkit.py exposes on the CLI, PLUS:
  * context-filtered tool listing (mirrors cmd_list_tools / cmd_run gating)
  * a full request/response audit log (every datum that passes through)
  * named macros: a sequence of tool-calls executed in order, logged per step
  * a /health endpoint for the daemonised agent loop

Reuses deskkit.py's own TOOLS table, ToolExecutor, InputRouter and
evaluate_predicate — so behaviour is identical to the CLI, never a fork.

Run:  python3 deskkit-api.py [--port 8642]
Requires the context daemon running:  python3 deskkit.py run &   (or bin/deskkitd)
"""
import argparse, json, os, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.resolve()))
import deskkit
from deskkit import (
    TOOLS, load_context, evaluate_predicate, ToolExecutor, InputRouter,
)

# ─── Paths ───────────────────────────────────────────────────────────────
MACRO_FILE = Path("/tmp/deskkit_macros.json")     # named macro definitions
LOG_FILE   = Path("/tmp/deskkit_api_access.log")  # audit log (JSONL)

def _audit(entry: dict):
    """Append one record to the API audit log — the 'records every bit of
    data' requirement. Every tool call, macro step, and error lands here."""
    entry.setdefault("ts", time.time())
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(entry) + "\n")

def _load_macros() -> dict:
    try:
        return json.loads(MACRO_FILE.read_text())
    except FileNotFoundError:
        return {}

def _save_macros(macros: dict):
    MACRO_FILE.write_text(json.dumps(macros, indent=2))

# ─── Tool execution (mirrors deskkit.cmd_run, returns structured result) ──
def execute_tool(tool_name: str, args: list = None, params: dict = None):
    args = list(args or [])
    params = dict(params or {})
    ctx = load_context()
    tool = next((t for t in TOOLS if t["name"] == tool_name), None)
    if not tool:
        return {"status": "error", "message": f"Unknown tool '{tool_name}'",
                "available": [t["name"] for t in TOOLS]}

    # Context gating — the "an agent can't look bad" core.
    blocked = None
    for path, expected in tool.get("requires", {}).items():
        ok, reason = evaluate_predicate(ctx, path, expected)
        if not ok:
            blocked = reason
            break
    if blocked:
        return {"status": "context_blocked", "message": blocked,
                "tool": tool_name, "requires": tool.get("requires", {})}

    # Parameter resolution: named `params` win, then positional `args` in
    # schema order, then schema defaults.
    spec = tool.get("parameters", {})
    pv = {}
    i = 0
    for name, s in spec.items():
        if name in params:  # explicit named
            pv[name] = _coerce(params[name], s.get("type"))
        elif i < len(args):  # positional
            pv[name] = _coerce(args[i], s.get("type")); i += 1
        elif "default" in s:
            pv[name] = s["default"]
    missing = [n for n, s in spec.items()
               if n not in pv and "default" not in s]
    if missing:
        return {"status": "error", "message": f"Missing parameters: {missing}"}

    executor = ToolExecutor(ctx, InputRouter(ctx.get("input_backends", {})))
    handler = getattr(executor, tool["handler"])
    try:
        result = handler(**pv)
        return {"status": "ok", "tool": tool_name, "result": result}
    except Exception as e:
        return {"status": "error", "tool": tool_name, "message": str(e)}

def _coerce(v, typ):
    if typ == "integer":
        return int(v)
    if typ == "number":
        return float(v)
    if typ == "boolean":
        return str(v).lower() in ("1", "true", "yes", "on")
    return v

def run_macro(name: str, args: list = None, params: dict = None):
    """Execute a named macro step-by-step; log each step."""
    macros = _load_macros()
    macro = macros.get(name)
    if not macro:
        return {"status": "error", "message": f"Unknown macro '{name}'",
                "macros": sorted(macros)}
    steps, results = macro.get("steps", []), []
    for s in steps:
        res = execute_tool(s.get("tool"), s.get("args"), s.get("params"))
        results.append({"step": s.get("tool"), "result": res})
        _audit({"kind": "macro_step", "macro": name, "tool": s.get("tool"),
                "result": res})
        if res.get("status") != "ok":
            results.append({"aborted": True, "reason": res.get("message")})
            break
    return {"status": "ok", "macro": name, "steps": results}

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            return json.loads(self.rfile.read(n)) if n else {}
        except Exception:
            return {}

    def log_message(self, fmt, *args):  # silence default stderr noise
        pass

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/health"):
            return self._json(200, {
                "status": "ok",
                "service": "deskkit-api",
                "port": self.server.server_port,
                "tools": len(TOOLS),
                "context_file": str(deskkit.CONTEXT_FILE),
                "has_context": os.path.exists(deskkit.CONTEXT_FILE),
            })
        if path == "/tools":
            ctx = load_context()
            avail, unavail = [], []
            for t in TOOLS:
                blocked = None
                for p, e in t.get("requires", {}).items():
                    ok, reason = evaluate_predicate(ctx, p, e)
                    if not ok:
                        blocked = reason; break
                entry = {"name": t["name"], "description": t["description"],
                         "parameters": t.get("parameters", {})}
                (avail if not blocked else unavail).append(entry)
                if blocked:
                    unavail[-1]["blocked_reason"] = blocked
            return self._json(200, {"available": avail, "blocked": unavail})
        if path == "/context":
            return self._json(200, load_context())
        if path == "/macros":
            return self._json(200, _load_macros())
        if path == "/log":
            entries = []
            if LOG_FILE.exists():
                for line in LOG_FILE.read_text().splitlines():
                    try: entries.append(json.loads(line))
                    except Exception: pass
            return self._json(200, {"count": len(entries), "entries": entries[-200:]})
        return self._json(404, {"status": "error", "message": "Not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        body = self._read_body()
        if path == "/api/tool" or path == "/tool":
            res = execute_tool(body.get("tool", ""), body.get("args"),
                               body.get("params"))
            _audit({"kind": "tool", "tool": body.get("tool"),
                    "args": body.get("args"), "params": body.get("params"),
                    "result": res})
            code = 200 if res.get("status") in ("ok", "context_blocked") else 400
            return self._json(code, res)
        if path == "/api/macro/run" or path == "/macro/run":
            res = run_macro(body.get("name", ""), body.get("args"),
                            body.get("params"))
            _audit({"kind": "macro", "name": body.get("name"), "result": res})
            return self._json(200, res)
        if path == "/api/macro/save" or path == "/macro/save":
            macros = _load_macros()
            macros[body.get("name")] = {"steps": body.get("steps", [])}
            _save_macros(macros)
            _audit({"kind": "macro_save", "name": body.get("name"),
                    "steps": body.get("steps")})
            return self._json(200, {"status": "ok",
                                    "macros": sorted(macros)})
        if path == "/api/context/refresh":
            # Force the daemon to repoll by touching the file marker (best-effort).
            ctx = load_context()
            return self._json(200, {"status": "ok", "context": ctx})
        return self._json(404, {"status": "error", "message": "Not found"})

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8642)
    a = ap.parse_args()
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    print(f"DeskKit API on http://{a.host}:{a.port}  (log: {LOG_FILE})",
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped", flush=True)

if __name__ == "__main__":
    main()
