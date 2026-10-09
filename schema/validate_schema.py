#!/usr/bin/env python3
"""DeskKit schema validator (DW-06).

Cross-checks schema/operations.yaml against the live TOOLS registry in
deskkit.py, so the documented contract cannot silently drift from the
implementation. This is the "every existing tool maps to a schema entry"
verification for DW-06.

Checks
  1. every operation has the required keys, and verbs are unique
  2. every tool in TOOLS binds to exactly one operation, and vice-versa:
     any operation naming a tool must name a tool that exists
  3. for each bound pair, the parameter NAMES match exactly (both ways)
  4. per parameter: type matches; a default present in BOTH must agree;
     a `required: true` param must not carry a code default
  5. preconditions mirror the tool's `requires` keys exactly
  6. side_effects mirror the tool's `updates` keys exactly
  7. implemented == (tool is not None)

Exit 0 when clean, 1 with a report otherwise.

Usage:  python3 schema/validate_schema.py [-v]
"""
from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("ERROR: PyYAML required:  pip install pyyaml")

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))

import deskkit  # noqa: E402  (path inserted above)

SCHEMA_PATH = HERE / "operations.yaml"
REQUIRED_OP_KEYS = {
    "verb", "tool", "category", "summary", "params",
    "target", "preconditions", "result", "side_effects", "implemented",
}
REQUIRED_PARAM_KEYS = {"type", "required"}


def main(argv: list[str]) -> int:
    verbose = "-v" in argv or "--verbose" in argv
    errors: list[str] = []
    warnings: list[str] = []

    doc = yaml.safe_load(SCHEMA_PATH.read_text())
    ops = doc.get("operations") or []
    tools = {t["name"]: t for t in deskkit.TOOLS}

    # 1 ── shape + unique verbs -------------------------------------------------
    by_verb: dict[str, dict] = {}
    for i, op in enumerate(ops):
        verb = op.get("verb", f"<op#{i}>")
        missing = REQUIRED_OP_KEYS - set(op)
        if missing:
            errors.append(f"{verb}: missing keys {sorted(missing)}")
        if verb in by_verb:
            errors.append(f"duplicate verb '{verb}'")
        by_verb[verb] = op
        for pname, spec in (op.get("params") or {}).items():
            pmiss = REQUIRED_PARAM_KEYS - set(spec)
            if pmiss:
                errors.append(f"{verb}.{pname}: param missing {sorted(pmiss)}")
            if not isinstance(spec.get("required"), bool):
                errors.append(f"{verb}.{pname}: 'required' must be a bool")
        if op.get("category") not in (doc.get("categories") or []):
            errors.append(f"{verb}: unknown category {op.get('category')!r}")

    # 2 ── tool binding, both directions ---------------------------------------
    bound: dict[str, str] = {}  # tool name -> verb
    for verb, op in by_verb.items():
        tool = op.get("tool")
        if tool is None:
            if op.get("implemented"):
                errors.append(f"{verb}: implemented=true but no tool bound")
            continue
        if tool not in tools:
            errors.append(f"{verb}: bound tool '{tool}' is not in TOOLS")
            continue
        if tool in bound:
            errors.append(f"tool '{tool}' bound by both {bound[tool]} and {verb}")
        bound[tool] = verb
        if not op.get("implemented"):
            errors.append(f"{verb}: tool bound but implemented=false")
    for name in tools:
        if name not in bound:
            errors.append(f"TOOL '{name}' has no schema entry")

    # 3-7 ── per-tool contract comparison --------------------------------------
    for name, tool in sorted(tools.items()):
        verb = bound.get(name)
        if verb is None:
            continue
        op = by_verb[verb]
        spec_params = op.get("params") or {}
        code_params = tool.get("parameters") or {}

        if set(spec_params) != set(code_params):
            errors.append(
                f"{name}: param names differ — schema={sorted(spec_params)} "
                f"code={sorted(code_params)}"
            )

        for pname in sorted(set(spec_params) & set(code_params)):
            ss, cs = spec_params[pname], code_params[pname]
            if ss.get("type") != cs.get("type"):
                errors.append(
                    f"{name}.{pname}: type {ss.get('type')!r} != code {cs.get('type')!r}"
                )
            if "default" in cs and "default" in ss and ss["default"] != cs["default"]:
                errors.append(
                    f"{name}.{pname}: default {ss['default']!r} != code {cs['default']!r}"
                )
            if ss.get("required") is True and "default" in cs:
                errors.append(
                    f"{name}.{pname}: required=true but code supplies a default "
                    f"{cs['default']!r}"
                )
            if "default" in ss and "default" not in cs and verbose:
                warnings.append(
                    f"{name}.{pname}: schema default {ss['default']!r} not encoded in "
                    f"TOOLS (harmless; DW-07 will fold it in)"
                )

        want_pre = sorted((tool.get("requires") or {}).keys())
        got_pre = sorted(op.get("preconditions") or [])
        if want_pre != got_pre:
            errors.append(f"{name}: preconditions {got_pre} != requires {want_pre}")

        want_eff = sorted((tool.get("updates") or {}).keys())
        got_eff = sorted(op.get("side_effects") or [])
        if want_eff != got_eff:
            errors.append(f"{name}: side_effects {got_eff} != updates {want_eff}")

    # ── report -----------------------------------------------------------------
    n_impl = sum(1 for o in ops if o.get("tool"))
    n_plan = len(ops) - n_impl
    for w in warnings:
        print(f"  warn: {w}")
    if errors:
        print(f"\nSCHEMA MISMATCH — {len(errors)} problem(s):\n")
        for e in errors:
            print(f"  ✗ {e}")
        return 1

    print(
        f"OK  schema/operations.yaml ↔ deskkit.TOOLS in sync\n"
        f"    operations: {len(ops)}  ({n_impl} bound to a tool, {n_plan} planned)\n"
        f"    tools covered: {len(bound)}/{len(tools)}\n"
        f"    verbs: {len(by_verb)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
