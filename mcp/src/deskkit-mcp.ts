#!/usr/bin/env node
/**
 * DeskKit MCP Server
 *
 * Exposes DeskKit's 19 desktop automation tools via the Model Context Protocol (MCP).
 * This allows any MCP-compatible AI agent to use DeskKit for:
 *   - uinput-level mouse/keyboard injection (unrefuseable)
 *   - X11 and kernel-level hotkey listeners
 *   - Phantom-filtered window enumeration and 3-method focus
 *   - Always-on-top manipulation
 *   - 617 Browser IPC control
 *
 * Communication model: subprocess call to `deskkit.py <tool> <args>`,
 * which returns JSON. The deskkit daemon (`deskkit.py run`) must be started
 * separately to maintain context state in /tmp/deskkit_context.json.
 *
 * Installation (Claude Desktop):
 *   {
 *     "mcpServers": {
 *       "deskkit": {
 *         "command": "node",
 *         "args": ["/path/to/desk-kit/mcp/dist/deskkit-mcp.js"],
 *         "env": { "DESKKIT_PY": "/path/to/desk-kit/deskkit.py" }
 *       }
 *     }
 *   }
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { spawn } from 'child_process';
import * as path from 'path';

// ── Configuration ───────────────────────────────────────────────

const DESKKIT_PY = path.resolve(
  process.env.DESKKIT_PY || path.join(path.dirname(import.meta.url), '..', 'deskkit.py')
);
const DESKKIT_DIR = path.dirname(DESKKIT_PY);

// ── Tool Definitions ────────────────────────────────────────────
// Mirror deskkit.py's TOOLS array exactly: same name, same param order, same
// descriptions. The MCP client uses these to present tools to the LLM.

const TOOLS = [
  {
    name: 'list_tools',
    description: 'List all available DeskKit tools (context-filtered by current state)',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'focus_window',
    description: 'Focus a window by partial title or class match. Methods: auto (try activate→focus→above), activate (EWMH _NET_ACTIVE_WINDOW), focus (X11 XSetInputFocus), above (toggle _NET_WM_STATE_ABOVE to force to front).',
    inputSchema: {
      type: 'object',
      properties: {
        title: { type: 'string', description: 'Partial window title or WM_CLASS to match' },
        method: { type: 'string', enum: ['auto', 'activate', 'focus', 'above'], description: "Focus method (default: 'auto')", default: 'auto' },
      },
      required: ['title'],
      additionalProperties: false,
    },
  },
  {
    name: 'list_windows',
    description: 'List all X11 windows (title + class). Phantom windows with no WM_CLASS are filtered out.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'get_active_title',
    description: 'Get the title of the currently active (focused) window',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'get_window_info',
    description: 'Get detailed info about the active window (pid, class, title, id)',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'type_text',
    description: 'Type text into the focused window via uinput (unrefuseable) or XTEST fallback. Sends each character as separate key events.',
    inputSchema: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'Text to type character by character' },
      },
      required: ['text'],
      additionalProperties: false,
    },
  },
  {
    name: 'send_keys',
    description: 'Send key combinations (e.g. ctrl+s, enter, alt+f4) via uinput or XTEST. Modifiers stay held during main key press.',
    inputSchema: {
      type: 'object',
      properties: {
        keys: { type: 'string', description: "Key combination to send, e.g. 'ctrl+s'" },
      },
      required: ['keys'],
      additionalProperties: false,
    },
  },
  {
    name: 'click_at',
    description: 'Click mouse at absolute (x, y) screen coordinates. Button: 1=left, 2=middle, 3=right.',
    inputSchema: {
      type: 'object',
      properties: {
        x: { type: 'number', description: 'X coordinate (pixels)' },
        y: { type: 'number', description: 'Y coordinate (pixels)' },
        button: { type: 'number', description: 'Button number (1=left, 2=middle, 3=right)', default: 1 },
      },
      required: ['x', 'y'],
      additionalProperties: false,
    },
  },
  {
    name: 'move_cursor',
    description: 'Move cursor to (x, y) screen coordinates without clicking. Uses uinput relative events (EV_REL) to track and move the cursor.',
    inputSchema: {
      type: 'object',
      properties: {
        x: { type: 'number', description: 'X coordinate (pixels)' },
        y: { type: 'number', description: 'Y coordinate (pixels)' },
      },
      required: ['x', 'y'],
      additionalProperties: false,
    },
  },
  {
    name: 'get_cursor_pos',
    description: 'Get current cursor (x, y) position via xdotool',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'get_focused_element',
    description: 'Get the AT-SPI focused element (role, name, actions). Requires AT-SPI accessibility bus active with a focused element.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'atspi_click',
    description: 'Invoke the click action on the currently focused AT-SPI element (GTK-unrefuseable). Requires AT-SPI with a focused element.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'atspi_read_text',
    description: 'Read text content of the AT-SPI focused element. Requires AT-SPI with a focused element.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'clipboard_get',
    description: 'Get current clipboard text content via xclip (fallback: xsel)',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'clipboard_set',
    description: 'Set clipboard text content',
    inputSchema: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'Text to set on clipboard' },
      },
      required: ['text'],
      additionalProperties: false,
    },
  },
  {
    name: 'get_window_geometry',
    description: 'Get geometry (x, y, width, height) of the active window via xdotool',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'resize_window',
    description: 'Resize the active window to specified dimensions (width x height pixels)',
    inputSchema: {
      type: 'object',
      properties: {
        width: { type: 'number', description: 'New width in pixels' },
        height: { type: 'number', description: 'New height in pixels' },
      },
      required: ['width', 'height'],
      additionalProperties: false,
    },
  },
  {
    name: 'register_hotkey',
    description: 'Register a global hotkey via sxhkd. Returns a hotkey_id for later unregister_hotkey. Key format: super+space, ctrl+shift+t, f1 (no "hotkey" prefix).',
    inputSchema: {
      type: 'object',
      properties: {
        key: { type: 'string', description: "Key combination, e.g. 'super+space'" },
        command: { type: 'string', description: 'Shell command to execute when hotkey fires' },
      },
      required: ['key', 'command'],
      additionalProperties: false,
    },
  },
  {
    name: 'register_hotkey_uinput',
    description: 'Register a hotkey at the kernel level by monitoring /dev/input/event* directly. Unrefuseable by any userspace app. Spawns a background listener process.',
    inputSchema: {
      type: 'object',
      properties: {
        key: { type: 'string', description: "Key combo, e.g. 'ctrl+s' or 'shift+f10'" },
        command: { type: 'string', description: 'Shell command to execute on trigger' },
      },
      required: ['key', 'command'],
      additionalProperties: false,
    },
  },
  {
    name: 'register_hotkey_x',
    description: 'Register a hotkey at the X11 level via xbindkeys. Modifiers are normalized (ctrl→Control, shift→Shift, super→Mod4). Uses shared config file.',
    inputSchema: {
      type: 'object',
      properties: {
        key: { type: 'string', description: "X11 key combo, e.g. 'ctrl+s' or 'shift+f11'" },
        command: { type: 'string', description: 'Shell command to execute on trigger' },
      },
      required: ['key', 'command'],
      additionalProperties: false,
    },
  },
  {
    name: 'set_always_on_top',
    description: 'Toggle _NET_WM_STATE_ABOVE on the active window — light-switch approach to window stacking manipulation.',
    inputSchema: {
      type: 'object',
      properties: {
        state: { type: 'string', enum: ['on', 'off', 'toggle'], description: 'on, off, or toggle (default: toggle)', default: 'toggle' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'unregister_hotkey',
    description: 'Remove a previously registered hotkey by hotkey_id. The id was returned by register_hotkey/register_hotkey_uinput/register_hotkey_x.',
    inputSchema: {
      type: 'object',
      properties: {
        id: { type: 'string', description: 'The hotkey_id returned by a register_hotkey* call' },
      },
      required: ['id'],
      additionalProperties: false,
    },
  },
] as const;

// ── Core: invoke a DeskKit tool via subprocess ─────────────────

function callDeskKit(toolName: string, params: Record<string, any>): Promise<string> {
  return new Promise((resolve, reject) => {
    // deskkit.py CLI:  deskkit <tool> <arg1> <arg2> ...
    // Arguments are positional, in the order defined in the TOOL's parameters dict.
    const args: string[] = [toolName];

    // Get the tool definition to know parameter order
    const tool = TOOLS.find((t) => t.name === toolName);
    if (tool) {
      const paramNames = Object.keys(tool.inputSchema.properties || {});
      for (const pname of paramNames) {
        if (params && params[pname] !== undefined) {
          // Convert to string, but preserve numeric types
          const val = params[pname];
          if (typeof val === 'number') {
            args.push(String(val));
          } else if (typeof val === 'string') {
            args.push(val);
          } else {
            args.push(String(val));
          }
        }
      }
    }

    const proc = spawn('python3', [DESKKIT_PY, ...args], {
      cwd: DESKKIT_DIR,
      env: { ...process.env, PYTHONWARNINGS: 'ignore' },
    });

    let stdout = '';
    let stderr = '';

    proc.stdout.on('data', (data) => (stdout += data.toString()));
    proc.stderr.on('data', (data) => (stderr += data));

    proc.on('close', (code) => {
      if (code === 0) {
        const trimmed = stdout.trim();
        try {
          const parsed = JSON.parse(trimmed);
          resolve(JSON.stringify(parsed));
        } catch {
          resolve(trimmed || JSON.stringify({ status: 'ok' }));
        }
      } else {
        reject(new Error(`DeskKit '${toolName}' exited ${code}: ${stderr}`));
      }
    });

    proc.on('error', (err) => {
      reject(new Error(`Failed to spawn DeskKit: ${err.message}`));
    });
  });
}

// ── MCP Server ──────────────────────────────────────────────────

// v0.4 API: Server constructor takes only (name, version). Capabilities are
// inferred automatically from registered setRequestHandler calls.
const server = new Server({
  name: 'deskkit-mcp',
  version: '1.0.0',
});

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map((t) => ({
    name: t.name,
    description: t.description,
    inputSchema: t.inputSchema,
  })),
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params!;

  try {
    const result = await callDeskKit(name, args || {});
    return { content: [{ type: 'text', text: result }] };
  } catch (err: any) {
    return {
      content: [{ type: 'text', text: JSON.stringify({ status: 'error', error: err.message }) }],
      isError: true,
    };
  }
});

// ── Entry point ─────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);

// ── Self-test mode (--test) ─────────────────────────────────────
if (process.argv.includes('--test')) {
  (async () => {
    console.log('DeskKit MCP Server — Self Test');
    console.log('='.repeat(40));

    const tests = [
      { name: 'list_tools', params: {} },
      { name: 'get_cursor_pos', params: {} },
      { name: 'list_windows', params: {} },
      { name: 'get_active_title', params: {} },
    ];

    for (const t of tests) {
      try {
        const result = await callDeskKit(t.name, t.params);
        console.log(`✅ ${t.name}: ${result.substring(0, 200)}`);
      } catch (err: any) {
        console.log(`❌ ${t.name}: ${err.message}`);
      }
    }

    console.log('='.repeat(40));
    console.log('MCP server running on stdio. Connect via Claude Desktop or any MCP client.');
    process.exit(0);
  })();
}
