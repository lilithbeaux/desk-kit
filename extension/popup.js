const statusEl = document.getElementById("status");
const toolsEl = document.getElementById("tools");
const outputEl = document.getElementById("output");
const logEl = document.getElementById("log");

async function send(msg) {
  return new Promise((resolve) => chrome.runtime.sendMessage(msg, resolve));
}

function showOutput(obj) {
  outputEl.textContent = JSON.stringify(obj, null, 2);
}

async function refresh() {
  const h = await send({ type: "health" });
  if (h.ok) {
    statusEl.className = "status ok";
    statusEl.textContent = `● DESKKIT LIVE — ${h.health.tools} tools · ${h.health.service}`;
    toolsEl.innerHTML = "";
    (h.tools.tools || []).forEach((t) => {
      const row = document.createElement("div");
      row.className = "tool-row";
      const name = document.createElement("span");
      name.className = "name";
      name.textContent = t.name;
      const avail = document.createElement("span");
      avail.className = "avail " + (t.available ? "yes" : "no");
      avail.textContent = t.available ? "ready" : "blocked";
      row.appendChild(name);
      row.appendChild(avail);
      toolsEl.appendChild(row);
    });
  } else {
    statusEl.className = "status bad";
    statusEl.textContent = `✗ DESKKIT DOWN — ${h.error}`;
  }
  const l = await send({ type: "log", tail: 8 });
  if (l && l.log) logEl.textContent = l.log.join("\n");
}

document.getElementById("probe").onclick = async () => {
  showOutput(await send({ type: "runTool", name: "get_active_title" }));
  refresh();
};
document.getElementById("probe2").onclick = async () => {
  showOutput(await send({ type: "runTool", name: "get_cursor_pos" }));
  refresh();
};

refresh();
