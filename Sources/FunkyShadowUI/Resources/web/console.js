// FunkyShadow console page. Drives the unmodified vendored spice-html5 and
// talks to the native side through two message handlers:
//   funkyTicket (with reply)  -> { uri, password } | { stop:true }
//   funkyEvent  (one-way)     -> { type:"log"|"link"|"inputsReady"|"pageReady", ... }
// The SPICE URI and ticket never appear in a URL.
import * as SpiceHtml5 from './spice-html5/src/main.js';

const $ = (s) => document.querySelector(s);
const native = window.webkit && window.webkit.messageHandlers;
const post = (msg) => { try { native.funkyEvent.postMessage(msg); } catch (e) { /* no native side */ } };

function logln(m) {
  const e = $("#log");
  e.textContent += m + "\n";
  e.scrollTop = e.scrollHeight;
  post({ type: "log", message: String(m) });
}

let sc = null;
let spamTimer = null;
let readyPoll = null;

const canvas = () => document.querySelector("#spice-screen canvas");
const inputsReady = () => !!(sc && sc.inputs && sc.inputs.state === "ready");

// ---- display scaling --------------------------------------------------------
// spice-html5 reads mouse positions from offsetX/Y, which stay correct under a
// CSS transform but not under object-fit, so scale the screen with a transform.
function fit() {
  const c = canvas(), area = $("#spice-area"), screen = $("#spice-screen");
  if (!c || !c.width || !c.height) return;
  const pad = document.body.classList.contains("bare") ? 0 : 14;
  const s = Math.min((area.clientWidth - 2 * pad) / c.width, (area.clientHeight - 2 * pad) / c.height);
  screen.style.width = c.width + "px";
  screen.style.height = c.height + "px";
  screen.style.transform = `translate(-50%, -50%) scale(${s > 0 ? s : 1})`;
}
new ResizeObserver(fit).observe($("#spice-area"));
// The guest changes resolution (new canvas, or width/height attributes).
new MutationObserver(fit).observe($("#spice-screen"), { childList: true, subtree: true, attributes: true, attributeFilter: ["width", "height"] });

// ---- keys -------------------------------------------------------------------
// spice-html5 maps DOM key events on the guest canvas to SPICE scancodes.
function tap(code, keyCode) {
  const c = canvas();
  if (!inputsReady() || !c) return false;
  const base = { bubbles: true, cancelable: true, key: code, code, keyCode, which: keyCode };
  c.dispatchEvent(new KeyboardEvent("keydown", base));
  c.dispatchEvent(new KeyboardEvent("keyup", base));
  return true;
}

function sendKey(code, keyCode) {
  if (!tap(code, keyCode)) { logln("not connected yet"); return false; }
  logln("sent " + code);
  return true;
}

// Esc spam — the only spam. Runs only when triggered, for durationMs.
function spamEsc(durationMs, periodMs) {
  if (!inputsReady() || !canvas()) { logln("not connected yet — can't spam"); return false; }
  if (spamTimer) clearInterval(spamTimer);
  const end = Date.now() + durationMs;
  logln(`Spamming Esc for ${durationMs / 1000}s …`);
  spamTimer = setInterval(() => {
    if (Date.now() >= end) { clearInterval(spamTimer); spamTimer = null; logln("Esc spam done"); return; }
    tap("Escape", 27);
  }, periodMs);
  return true;
}

function ctrlAltDel() {
  if (!sc) { logln("not connected yet"); return false; }
  SpiceHtml5.sendCtrlAltDel(sc);
  logln("sent Ctrl+Alt+Del");
  return true;
}

// US-layout ASCII only; anything else is skipped and reported.
async function typeText(text) {
  if (!sc || !inputsReady()) { logln("not connected yet"); return { typed: 0, skipped: [], aborted: true }; }
  logln(`typing ${text.length} chars into guest`);
  const r = await SpiceHtml5.typeText(sc, text);
  const skipped = (r && r.skipped) || [];
  logln(`typed ${r ? r.typed : 0}` + (skipped.length ? `, skipped ${skipped.length}: ${[...new Set(skipped)].join(" ")}` : "") + (r && r.aborted ? " (aborted)" : ""));
  return { typed: (r && r.typed) || 0, skipped: skipped.map(String), aborted: !!(r && r.aborted) };
}

function screenshot() {
  const c = canvas();
  if (!c) throw new Error("no display yet");
  return c.toDataURL("image/png");
}

function focusCanvas() {
  const c = canvas();
  if (c) c.focus({ preventScroll: true });
}

// ---- connection -------------------------------------------------------------
// SPICE link errors go to the log only; the window header shows the real VM
// status, which the native side polls from the proxy.
function onError(e) {
  const m = e && e.message ? e.message : (e && e.type ? "ws-" + e.type : String(e));
  logln("SPICE: " + m);
  post({ type: "link", state: m === "Permission denied." ? "badTicket" : "error", message: m });
}

function disconnect() {
  if (spamTimer) { clearInterval(spamTimer); spamTimer = null; }
  if (readyPoll) { clearInterval(readyPoll); readyPoll = null; }
  try { if (sc && sc.stop) sc.stop(); } catch (e) { /* already gone */ }
  sc = null;
  $("#spice-screen").replaceChildren();
}

async function connect(fresh) {
  disconnect();
  let ticket;
  try { ticket = await native.funkyTicket.postMessage({ fresh: !!fresh }); }
  catch (e) { logln("could not get a SPICE ticket: " + e); post({ type: "link", state: "error", message: String(e) }); return false; }
  if (!ticket || ticket.stop || !ticket.uri) { logln("no console available"); return false; }

  logln("Connecting: " + ticket.uri);
  post({ type: "link", state: "connecting" });
  try {
    sc = new SpiceHtml5.SpiceMainConn({
      uri: ticket.uri, password: ticket.password || "",
      screen_id: "spice-screen", dump_id: "debug-div", message_id: "message-div",
      onerror: onError,
      onagent: () => logln("guest agent connected"),
      onsuccess: () => { logln("main channel up"); post({ type: "link", state: "connected" }); },
    });
  } catch (e) { onError(e); return false; }

  let waited = 0;
  readyPoll = setInterval(() => {
    waited += 200;
    if (inputsReady() && canvas()) {
      clearInterval(readyPoll); readyPoll = null;
      logln("inputs channel ready");
      fit(); focusCanvas();
      post({ type: "inputsReady" });
    } else if (waited > 60000) {
      clearInterval(readyPoll); readyPoll = null;
      logln("gave up waiting for inputs channel (60s)");
    }
  }, 200);
  return true;
}

// Backspace (and friends) must never navigate the page away from the console.
window.addEventListener("keydown", (e) => { if (e.target === document.body) e.preventDefault(); });
$("#spice-area").addEventListener("mousedown", () => setTimeout(focusCanvas, 0));

window.funky = {
  connect, disconnect, sendKey, ctrlAltDel, spamEsc, typeText, screenshot, focusCanvas,
  setLogVisible(v) { document.body.classList.toggle("nolog", !v); fit(); },
  setBare(v) { document.body.classList.toggle("bare", !!v); fit(); },
};
post({ type: "pageReady" });
