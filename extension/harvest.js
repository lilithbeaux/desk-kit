const noteEl = document.getElementById("note");
const txEl = document.getElementById("tx");
const outEl = document.getElementById("out");

document.getElementById("go").onclick = async () => {
  const transcript = txEl.value.trim();
  if (!transcript) return;
  outEl.className = "out";
  outEl.textContent = "shipping to local lane…";
  try {
    const r = await new Promise((resolve) =>
      chrome.runtime.sendMessage(
        { type: "harvest", transcript, systemNote: noteEl.value.trim() },
        resolve
      )
    );
    if (r.error) {
      outEl.className = "out bad";
      outEl.textContent = `ERROR: ${r.error}`;
    } else {
      outEl.className = "out";
      outEl.textContent = r;
    }
  } catch (err) {
    outEl.className = "out bad";
    outEl.textContent = String(err);
  }
};
