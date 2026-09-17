// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[...], charted:[...], delivered:[...],
//     stalled:[...], grill:[...], advice:[...], empty, more, error, live }
//
// Live mode (FM_HARNESS_LIVE=1) additionally wires the browser APIs the
// live-update watcher needs - location, fetch, setInterval, localStorage, and a
// Web Audio stub - so a test can drive one refresh and assert what the page
// announced. FM_HARNESS_NEXT_HTML supplies the board the refresh delivers,
// FM_HARNESS_SEED_SEEN_HTML pre-seeds the stored previously-seen payload (the F5
// case), and FM_HARNESS_LIVE_SOUND=1 turns the sound toggle on first.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const liveMode = process.env.FM_HARNESS_LIVE === "1";
const nextHtmlFile = process.env.FM_HARNESS_NEXT_HTML || "";
const seedSeenFile = process.env.FM_HARNESS_SEED_SEEN_HTML || "";

function payloadOf(source) {
  return JSON.parse(
    source.split('<script id="bearings-data" type="application/json">')[1].split("</script>")[0]);
}

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this._html = "";
    this.hidden = false;
    this.disabled = false;
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.handlers = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      remove: (c) => {
        this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" ");
      },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, force) => {
        const has = this.classList.contains(c);
        const want = force === undefined ? !has : !!force;
        if (want && !has) this.classList.add(c);
        if (!want && has) this.classList.remove(c);
      },
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  // The renderer clears containers by setting innerHTML to ""; mirror the
  // browser by actually dropping the children so a live re-render is faithful.
  get innerHTML() { return this._html; }
  set innerHTML(v) {
    this._html = String(v);
    if (this._html === "") { this.children = []; this._text = ""; }
  }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  removeChild(n) {
    const i = this.children.indexOf(n);
    if (i >= 0) this.children.splice(i, 1);
    return n;
  }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

// Depth-first lookup helpers for nested markup (chips live inside a row body).
function find(node, cls) {
  for (const c of node.children) {
    if (c.className.split(/\s+/).includes(cls)) return c;
    const nested = find(c, cls);
    if (nested) return nested;
  }
  return null;
}
function findAll(node, cls, out = []) {
  for (const c of node.children) {
    if (c.className.split(/\s+/).includes(cls)) out.push(c);
    findAll(c, cls, out);
  }
  return out;
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};

const stores = new Map();
globalThis.window = {};
// A queuePrompt spy shared by every mode: it records exactly what the page would
// have queued on the captain's behalf, so a test can assert the annotation.
globalThis.window.lavish = {
  queued: [],
  queuePrompt(text, opts) {
    this.queued.push({ text: text, queueKey: opts && opts.queueKey, data: opts && opts.data, tag: opts && opts.tag });
  },
};
// The answer handlers read the selected radio, which a test supplies here.
globalThis.FormData = function () {
  this.get = (k) => {
    if (k === "answer") return process.env.FM_HARNESS_ANSWER || null;
    if (k === "note") return process.env.FM_HARNESS_NOTE || "";
    return null;
  };
};
const liveData = liveMode ? payloadOf(html) : null;
if (liveMode) {
  globalThis.window.location = { href: "http://board.example/session/render", pathname: "/session/render" };
  globalThis.window.localStorage = {
    getItem: (k) => (stores.has(k) ? stores.get(k) : null),
    setItem: (k, v) => { stores.set(k, String(v)); },
    removeItem: (k) => { stores.delete(k); },
  };
  globalThis.window.setInterval = (fn) => { globalThis.window.__interval = fn; return 1; };
  const nextHtml = nextHtmlFile ? readFileSync(nextHtmlFile, "utf8") : html;
  globalThis.window.fetch = () => Promise.resolve({ ok: true, text: () => Promise.resolve(nextHtml) });
  globalThis.window.AudioContext = function () {
    this.state = "running";
    this.currentTime = 0;
    this.destination = {};
    this.resume = () => {};
    this.createOscillator = () => ({ frequency: {}, connect() {}, start() {}, stop() {} });
    this.createGain = () => ({ gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {} });
  };
  if (seedSeenFile) {
    const seed = payloadOf(readFileSync(seedSeenFile, "utf8"));
    stores.set("fm-bearings-seen:" + (liveData.home || "") + ":/session/render", JSON.stringify(seed));
  }
}
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

async function flush() { await new Promise((r) => setTimeout(r, 0)); }
await flush();
if (liveMode && process.env.FM_HARNESS_LIVE_SOUND === "1") {
  globalThis.window.fmBearingsBoard.setSound(true);
}
if (liveMode && process.env.FM_HARNESS_LIVE_REFRESH === "1") {
  await globalThis.window.fmBearingsBoard.refreshNow();
  await flush();
}

// Action mode performs one real captain click through the shipped handler, so
// behavior is asserted through the page's own code rather than a reimplementation.
const action = process.env.FM_HARNESS_ACTION || "";
const actionReport = { fired: action, found: false, error: "", queued: [] };
function firstNode(root, cls) { return root ? findAll(root, cls)[0] || null : null; }
function firstForm(root) {
  let hit = null;
  const walk = (n) => {
    for (const c of n.children) {
      if (hit) return;
      if (c.tagName === "form") { hit = c; return; }
      walk(c);
    }
  };
  if (root) walk(root);
  return hit;
}
function fire(node, type, event) {
  if (!node || !node.handlers[type] || !node.handlers[type].length) return false;
  node.handlers[type].forEach((fn) => fn(event || { preventDefault() {} }));
  return true;
}
if (action) {
  let ok = false;
  if (action === "dispatch-now") ok = fire(firstNode(byId.get("bb-charted"), "bb-now"), "click");
  else if (action === "resume") ok = fire(firstNode(byId.get("bb-stalled"), "bb-resume"), "click");
  else if (action === "approve") {
    const box = firstNode(byId.get("bb-delivered"), "bb-approve");
    if (box) { box.checked = true; ok = fire(box, "change"); }
  } else if (action === "answer") {
    const deck = byId.get("bb-call");
    ok = fire(firstForm(deck && deck.children[0]), "submit");
  } else if (action === "grill") {
    ok = fire(firstForm(byId.get("bb-grill")), "submit");
  } else if (action === "card-question") {
    ok = fire(firstForm(byId.get("bb-kanban")), "submit");
  } else if (action === "card-approve") {
    const box = firstNode(byId.get("bb-kanban"), "bb-approve");
    if (box) { box.checked = true; ok = fire(box, "change"); }
  } else {
    actionReport.error = "unknown action: " + action;
  }
  actionReport.found = ok;
  if (!ok && !actionReport.error) actionReport.error = "no handler found for " + action;
  actionReport.queued = JSON.parse(JSON.stringify(globalThis.window.lavish.queued));
  await flush();
}

const badgesOf = (node) =>
  findAll(node, "fm-badge").map((c) => ({
    tone: c.className.replace(/.*fm-badge--/, "").split(/\s+/)[0],
    text: c.textContent,
  }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = find(row, "bb-row__main");
      return {
        title: find(row, "bb-row__title")?.textContent ?? "",
        sub: find(row, "bb-row__sub")?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
        dispatchNow: !!find(row, "bb-now"),
        resume: !!find(row, "bb-resume"),
        ticket: find(row, "bb-ticket")?.textContent ?? "",
        wait: find(row, "bb-wait")?.textContent ?? "",
        why: find(row, "bb-stall__why")?.textContent ?? "",
        next: find(row, "bb-stall__next")?.textContent ?? "",
        kasten: !!find(row, "bb-approve"),
        main: main ? main.textContent : "",
      };
    });

const underway = rowsOf(byId.get("bb-underway") || new Node("div"));
const charted = rowsOf(byId.get("bb-charted") || new Node("div"));
const delivered = rowsOf(byId.get("bb-delivered") || new Node("div"));
const stalled = rowsOf(byId.get("bb-stalled") || new Node("div"));

const grill = (byId.get("bb-grill") || new Node("div")).children.map((card) => ({
  num: find(card, "bb-grill__num")?.textContent ?? "",
  ticket: find(card, "bb-ticket")?.textContent ?? "",
  prompt: find(card, "bb-grill__prompt")?.textContent ?? "",
  options: findAll(card, "bb-opt__label").map((c) => c.textContent),
  wait: find(card, "bb-wait")?.textContent ?? "",
}));

const advice = (byId.get("bb-advice") || new Node("div")).children.map((card) => {
  const lists = findAll(card, "bb-advice__list");
  return {
    title: find(card, "bb-advice__title")?.textContent ?? "",
    verdict: find(card, "bb-advice__verdict")?.textContent ?? "",
    pros: lists[0] ? lists[0].children.map((li) => li.textContent) : [],
    cons: lists[1] ? lists[1].children.map((li) => li.textContent) : [],
    recommendation: find(card, "bb-advice__rec")?.textContent ?? "",
    badges: badgesOf(card),
  };
});

const kanban = (byId.get("bb-kanban") || new Node("div")).children.map((col) => ({
  label: find(col, "bb-col__head")?.children?.[0]?.textContent ?? "",
  count: find(col, "bb-col__count")?.textContent ?? "",
  cards: (col.children || [])
    .filter((c) => c.className.split(/\s+/).includes("bb-card"))
    .map((card) => ({
      ticket: find(card, "bb-ticket")?.textContent ?? "",
      title: find(card, "bb-card__title")?.textContent ?? "",
      meta: find(card, "bb-card__meta")?.textContent ?? "",
      summary: find(card, "bb-card__summary")?.textContent ?? "",
      kasten: !!find(card, "bb-approve"),
      questions: card.children.filter((c) => c.tagName === "form").length,
      history: (findAll(card, "bb-card__list").filter((l) => !l.className.includes("bb-card__learnings"))[0]?.children || [])
        .map((li) => li.textContent),
      learnings: (findAll(card, "bb-card__learnings")[0]?.children || []).map((li) => li.textContent),
    })),
}));

const ch = byId.get("bb-charted") || new Node("div");
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

const liveNode = byId.get("bb-live");
const live = {
  available: !!(globalThis.window.fmBearingsBoard && globalThis.window.fmBearingsBoard.liveState.available),
  bannerHidden: liveNode ? !!liveNode.hidden : true,
  bannerTitle: byId.get("bb-live-title")?.textContent ?? "",
  banner: byId.get("bb-live-list")?.textContent ?? "",
  sound: byId.get("bb-sound")?.textContent ?? "",
  chimes: globalThis.window.fmBearingsBoard ? globalThis.window.fmBearingsBoard.liveState.chimes : 0,
  notice: globalThis.window.fmBearingsBoard ? globalThis.window.fmBearingsBoard.liveState.notice : "",
  intervalArmed: liveMode ? typeof globalThis.window.__interval === "function" : false,
};

process.stdout.write(
  JSON.stringify({ stats, underway, charted, delivered, stalled, grill, advice, kanban, empty, more, error: errorText, live, action: actionReport }) + "\n");
