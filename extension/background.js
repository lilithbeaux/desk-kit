// DeskKit Commander — background service worker.
// Talks to the DeskKit REST API (127.0.0.1:8642) and the local
// reasoning lane (127.0.0.1:8773). No LLM in the loop — pure plumbing.

const DESKKIT = "http://127.0.0.1:8642";
const LOCAL_LANE = "http://127.0.0.1:8773";

async function api(path, opts = {}) {
  const res = await fetch(`${DESKKIT}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...opts,
  });
  const text = await res.text();
  let body;
  try { body = JSON.parse(text); } catch { body = text; }
  if (!res.ok) throw new Error(`${res.status}: ${JSON.stringify(body)}`);
  return body;
}

async function health() {
  try {
    const h = await api("/health");
    const tools = await api("/tools");
    return { ok: true, health: h, tools };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
}

async function runTool(name, args = {}) {
  return api("/api/tool", {
    method: "POST",
    body: JSON.stringify({ tool: name, args }),
  });
}

async function runMacro(name) {
  return api("/api/macro/run", {
    method: "POST",
    body: JSON.stringify({ macro: name }),
  });
}

async function log(tail = 20) {
  try {
    return await api(`/log?tail=${tail}`);
  } catch (err) {
    return { error: String(err) };
  }
}

// Harvest bridge: ship captured reasoning text to the local planner lane.
async function harvestToLocal(transcript, systemNote) {
  const payload = {
    model: "local",
    messages: [
      { role: "system", content: systemNote || "You are the planner lane. Absorb reasoning from a larger model and return a concrete execution plan. Keep it small and precise." },
      { role: "user", content: transcript },
    ],
    temperature: 0.3,
    max_tokens: 2048,
  };
  const res = await fetch(`${LOCAL_LANE}/v1/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data?.error?.message || `${res.status}`);
  return data.choices?.[0]?.message?.content || "";
}

// Hotkey path: command -> active-window probe.
chrome.commands.onCommand.addListener(async (cmd) => {
  if (cmd !== "run-desk-hotkey") return;
  try {
    const win = await runTool("get_active_title");
    await chrome.notifications?.create?.("dk-probe", {
      type: "basic",
      iconUrl: "icons/icon128.png",
      title: "DeskKit Probe",
      message: `Active window: ${JSON.stringify(win?.result ?? win)}`,
    });
  } catch (err) {
    console.error("DeskKit hotkey failed:", err);
  }
});

// Message routing for popup/harvest pages.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  const handlers = {
    health: () => health(),
    runTool: (m) => runTool(m.name, m.args || {}),
    runMacro: (m) => runMacro(m.name),
    log: (m) => log(m.tail || 20),
    harvest: (m) => harvestToLocal(m.transcript, m.systemNote),
  };
  const fn = handlers[msg?.type];
  if (!fn) return false;
  fn(msg).then(sendResponse).catch((err) => sendResponse({ error: String(err) }));
  return true; // keep channel open for async response
});
