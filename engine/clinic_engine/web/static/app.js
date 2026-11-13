// Clinician page. Vanilla JS, no build step, no outside resources.
// Rules: every value from the API is put on the page with textContent or
// setAttribute, never parsed as HTML. The session token lives in memory and
// in sessionStorage only.
//
// How the page keeps its place: everything shown is drawn by render() from
// `state`. The selected tab is in the URL hash, and which sections are
// expanded is in state.open (also kept in sessionStorage). A refresh fetches
// new data and calls render() again, so tabs, expanded sections, chart
// selections and the scroll position come back exactly as they were.
"use strict";

(function () {
  const SVG_NS = "http://www.w3.org/2000/svg";
  const TOKEN_KEY = "clinic_session_token";
  const OPEN_KEY = "clinic_open_sections";
  const REFRESH_MS = 60000;

  const PATIENT_TABS = [
    { id: "overview", label: "Overview" },
    { id: "reasoning", label: "Reasoning" },
    { id: "progress", label: "Progress" },
    { id: "rounds", label: "Rounds" },
    { id: "mind", label: "Mind" },
    { id: "history", label: "History" },
    { id: "safety", label: "Safety log" },
  ];

  const state = {
    token: null,
    me: null,
    route: { name: "list" },
    list: null,
    detail: {}, // patient id -> detail
    rounds: {}, // "pid/rid" -> round
    trace: {}, // "pid|all|item" -> trace
    errors: {}, // cache key -> message
    open: new Set(), // keys of expanded sections
    chartSel: {}, // chart key -> selected date or round id
    traceAll: false, // show all chains, not only those that changed something
    demo: { pid: null, rid: null, results: {} },
    focusKey: null,
    fkeys: new Map(),
    updatedAt: null,
    busy: false,
    chartWidth: 760,
  };

  // ---- small helpers ------------------------------------------------------------------

  function $(id) { return document.getElementById(id); }

  // el("p", {class: "x"}, "text", childNode, ...). Strings become text nodes.
  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    setAttrs(node, attrs);
    append(node, children);
    return node;
  }

  function svg(tag, attrs, ...children) {
    const node = document.createElementNS(SVG_NS, tag);
    setAttrs(node, attrs);
    append(node, children);
    return node;
  }

  function setAttrs(node, attrs) {
    if (!attrs) return;
    for (const k of Object.keys(attrs)) {
      const v = attrs[k];
      if (v === null || v === undefined || v === false) continue;
      if (k.startsWith("on")) throw new Error("use addEventListener");
      node.setAttribute(k, v === true ? "" : String(v));
    }
  }

  function append(node, children) {
    for (const c of children.flat(3)) {
      if (c === null || c === undefined || c === false || c === "") continue;
      node.appendChild(typeof c === "object" ? c : document.createTextNode(String(c)));
    }
  }

  function setHidden(node, hide) {
    if (hide) node.setAttribute("hidden", ""); else node.removeAttribute("hidden");
  }

  // A stable key for an element, so focus can come back to it after a re-render.
  function fk(node, key) {
    node.setAttribute("data-fkey", key);
    state.fkeys.set(key, node);
    return node;
  }

  function words(code) {
    return code === null || code === undefined ? "" : String(code).replace(/_/g, " ");
  }

  function cap(s) { s = String(s || ""); return s.charAt(0).toUpperCase() + s.slice(1); }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

  function domId(prefix, key) { return prefix + "-" + String(key).replace(/[^A-Za-z0-9_-]/g, "-"); }

  // ---- dates --------------------------------------------------------------------------

  const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

  function parseDay(s) {
    const p = String(s).slice(0, 10).split("-").map(Number);
    return new Date(Date.UTC(p[0], p[1] - 1, p[2]));
  }
  function isoDay(d) { return d.toISOString().slice(0, 10); }
  function addDays(s, n) { const d = parseDay(s); d.setUTCDate(d.getUTCDate() + n); return isoDay(d); }
  function dayDiff(a, b) { return Math.round((parseDay(b) - parseDay(a)) / 86400000); }
  function fmtDay(s) {
    if (!s) return "";
    const d = parseDay(s);
    return isNaN(d.getTime()) ? String(s) : d.getUTCDate() + " " + MONTHS[d.getUTCMonth()];
  }
  function fmtDayLong(s) {
    const d = parseDay(s);
    return isNaN(d.getTime()) ? String(s) : WEEKDAYS[d.getUTCDay()] + " " + fmtDay(s);
  }
  function pad2(n) { return (n < 10 ? "0" : "") + n; }
  function fmtTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d.getTime())) return String(iso);
    return d.getDate() + " " + MONTHS[d.getMonth()] + ", " + pad2(d.getHours()) + ":" + pad2(d.getMinutes());
  }
  function localDay(iso) {
    const d = new Date(iso);
    return isNaN(d.getTime()) ? String(iso).slice(0, 10)
      : d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate());
  }

  function fmtNum(v, digits) {
    if (v === null || v === undefined || v === "") return "none";
    if (typeof v === "number") return v.toFixed(digits === undefined ? 2 : digits);
    return String(v);
  }
  function fmtZ(z) {
    if (z === null || z === undefined) return "none";
    return (z < 0 ? "−" : "+") + Math.abs(z).toFixed(1);
  }

  function flash(msg) {
    const f = $("flash");
    f.textContent = msg || "";
    setHidden(f, !msg);
  }

  // ---- storage --------------------------------------------------------------------------

  function saveToken(t) {
    state.token = t;
    try {
      if (t) sessionStorage.setItem(TOKEN_KEY, t); else sessionStorage.removeItem(TOKEN_KEY);
    } catch (e) { /* storage blocked: memory only */ }
  }
  function loadToken() {
    try { return sessionStorage.getItem(TOKEN_KEY); } catch (e) { return null; }
  }
  function saveOpen() {
    try { sessionStorage.setItem(OPEN_KEY, JSON.stringify([...state.open].slice(-300))); } catch (e) { /* memory only */ }
  }
  function loadOpen() {
    try {
      const v = JSON.parse(sessionStorage.getItem(OPEN_KEY) || "[]");
      if (Array.isArray(v)) for (const k of v) if (typeof k === "string") state.open.add(k);
    } catch (e) { /* ignore */ }
  }

  // ---- API ----------------------------------------------------------------------------

  class ApiFailure extends Error {
    constructor(status, code, message) { super(message); this.status = status; this.code = code; }
  }

  async function api(method, path, body) {
    const headers = { "Accept": "application/json" };
    if (state.token) headers["Authorization"] = "Bearer " + state.token;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const res = await fetch(path, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
      credentials: "omit", cache: "no-store", redirect: "error",
    });
    let data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (!res.ok) {
      const err = (data && data.error) || {};
      if (res.status === 401 && path !== "/v1/clinic/login") {
        logout("Your session ended. Please sign in again.");
      }
      throw new ApiFailure(res.status, err.code || "error", err.message || ("HTTP " + res.status));
    }
    return data;
  }

  // ---- words for codes -------------------------------------------------------------------

  const STATUS = {
    outside: { word: "Outside own normal", shape: "tri-down" },
    no_data: { word: "No data", shape: "circle-dashed" },
    no_baseline: { word: "Learning own normal", shape: "square-hollow" },
    within: { word: "Within own normal", shape: "dot" },
  };
  const LEVEL = {
    urgent: { word: "Needs review today", shape: "circle" },
    attention: { word: "Attention", shape: "diamond" },
    watch: { word: "Watch", shape: "circle-hollow" },
  };
  const LEVEL_ORDER = { urgent: 0, attention: 1, watch: 2 };
  const STATUS_ORDER = { outside: 0, no_data: 1, no_baseline: 2, within: 3 };

  const KIND_WORD = {
    deviation: "Movement below own normal",
    novelty: "One day far from usual",
    silence: "No daily data",
    oddity: "Implausible values sent",
    ignored: "Suggestions left unanswered",
    asked_for_help: "Asked for help in a note",
    low_notes: "Several low-mood notes",
    weak_rounds: "Weak rounds",
    round_mismatch: "Rounds and daily data disagree",
    fading: "Slowing within rounds",
    stopped_early: "Rounds stopped early",
    not_played: "Offered rounds not played",
  };
  const KIND_SHORT = {
    deviation: "Low movement", novelty: "Unusual day", silence: "No data", oddity: "Odd values",
    ignored: "Unanswered", asked_for_help: "Asked for help", low_notes: "Low mood",
    weak_rounds: "Weak rounds", round_mismatch: "Mismatch", fading: "Slowing",
    stopped_early: "Stopped early", not_played: "Not played",
  };
  const ACTION_WORD = {
    ar_round: "a catch-the-lights round", ar_round_seated: "a seated catch-the-lights round",
    walk_10min: "a short walk", daylight_10min: "some daylight",
    call_someone: "reaching out to someone", breathing_2min: "slow breathing",
  };
  const METRICS = [
    { key: "steps", title: "Steps", unit: (v) => Math.round(v).toLocaleString("en-GB") + " steps" },
    { key: "walking_speed_m_s", title: "Walking speed", unit: (v) => v.toFixed(2) + " m/s" },
    { key: "hrv_ms", title: "Heart-rate variability", unit: (v) => Math.round(v) + " ms" },
    { key: "sleep_h", title: "Sleep", unit: (v) => v.toFixed(1) + " hours" },
  ];
  const TRIGGER_WORD = {
    day: "Daily data arrived", round: "A round was reported", note: "A note was received",
    feedback: "The patient answered a suggestion", rule: "The patient changed a rule",
    tick: "Regular check", scenario: "Demo scenario switched",
    ack: "A clinician acknowledged an item", lesson_rejected: "The patient rejected a lesson",
    question_answered: "The patient answered a question", reading: "A movement reading came back",
    reading_requested: "Movement reading asked for", queued_message_due: "A queued message came due",
    internal: "Internal step",
  };
  const RULE_WORD = {
    sustained_drop: "several of the last days were clearly below own normal",
    far_from_normal: "one day was far from usual",
    no_daily_data: "no daily data arrived for some days",
    implausible_data: "values that cannot be true were sent",
    no_answers: "several suggestions in a row were left unanswered",
    note_flagged: "a note asked for help",
    low_mood_notes: "several recent notes were low in mood",
    two_weak_rounds: "two weak rounds in a row",
    rounds_and_days_disagree: "rounds and daily data disagree",
    growing_fade: "slowing within rounds is growing",
    rounds_stopped_early: "rounds were stopped early",
    rounds_offered_not_played: "offered rounds were not played",
    deviation_is_attention: "a sustained movement drop is held at Attention",
    deep_drop_and_unanswered: "the drop is deep and suggestions are left unanswered",
    silence_while_held: "data stopped while the drop is held",
    held_too_long: "the drop has been held for 10 days or more",
    raised_while_drop_held: "a movement drop is held at the same time",
    asked_for_help_is_urgent: "asking for help always needs review",
    kept_level: "the level it opened at",
    recovered: "movement was back to usual for several days",
    settled: "it settled", data_arrived: "data arrived again", clean_again: "values were plausible again",
    answered_again: "the patient answered again", acknowledged: "a clinician acknowledged it",
    round_usual_again: "rounds were usual again", agree_again: "rounds and days agree again",
    fade_settled: "slowing settled", finished_again: "rounds were finished again",
    played_again: "rounds were played again",
  };
  const BECAUSE_WORD = {
    no_held_item_to_answer: "nothing is held that a suggestion could answer",
    already_answered_today: "the held item already got a suggestion today",
    held_items_need_a_clinician: "what is held needs a clinician, not a suggestion",
    no_action_allowed_by_rules: "the patient's own rules allow no action",
    quiet_hours: "it is the patient's quiet time",
    one_open_already: "one suggestion is still open",
    daily_cap: "the daily limit of suggestions is reached",
    cooldown: "the last suggestion was made only a few hours ago",
  };
  const LAYER_NAME = {
    trigger: "1. Trigger", watchers: "2. Watchers", attention: "3. Attention",
    response: "4. Response (code)", level1: "5. Level 1: local model",
    level2: "6. Level 2: outside model", notifier: "7. Notifier", learning: "8. Learning",
  };
  const LAYER_ORDER = ["trigger", "watchers", "attention", "response", "level1", "level2", "notifier", "learning"];
  const TASK_WORD = { wording: "wording a suggestion", review: "proposing lessons", note: "classifying a note",
    second_opinion: "a second opinion on lessons", reading: "reading a round's movement" };
  const NOTIFY_WORD = {
    sent: "Sent", outside_hours_queued: "Queued until clinic hours", outside_hours_dropped: "Dropped (outside clinic hours)",
    notify_off: "Not sent: notifications are off", rate_limited: "Not sent: hourly limit reached",
    duplicate: "Not sent again: already handled", send_failed: "Sending failed", notifier_error: "Notifier error",
  };

  function ruleWords(code) {
    if (!code) return "";
    if (RULE_WORD[code]) return RULE_WORD[code];
    if (/_watcher$/.test(code)) return "its watcher raised it";
    return words(code);
  }
  function actionWords(a) { return ACTION_WORD[a] || words(a); }

  // ---- shapes and badges ------------------------------------------------------------------

  function shapeNodes(shape, cx, cy, r) {
    const t = (pts) => svg("path", { d: "M" + pts.map((p) => p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" L") + " Z" });
    switch (shape) {
      case "tri-down": return t([[cx - r, cy - r * 0.8], [cx + r, cy - r * 0.8], [cx, cy + r]]);
      case "tri-up": return t([[cx - r, cy + r * 0.8], [cx + r, cy + r * 0.8], [cx, cy - r]]);
      case "diamond": return t([[cx, cy - r], [cx + r, cy], [cx, cy + r], [cx - r, cy]]);
      case "square-hollow": case "square":
        return svg("rect", { x: cx - r * 0.8, y: cy - r * 0.8, width: r * 1.6, height: r * 1.6 });
      case "dot": return svg("circle", { cx, cy, r: r * 0.55 });
      case "cross": return svg("path", { d: `M${cx - r} ${cy - r} L${cx + r} ${cy + r} M${cx + r} ${cy - r} L${cx - r} ${cy + r}` });
      case "slash": return svg("g", null, svg("circle", { cx, cy, r: r * 0.85 }),
        svg("path", { d: `M${cx - r * 0.6} ${cy + r * 0.6} L${cx + r * 0.6} ${cy - r * 0.6}` }));
      case "chevron-open": return svg("path", { d: `M${cx - r * 0.7} ${cy - r * 0.35} L${cx} ${cy + r * 0.45} L${cx + r * 0.7} ${cy - r * 0.35}` });
      case "chevron-closed": return svg("path", { d: `M${cx - r * 0.35} ${cy - r * 0.7} L${cx + r * 0.45} ${cy} L${cx - r * 0.35} ${cy + r * 0.7}` });
      case "bar": return svg("rect", { x: cx - 1.5, y: cy - r, width: 3, height: r * 2 });
      default: return svg("circle", { cx, cy, r: r * 0.8 });
    }
  }

  function marker(shape, cls) {
    const s = svg("svg", { class: "mk mk-" + shape + (cls ? " " + cls : ""), viewBox: "0 0 16 16", "aria-hidden": "true", focusable: "false" });
    s.appendChild(shapeNodes(shape, 8, 8, 6));
    return s;
  }

  function statusBadge(status) {
    const info = STATUS[status] || { word: words(status), shape: "dot" };
    return el("span", { class: "badge st-" + status }, marker(info.shape), info.word);
  }

  function levelTag(level) {
    if (!level) return null;
    const info = LEVEL[level] || { word: words(level), shape: "dot" };
    return el("span", { class: "badge lv-" + level }, marker(info.shape), info.word);
  }

  function exampleTag(rec) {
    return rec && rec.example ? el("span", { class: "tag tag-example", title: "Generated example data, not a real person" }, "example data") : null;
  }

  function edgeOf(status, level) {
    if (level === "urgent" || status === "outside") return "ember";
    if (level === "attention") return "amber";
    if (level === "watch") return "sun";
    if (status === "no_data") return "nodata";
    if (status === "no_baseline") return "learning";
    return "calm";
  }

  // ---- building blocks --------------------------------------------------------------------

  let headingSeq = 0;

  function panel(opts, ...children) {
    const hid = "h" + (++headingSeq);
    const tag = opts.level === 3 ? "h3" : "h2";
    return el("section", { class: "panel" + (opts.edge ? " edge-" + opts.edge : ""), "aria-labelledby": hid },
      opts.eyebrow ? el("p", { class: "eyebrow" }, opts.eyebrow) : null,
      el("div", { class: "panel-head" }, el(tag, { id: hid }, opts.title), opts.aside || null),
      children);
  }

  function muted(text) { return el("p", { class: "muted" }, text); }

  function table(label, head, rows) {
    const t = el("table", null,
      el("thead", null, el("tr", null, head.map((h) => el("th", { scope: "col" }, h)))));
    const tb = el("tbody");
    for (const r of rows) {
      tb.appendChild(el("tr", null, r.map((c) => el("td", null,
        c === null || c === undefined ? "" : typeof c === "object" ? c : String(c)))));
    }
    t.appendChild(tb);
    return el("div", { class: "table-wrap", role: "region", "aria-label": label, tabindex: "0" }, t);
  }

  function facts(list) {
    return el("dl", { class: "facts" }, list.filter(Boolean).map((f) =>
      el("div", null, el("dt", null, f[0]), el("dd", null, f[1]))));
  }

  // A collapsible section: a button with aria-expanded controlling a region.
  // Its open state lives in state.open and is restored on every render.
  function disclosure(key, label, body) {
    const id = domId("dx", key);
    const open = state.open.has(key);
    const region = el("div", { id, class: "disclosure-body", role: "region", "aria-label": label, hidden: !open });
    append(region, [typeof body === "function" ? body() : body]);
    const btn = fk(el("button", {
      type: "button", class: "disclosure", "aria-expanded": open ? "true" : "false",
      "aria-controls": id, "data-disclosure": key,
    }, marker("chevron-" + (open ? "open" : "closed"), "chev"), label), "dx:" + key);
    btn.addEventListener("click", () => {
      const now = !state.open.has(key);
      if (now) state.open.add(key); else state.open.delete(key);
      saveOpen();
      btn.setAttribute("aria-expanded", now ? "true" : "false");
      setHidden(region, !now);
      const m = btn.firstChild;
      if (m && m.setAttribute) m.setAttribute("class", "mk chev mk-chevron-" + (now ? "open" : "closed"));
    });
    return el("div", { class: "disclosure-wrap" }, btn, region);
  }

  function detailList(obj, depth) {
    depth = depth || 0;
    if (obj === null || obj === undefined) return el("span", { class: "muted" }, "none");
    if (typeof obj !== "object") return el("span", null, typeof obj === "boolean" ? (obj ? "yes" : "no") : String(obj));
    if (Array.isArray(obj)) {
      if (!obj.length) return el("span", { class: "muted" }, "none");
      if (obj.every((x) => x === null || typeof x !== "object")) return el("span", null, obj.map((x) => words(x)).join(", "));
      if (depth > 3) return el("span", null, obj.length + " items");
      return el("ol", { class: "detail-list" }, obj.map((x) => el("li", null, detailList(x, depth + 1))));
    }
    const keys = Object.keys(obj);
    if (!keys.length) return el("span", { class: "muted" }, "none");
    if (depth > 3) return el("span", null, keys.length + " fields");
    return el("dl", { class: "detail" }, keys.map((k) => el("div", null, el("dt", null, words(k)), el("dd", null, detailList(obj[k], depth + 1)))));
  }

  // Tabs: real tabs with roving focus. Each tab is a hash route.
  function tabs(label, items, active, routeFor, idPrefix) {
    const list = el("div", { class: "tabs", role: "tablist", "aria-label": label });
    for (const t of items) {
      const sel = t.id === active;
      const b = fk(el("button", {
        type: "button", role: "tab", id: idPrefix + "tab-" + t.id, "aria-controls": idPrefix + "panel-" + t.id,
        "aria-selected": sel ? "true" : "false", tabindex: sel ? "0" : "-1", "data-route": routeFor(t.id),
      }, t.label), idPrefix + "tab:" + t.id);
      list.appendChild(b);
    }
    wireTabs(list);
    return list;
  }

  function wireTabs(list) {
    list.addEventListener("click", (ev) => {
      const b = ev.target.closest ? ev.target.closest("[role=tab]") : null;
      if (!b) return;
      state.focusKey = b.getAttribute("data-fkey");
      navigate(b.getAttribute("data-route"));
    });
    list.addEventListener("keydown", (ev) => {
      const all = [...list.children].filter((c) => c.getAttribute("role") === "tab" && !c.hasAttribute("hidden"));
      const i = all.indexOf(ev.target);
      if (i < 0) return;
      let j = null;
      if (ev.key === "ArrowRight") j = (i + 1) % all.length;
      else if (ev.key === "ArrowLeft") j = (i - 1 + all.length) % all.length;
      else if (ev.key === "Home") j = 0;
      else if (ev.key === "End") j = all.length - 1;
      if (j === null) return;
      ev.preventDefault();
      const b = all[j];
      state.focusKey = b.getAttribute("data-fkey");
      b.focus();
      navigate(b.getAttribute("data-route"));
    });
  }

  // ---- routing ------------------------------------------------------------------------

  function safeDecode(s) { try { return decodeURIComponent(s); } catch (e) { return ""; } }

  function parseRoute() {
    const parts = location.hash.replace(/^#\/?/, "").split("/").map(safeDecode);
    if (parts[0] === "patient" && parts[1]) {
      const tab = PATIENT_TABS.some((t) => t.id === parts[2]) ? parts[2] : "overview";
      return { name: "patient", pid: parts[1], tab, sub: parts[3] || null };
    }
    if (parts[0] === "round" && parts[1] && parts[2]) return { name: "patient", pid: parts[1], tab: "rounds", sub: parts[2], legacy: true };
    if (parts[0] === "demo") return { name: "demo" };
    return { name: "list" };
  }

  function patientHash(pid, tab, sub) {
    return "#/patient/" + encodeURIComponent(pid) + (tab ? "/" + tab : "") + (sub ? "/" + encodeURIComponent(sub) : "");
  }

  function navigate(hash) {
    if (location.hash === hash) render();
    else location.hash = hash;
  }

  function demoOn() { return !!(state.me && state.me.demo && state.me.demo.enabled); }

  async function onHash() {
    flash("");
    const before = viewKey(state.route);
    await route();
    if (viewKey(state.route) !== before && !state.focusKey) {
      $("main").focus({ preventScroll: true });
      window.scrollTo(0, 0);
    }
  }

  function viewKey(r) { return r.name + (r.name === "patient" ? ":" + r.pid : ""); }

  async function route() {
    if (!state.token) { showLogin(); return; }
    state.route = parseRoute();
    const r = state.route;
    if (r.legacy) { location.replace(patientHash(r.pid, "rounds", r.sub)); return; }
    if (r.name === "demo" && !demoOn()) { location.replace("#/patients"); return; }
    render();
    await load(false);
    render();
  }

  // ---- data loading -------------------------------------------------------------------

  function traceKey(pid, item) { return pid + "|" + (state.traceAll ? "all" : "changed") + "|" + (item || ""); }

  async function fetchInto(store, key, path) {
    try {
      store[key] = await api("GET", path);
      delete state.errors[key];
    } catch (e) {
      state.errors[key] = e.status === 404 ? "Not found." : "Could not load: " + e.message;
    }
  }

  async function load(force) {
    const r = state.route;
    const jobs = [];
    const P = "/v1/clinic/patients/";
    if (r.name === "list" || r.name === "demo") {
      if (force || !state.list) jobs.push(fetchInto(state, "list", "/v1/clinic/patients"));
    }
    if (r.name === "demo") {
      const pid = demoPid();
      if (pid && (force || !state.detail[pid])) jobs.push(fetchInto(state.detail, pid, P + encodeURIComponent(pid)));
    }
    if (r.name === "patient") {
      const pid = r.pid;
      if (force || !state.detail[pid]) jobs.push(fetchInto(state.detail, pid, P + encodeURIComponent(pid)));
      if (r.tab === "reasoning") {
        const item = r.sub;
        const k = traceKey(pid, item);
        const q = "?limit=30&changed_only=" + (state.traceAll ? "false" : "true") + (item ? "&attention_id=" + encodeURIComponent(item) : "");
        if (force || !state.trace[k]) jobs.push(fetchInto(state.trace, k, P + encodeURIComponent(pid) + "/trace" + q));
      }
      if (r.tab === "rounds" && r.sub) {
        const k = pid + "/" + r.sub;
        if (force || !state.rounds[k]) jobs.push(fetchInto(state.rounds, k, P + encodeURIComponent(pid) + "/rounds/" + encodeURIComponent(r.sub)));
      }
    }
    await Promise.all(jobs);
    if (jobs.length) state.updatedAt = new Date();
  }

  // Fetch fresh data and draw again, keeping tab, sections, selections and scroll.
  async function refresh() {
    if (state.busy || !state.token) return;
    state.busy = true;
    const y = window.scrollY || 0;
    try {
      await load(true);
      render({ scrollY: y });
    } finally {
      state.busy = false;
    }
  }

  function dropCaches() {
    state.list = null; state.detail = {}; state.rounds = {}; state.trace = {};
  }

  // ---- render -------------------------------------------------------------------------

  function render(opts) {
    if (!state.token) { showLogin(); return; }
    const active = document.activeElement;
    const focusKey = state.focusKey || (active && active.getAttribute ? active.getAttribute("data-fkey") : null);
    state.focusKey = null;
    state.fkeys = new Map();
    headingSeq = 0;
    state.chartWidth = chartWidth();

    const r = state.route;
    setHidden($("view-login"), true);
    setHidden($("who"), false);
    setHidden($("top-tabs"), false);
    setHidden($("tab-demo"), !demoOn());
    const onDemo = r.name === "demo";
    for (const [tid, sel] of [["tab-patients", !onDemo], ["tab-demo", onDemo]]) {
      const t = $(tid);
      t.setAttribute("aria-selected", sel ? "true" : "false");
      t.setAttribute("tabindex", sel ? "0" : "-1");
      fk(t, "top:" + tid);
    }
    setHidden($("panel-patients"), onDemo);
    setHidden($("panel-demo"), !onDemo);

    if (r.name === "list") $("panel-patients").replaceChildren(...listView());
    else if (r.name === "patient") $("panel-patients").replaceChildren(...patientView());
    else if (onDemo) $("panel-demo").replaceChildren(...demoView());

    const back = focusKey && state.fkeys.get(focusKey);
    if (back && back !== document.activeElement) back.focus({ preventScroll: true });
    if (opts && typeof opts.scrollY === "number") window.scrollTo(0, opts.scrollY);
  }

  function updatedLine() {
    return state.updatedAt ? el("span", { class: "muted small" }, "Updated " + pad2(state.updatedAt.getHours()) + ":" + pad2(state.updatedAt.getMinutes())) : null;
  }

  function refreshButton() {
    const b = fk(el("button", { type: "button", id: "refresh", class: "pill pill-outline" }, "Refresh"), "refresh");
    b.addEventListener("click", () => refresh());
    return b;
  }

  function loadingOrError(key) {
    return state.errors[key] ? el("p", { class: "error", role: "alert" }, state.errors[key]) : muted("Loading...");
  }

  // ---- login / logout ------------------------------------------------------------------

  function showLogin() {
    setHidden($("view-login"), false);
    setHidden($("panel-patients"), true);
    setHidden($("panel-demo"), true);
    setHidden($("top-tabs"), true);
    setHidden($("who"), true);
  }

  async function onLogin(ev) {
    ev.preventDefault();
    const user = $("login-user").value.trim();
    const pass = $("login-pass").value;
    const errBox = $("login-error");
    setHidden(errBox, true);
    if (!user || !pass) {
      errBox.textContent = "Enter a username and a password.";
      setHidden(errBox, false);
      return;
    }
    const btn = $("login-form").querySelector("button[type=submit]");
    btn.disabled = true;
    try {
      const out = await api("POST", "/v1/clinic/login", { username: user, password: pass });
      saveToken(out.session_token);
      $("login-pass").value = "";
      await afterLogin();
    } catch (e) {
      errBox.textContent = e.status === 429 ? "Too many tries. Wait a minute and try again."
        : e.status === 401 ? "Wrong username or password." : "Sign in failed: " + e.message;
      setHidden(errBox, false);
    } finally {
      btn.disabled = false;
    }
  }

  function setProduct(name) {
    if (!name) return;
    $("product-name").textContent = name;
    document.title = name + " clinician page";
  }

  async function afterLogin() {
    state.me = await api("GET", "/v1/clinic/me");
    setProduct(state.me.product_name);
    $("clinic-name").textContent = state.me.clinic_name || "";
    if (!location.hash || location.hash === "#/login") location.hash = "#/patients";
    else await route();
  }

  function logout(message) {
    saveToken(null);
    state.me = null;
    dropCaches();
    $("clinic-name").textContent = "";
    showLogin();
    flash(message || "");
    $("login-user").focus();
  }

  // ---- patient list ---------------------------------------------------------------------

  function legend() {
    return el("div", { class: "legend", role: "list", "aria-label": "What the markers mean" },
      ["outside", "no_data", "no_baseline", "within"].map((s) => el("span", { role: "listitem" }, statusBadge(s))),
      ["urgent", "attention", "watch"].map((l) => el("span", { role: "listitem" }, levelTag(l))));
  }

  function listView() {
    const head = el("div", { class: "page-head" },
      el("div", null, el("p", { class: "eyebrow" }, state.me ? state.me.clinic_name : "Clinic"), el("h1", null, "Patients")),
      el("div", { class: "head-actions" }, updatedLine(), refreshButton()));
    const out = [head, el("p", { class: "lead" }, "Those who need a look come first. Each person is compared only with their own normal."), legend()];
    if (!state.list) { out.push(loadingOrError("list")); return out; }
    const lines = state.list.patients.slice().sort((a, b) =>
      (LEVEL_ORDER[a.level] ?? 3) - (LEVEL_ORDER[b.level] ?? 3)
      || (STATUS_ORDER[a.status] ?? 4) - (STATUS_ORDER[b.status] ?? 4)
      || String(a.label).localeCompare(String(b.label)));
    if (!lines.length) { out.push(muted("No patients in this clinic yet.")); return out; }
    out.push(el("ol", { class: "pcards" }, lines.map(patientCard)));
    return out;
  }

  function patientCard(p) {
    const att = el("ul", { class: "held" });
    if (!p.attention.length) att.appendChild(el("li", { class: "muted" }, "Nothing held"));
    for (const a of p.attention) {
      att.appendChild(el("li", null, levelTag(a.level), " ", KIND_WORD[a.kind] || words(a.kind),
        el("span", { class: "muted" }, " since " + fmtDay(a.since))));
    }
    const link = fk(el("a", { class: "pcard-link", href: patientHash(p.patient_id) },
      el("div", { class: "pcard-top" }, el("span", { class: "pname" }, p.label), exampleTag(p)),
      el("div", { class: "pcard-status" }, statusBadge(p.status)),
      el("p", { class: "pcard-summary" }, p.summary),
      att,
      el("p", { class: "pcard-last muted small" }, "Last data day: " + (p.last_data_day ? fmtDayLong(p.last_data_day) : "none yet"))),
    "pcard:" + p.patient_id);
    return el("li", { class: "pcard panel edge-" + edgeOf(p.status, p.level) }, link);
  }

  // ---- patient view ---------------------------------------------------------------------

  function patientView() {
    const r = state.route;
    const d = state.detail[r.pid];
    const out = [el("p", { class: "back" }, fk(el("a", { href: "#/patients" }, "← All patients"), "back"))];
    if (!d) { out.push(loadingOrError(r.pid)); return out; }
    out.push(patientHeader(d));
    out.push(tabs("Patient sections", PATIENT_TABS, r.tab, (id) => patientHash(d.patient_id, id), "p"));
    for (const t of PATIENT_TABS) {
      const on = t.id === r.tab;
      const pnl = el("div", { role: "tabpanel", id: "ppanel-" + t.id, "aria-labelledby": "ptab-" + t.id, class: "tabpanel", hidden: !on });
      if (on) append(pnl, [TAB_VIEWS[t.id](d)]);
      out.push(pnl);
    }
    return out;
  }

  function patientHeader(d) {
    return el("section", { class: "panel phead edge-" + edgeOf(d.status, d.level), "aria-labelledby": "patient-title" },
      el("div", { class: "page-head" },
        el("div", null, el("p", { class: "eyebrow" }, "Patient"),
          el("h1", { id: "patient-title" }, d.label, " ", exampleTag(d))),
        el("div", { class: "head-actions" }, updatedLine(), refreshButton())),
      el("div", { class: "badges" }, statusBadge(d.status), levelTag(d.level),
        el("span", { class: "muted" }, "Last data day: " + (d.last_data_day ? fmtDayLong(d.last_data_day) : "none yet"))),
      el("p", { class: "summary" }, d.summary));
  }

  const TAB_VIEWS = {
    overview: overviewTab, reasoning: reasoningTab, progress: progressTab, rounds: roundsTab,
    mind: mindTab, history: historyTab, safety: safetyTab,
  };

  // ---- overview -------------------------------------------------------------------------

  function overviewTab(d) {
    const open = d.attention_items.filter((i) => i.state === "open").sort((a, b) =>
      (LEVEL_ORDER[a.level] ?? 3) - (LEVEL_ORDER[b.level] ?? 3));
    const held = panel({ eyebrow: "Now", title: "What needs attention", edge: open.length ? edgeOf(null, open[0].level) : "calm" },
      open.length ? el("ul", { class: "items" }, open.map((i) => attentionItem(d, i, true))) : muted("Nothing is held right now."));

    const sug = d.suggestions[d.suggestions.length - 1];
    const latest = panel({ eyebrow: "Latest suggestion", title: sug ? cap(actionWords(sug.action)) : "None yet" },
      sug ? [
        el("p", { class: "quote" }, sug.text),
        facts([["Offered", fmtDayLong(sug.date)], ["Status", words(sug.status)],
          ["Answer", sug.answer ? words(sug.answer) : "no answer yet"], sug.felt ? ["Felt", words(sug.felt)] : null,
          ["Because of", KIND_WORD[sug.attention_kind] || words(sug.attention_kind)], ["Worded by", words(sug.wording)]]),
      ] : muted("Nothing has been suggested yet."));

    const n = d.notes[d.notes.length - 1];
    const note = panel({ eyebrow: "Latest note", title: n ? fmtTime(n.at) : "None yet", edge: n && n.classification.crisis ? "ember" : null },
      n ? [noteLabels(n), n.text !== undefined ? el("blockquote", { class: "quote" }, n.text) : el("p", { class: "muted small" }, "Only labels are shown. The patient does not share note text.")]
        : muted("No notes."));

    const today = d.progress.today || d.last_data_day;
    const days7 = today ? d.progress.series.filter((s) => dayDiff(s.date, today) >= 0 && dayDiff(s.date, today) < 7).length : 0;
    const rounds14 = today ? d.progress.rounds.energy_series.filter((x) => dayDiff(localDay(x.started_at), today) < 14).length : 0;
    const key = panel({ eyebrow: "Key facts", title: "At a glance" },
      facts([["Last data day", d.last_data_day ? fmtDayLong(d.last_data_day) : "none yet"],
        ["Days with data, last 7", days7 + " of 7"], ["Rounds, last 14 days", String(rounds14)],
        ["Note text shared", d.share_notes ? "yes" : "no, labels only"],
        ["Outside processing", d.allow_outside_processing ? "allowed" : "not allowed"]]));
    return el("div", { class: "grid-2" }, held, latest, note, key);
  }

  function attentionItem(d, i, withAck) {
    const open = i.state === "open";
    const det = Object.entries(i.detail || {}).map(([k, v]) => words(k) + ": " + (typeof v === "object" ? JSON.stringify(v) : v)).join(", ");
    const held = open ? dayDiff(i.since, d.progress.today || i.since) : null;
    return el("li", { class: "item edge-" + (open ? edgeOf(null, i.level) : "calm") + (open ? "" : " closed") },
      el("div", { class: "item-head" },
        el("div", null, levelTag(open ? i.level : (i.peak_level || i.level)), " ",
          el("strong", null, KIND_WORD[i.kind] || words(i.kind))),
        open && withAck ? ackButton(i) : null),
      el("p", { class: "small" }, open
        ? "Held since " + fmtDayLong(i.since) + (held !== null ? " (" + (held === 0 ? "today" : held + (held === 1 ? " day" : " days")) + ")" : "")
        : "From " + fmtDay(i.since) + " to " + fmtDay(i.closed_at) + ". Ended: " + ruleWords(i.close_reason) + "."),
      el("p", { class: "small muted" }, "Why: " + ruleWords(i.reason) + (det ? " (" + det + ")" : "") + "."),
      el("p", { class: "small" }, fk(el("a", { href: patientHash(d.patient_id, "reasoning", i.id) }, "How the system reasoned about this"), "why:" + i.id)),
      i.history && i.history.length ? disclosure("hist:" + i.id, "History (" + i.history.length + ")",
        () => el("ol", { class: "small plain" }, i.history.map((h) => el("li", null, fmtTime(h.at) + ": " + words(h.event)
          + (h.level ? " (" + (LEVEL[h.level] ? LEVEL[h.level].word : words(h.level)) + ")" : "") + (h.reason ? ", " + ruleWords(h.reason) : ""))))) : null);
  }

  function ackButton(item) {
    const b = fk(el("button", { type: "button", class: "pill pill-primary small-pill" }, "Acknowledge"), "ack:" + item.id);
    b.setAttribute("aria-label", "Acknowledge: " + (KIND_WORD[item.kind] || words(item.kind)));
    b.addEventListener("click", async () => {
      b.disabled = true;
      try {
        await api("POST", "/v1/clinic/attention/" + encodeURIComponent(item.id) + "/ack");
        flash("Acknowledged. The same evidence will not reopen it; new evidence will.");
        state.trace = {};
        state.focusKey = "refresh";
        await refresh();
      } catch (e) {
        flash("Could not acknowledge: " + e.message);
        b.disabled = false;
      }
    });
    return b;
  }

  function noteLabels(n) {
    const c = n.classification;
    return el("div", { class: "labels" },
      el("span", { class: "tag" }, "mood: " + words(c.mood)),
      el("span", { class: "tag" }, "topic: " + words(c.topic)),
      el("span", { class: "tag" }, c.asks_for_help ? "asks for help" : "does not ask for help"),
      c.crisis ? el("span", { class: "badge lv-urgent" }, marker("circle"), "help screen shown") : null,
      c.crisis ? el("span", { class: "tag tag-draft" }, "help wording is a draft, not reviewed") : null);
  }

  // ---- reasoning ------------------------------------------------------------------------

  function reasoningTab(d) {
    const r = state.route;
    const k = traceKey(d.patient_id, r.sub);
    const t = state.trace[k];
    if (!t) return loadingOrError(k);
    const out = [];

    const cur = panel({ eyebrow: "Current state", title: "Why things are as they are now", edge: edgeOf(t.status, d.level) },
      el("div", { class: "badges" }, statusBadge(t.status)),
      t.current.length ? el("ul", { class: "items" }, t.current.map((c) => el("li", { class: "item edge-" + edgeOf(null, c.level) },
        el("div", { class: "item-head" }, el("div", null, levelTag(c.level), " ", el("strong", null, KIND_WORD[c.kind] || words(c.kind)),
          el("span", { class: "muted" }, " since " + fmtDay(c.since)))),
        el("p", { class: "small" }, "Why this level: " + cap(ruleWords(c.level_rule)) + factsText(c.level_detail) + "."),
        el("p", { class: "small" }, "Last done: " + (c.last_action ? actionText(c.last_action) + " (" + fmtTime(c.last_action.at) + ")" : "nothing yet.")),
        el("p", { class: "small" }, fk(el("a", { href: patientHash(d.patient_id, "reasoning", c.attention_id) }, "Show only the chains about this item"), "cur:" + c.attention_id)))))
        : muted("Nothing is held. " + (STATUS[t.status] ? STATUS[t.status].word + "." : "")));
    out.push(cur);

    const toggle = fk(el("button", { type: "button", class: "pill pill-outline", "aria-pressed": state.traceAll ? "false" : "true" },
      marker(state.traceAll ? "square-hollow" : "square", "check"), "Only chains that changed something"), "trace-filter");
    toggle.addEventListener("click", async () => {
      state.traceAll = !state.traceAll;
      state.focusKey = "trace-filter";
      render();
      await load(false);
      render();
    });
    const filterLine = el("div", { class: "filter-row" }, toggle,
      r.sub ? el("span", { class: "small" }, "Showing chains about one item. ",
        fk(el("a", { href: patientHash(d.patient_id, "reasoning") }, "Show every item"), "trace-all-items")) : null);

    const list = el("ol", { class: "timeline" }, t.chains.map((c) => chainView(c)));
    out.push(panel({ eyebrow: "Decision trace", title: "What happened, newest first" },
      el("p", { class: "muted small" }, "Each block is one trigger and everything it caused, in the order the system works: trigger, watchers, attention, response, the two model levels, notifier and learning. Changed means it opened or raised attention, made a suggestion, sent a message or refused a model answer."),
      filterLine,
      t.chains.length ? list : muted(state.traceAll ? "No steps recorded yet." : "No chain changed anything yet. Turn the filter off to see all.")));
    return out;
  }

  function factsText(f) {
    if (!f || typeof f !== "object") return "";
    const parts = [];
    if (f.low_days !== undefined) parts.push(f.low_days + " low days");
    if (f.mean_low_z !== undefined && f.mean_low_z !== null) parts.push("mean z " + fmtZ(f.mean_low_z));
    for (const k of Object.keys(f)) if (!["low_days", "mean_low_z"].includes(k) && typeof f[k] !== "object") parts.push(words(k) + " " + words(f[k]));
    return parts.length ? " (" + parts.join(", ") + ")" : "";
  }

  function actionText(a) {
    const dt = a.detail || {};
    if (a.layer === "notifier") return (NOTIFY_WORD[dt.reason] || words(a.code)) + " (message to the clinic)";
    if (a.code === "suggested") return "suggested " + actionWords(dt.action);
    if (a.code === "blocked" || a.code === "none") return "no new suggestion, because " + (BECAUSE_WORD[dt.because] || words(dt.because));
    return words(a.code);
  }

  function outcomeOf(e) {
    if (["refused", "partly_refused", "failed", "not_sent"].includes(e.code)) return { cls: "refused", shape: "cross", word: "Refused" };
    if (e.layer === "response" && (e.code === "none" || e.code === "blocked")) return { cls: "none", shape: "slash", word: "None" };
    if (e.layer === "notifier" && e.code === "suppressed") return { cls: "none", shape: "slash", word: "Not sent" };
    if (e.notable) return { cls: "changed", shape: "diamond", word: "Changed" };
    return { cls: "info", shape: "dot", word: "" };
  }

  function chainView(c) {
    const trig = c.entries.find((e) => e.layer === "trigger") || { code: c.trigger, detail: {} };
    const entries = c.entries.slice().sort((a, b) => LAYER_ORDER.indexOf(a.layer) - LAYER_ORDER.indexOf(b.layer));
    return el("li", { class: "chain " + (c.changed ? "chain-changed" : "chain-quiet") },
      el("div", { class: "chain-head" },
        el("span", { class: "chain-mark" }, marker(c.changed ? "diamond" : "circle-hollow"), c.changed ? "Changed something" : "No change"),
        el("strong", null, triggerWord(trig.code)),
        el("span", { class: "muted small" }, fmtTime(c.at))),
      el("ol", { class: "layers" }, entries.map((e) => {
        const o = outcomeOf(e);
        return el("li", { class: "step step-" + o.cls },
          el("div", { class: "step-head" },
            el("span", { class: "step-layer" }, LAYER_NAME[e.layer] || words(e.layer)),
            o.word ? el("span", { class: "step-out out-" + o.cls }, marker(o.shape), o.word) : null),
          el("p", { class: "step-sum" }, stepSummary(e)),
          disclosure("tr:" + e.id, "Details", () => detailList(e.detail)));
      })));
  }

  function triggerWord(code) {
    if (TRIGGER_WORD[code]) return TRIGGER_WORD[code];
    if (/^review_/.test(code)) return "Learning review (" + words(code.slice(7)) + ")";
    return cap(words(code));
  }

  function stepSummary(e) {
    const d = e.detail || {};
    switch (e.layer) {
      case "trigger": {
        if (e.code === "day") return "Days received: " + (d.days ?? "?") + (d.last_day && d.last_day !== "none" ? ", latest " + fmtDay(d.last_day) : "") + (d.rejected ? ", " + d.rejected + " refused as implausible" : "") + ".";
        if (e.code === "note") return "Labels: mood " + words(d.mood) + ", topic " + words(d.topic) + (d.crisis ? ", asked for help" : "") + ". The note text is never part of the trace.";
        if (e.code === "round") return cap(words(d.mode)) + " round, energy " + (d.energy_bucket ? words(d.energy_bucket) : "not known yet") + ", " + (d.ended_by === "finished" ? "finished" : "ended by " + words(d.ended_by)) + ".";
        if (e.code === "feedback") return "Answer to " + actionWords(d.action) + ": " + words(d.answer) + (d.felt ? ", felt " + words(d.felt) : "") + ".";
        if (e.code === "scenario") return "Scenario: " + words(d.name || "settle") + ".";
        if (e.code === "ack") return "Acknowledged: " + (KIND_WORD[d.kind] || words(d.kind)) + ".";
        if (e.code === "rule") return "Rules now: " + ((d.rules || []).map(words).join(", ") || "none") + ".";
        return triggerWord(e.code) + ".";
      }
      case "watchers": {
        const f = (d.facts || {}).deviation;
        const dev = f ? f.low_days + " of the last " + f.of_days + " days below own normal" + (f.mean_low_z !== null && f.mean_low_z !== undefined ? " (mean z " + fmtZ(f.mean_low_z) + ")" : "") + "; " + f.needed + " needed. " : "";
        const fired = (d.fired || []).map((x) => (KIND_WORD[x.kind] || words(x.kind)) + ": " + ({ open: "opened", update: "updated", close: "closed" }[x.op] || x.op));
        const quiet = (d.quiet || []).length;
        return (fired.length ? "Fired: " + fired.join("; ") + ". " : "All watchers stayed quiet. ") + dev + (fired.length ? quiet + " stayed quiet." : "");
      }
      case "attention": {
        const kind = KIND_WORD[d.kind] || words(d.kind);
        const lv = (x) => (LEVEL[x] ? LEVEL[x].word : words(x));
        if (e.code === "opened") return "Opened “" + kind + "” at " + lv(d.level) + ", because " + ruleWords(d.rule) + factsText(d.facts) + ".";
        if (e.code === "raised") return "Raised “" + kind + "” from " + lv(d.from_level) + " to " + lv(d.level) + ", because " + ruleWords(d.rule) + ".";
        if (e.code === "closed") return "Closed “" + kind + "”: " + ruleWords(d.rule) + ".";
        return cap(words(e.code)) + ".";
      }
      case "response": {
        if (e.code === "suggested") {
          const rk = d.ranking || {};
          const removed = (rk.rules || []).filter((x) => x.removed && x.removed.length).map((x) => words(x.type) + " removed " + x.removed.map(actionWords).join(", "));
          const moved = (rk.lessons || []).map((x) => "a lesson moved " + actionWords(x.action) + " " + x.moves);
          return "Suggested " + actionWords(d.action) + " for “" + (KIND_WORD[d.kind] || words(d.kind)) + "”. " +
            (removed.length ? "Patient rules: " + removed.join("; ") + ". " : "No patient rule changed the list. ") +
            (moved.length ? cap(moved.join("; ")) + "." : "No lesson changed the order.");
        }
        return "None, because " + (BECAUSE_WORD[d.because] || words(d.because)) + ".";
      }
      case "level1": {
        const task = TASK_WORD[d.task] || words(d.task);
        const used = d.used ? " Used: " + words(d.used) + "." : "";
        if (e.code === "off") return "Off for " + task + "." + used;
        if (e.code === "accepted") return "Model answer for " + task + " passed the output gate." + used;
        if (e.code === "no_reply") return "No answer for " + task + "." + used;
        return "Model answer for " + task + " refused by the output gate (" + (d.reasons || []).map(words).join(", ") + ")." + used;
      }
      case "level2": {
        const task = TASK_WORD[d.task] || words(d.task);
        if (e.code === "not_sent") return "Nothing sent for " + task + ": " + words(d.reason || (d.reasons || [])[0]) + ".";
        if (e.code === "accepted") return "Anonymized pack sent for " + task + ". Code confirmed " + (d.confirmed || []).length + " claims and dropped " + (d.dropped || []).length + ".";
        if (e.code === "no_reply") return "Anonymized pack sent for " + task + "; no answer came back.";
        return "Answer for " + task + " refused (" + (d.reasons || []).map(words).join(", ") + ").";
      }
      case "notifier":
        return (NOTIFY_WORD[d.reason] || cap(words(e.code))) + " (" + (LEVEL[d.level] ? LEVEL[d.level].word : words(d.level)) + ").";
      case "learning":
        return "Looked at " + (d.evidence_rows ?? 0) + " pieces of evidence; " + (d.proposed_by_code ?? 0) + " proposed by code; " +
          (d.added ?? 0) + " lessons added, " + ((d.retired || []).length) + " retired, " + ((d.refused || []).length) + " proposals refused.";
      default:
        return words(e.code);
    }
  }

  // ---- progress (charts) ---------------------------------------------------------------------

  function chartWidth() {
    const m = $("main");
    const w = m && m.clientWidth ? m.clientWidth : 0;
    return w ? clamp(Math.round(w - 84), 290, 1100) : 760;
  }

  function progressTab(d) {
    const pr = d.progress;
    const has = (k) => pr.series.some((s) => s.z && s.z[k] !== undefined);
    const out = [];
    for (const m of METRICS) {
      if (m.key === "steps" || m.key === "walking_speed_m_s" || has(m.key)) out.push(dailyChart(d, m));
    }
    out.push(weeklyChart(d));
    out.push(offeredPanel(d));
    return out;
  }

  function legendRow(items) {
    return el("ul", { class: "chart-legend" }, items.filter(Boolean).map((it) =>
      el("li", null, it.swatch ? el("span", { class: "swatch " + it.swatch, "aria-hidden": "true" }) : marker(it.shape, it.cls), it.label)));
  }

  function dailyChart(d, m) {
    const pr = d.progress;
    const band = pr.band || { low_z: -1.5, high_z: 1.5 };
    const today = pr.today || (pr.series.length ? pr.series[pr.series.length - 1].date : isoDay(new Date()));
    const byDate = {};
    for (const s of pr.series) byDate[s.date] = s;
    const first = pr.series.length ? pr.series[0].date : addDays(today, -27);
    const n = Math.max(1, dayDiff(first, today) + 1);
    const W = state.chartWidth, compact = W < 560;
    const L = compact ? 82 : 100, R = 14, T = 28, PH = compact ? 170 : 210, B = 62;
    const H = T + PH + B;
    const ZMAX = 3, ZMIN = -4;
    const slot = (W - L - R) / n;
    const x = (i) => L + slot * (i + 0.5);
    const y = (z) => T + (ZMAX - clamp(z, ZMIN, ZMAX)) * PH / (ZMAX - ZMIN);
    const yb = T + PH;
    const pts = [];
    for (let i = 0; i < n; i++) {
      const ds = addDays(first, i);
      const s = byDate[ds];
      const z = s && s.z && s.z[m.key] !== undefined ? s.z[m.key] : null;
      pts.push({ i, date: ds, rec: !!s, z, v: s && s.values ? s.values[m.key] : undefined, example: !!(s && s.example) });
    }
    const valid = pts.filter((p) => p.z !== null);
    const kindOf = (z) => (z <= band.low_z ? "low" : z >= band.high_z ? "high" : "in");
    const lows = valid.filter((p) => kindOf(p.z) === "low").length;
    const highs = valid.filter((p) => kindOf(p.z) === "high").length;
    const missing = pts.filter((p) => !p.rec).length;
    const learning = pts.filter((p) => p.rec && p.z === null).length;
    const anyExample = pts.some((p) => p.example);
    const usual = pr.usual && pr.usual[m.key] !== undefined ? m.unit(pr.usual[m.key]) : null;
    const key = "daily:" + d.patient_id + ":" + m.key;

    const caption = m.title + " each day for the last " + n + " days, compared with this person's own normal" +
      (usual ? " (usual is about " + usual + ")" : "") + ": " + lows + " days below, " + highs + " above, " + missing + " without data.";

    const s = svg("svg", { class: "chart", viewBox: "0 0 " + W + " " + H, role: "group", "aria-label": caption });
    // Regions and labels
    s.appendChild(svg("rect", { class: "c-band", x: L, y: y(band.high_z), width: W - L - R, height: y(band.low_z) - y(band.high_z) }));
    s.appendChild(svg("line", { class: "c-band-edge", x1: L, x2: W - R, y1: y(band.high_z), y2: y(band.high_z) }));
    s.appendChild(svg("line", { class: "c-band-edge", x1: L, x2: W - R, y1: y(band.low_z), y2: y(band.low_z) }));
    // Attention episodes behind the line
    const rows = [[], []];
    for (const ep of pr.episodes || []) {
      const end = ep.end || today;
      if (end < first || ep.start > today) continue;
      const i0 = Math.max(0, dayDiff(first, ep.start)), i1 = Math.min(n - 1, dayDiff(first, end));
      const x0 = L + slot * i0, x1 = L + slot * (i1 + 1);
      s.appendChild(svg("rect", { class: "c-episode", x: x0, y: T, width: Math.max(2, x1 - x0), height: PH }));
      const label = KIND_SHORT[ep.kind] || words(ep.kind);
      const w = label.length * 7 + 8;
      const lx = Math.min(x0 + 4, W - R - w);
      for (let row = 0; row < rows.length; row++) {
        if (rows[row].every((r) => lx > r[1] || lx + w < r[0])) {
          rows[row].push([lx, lx + w]);
          s.appendChild(svg("text", { class: "c-ep-label", x: lx, y: row === 0 ? T - 8 : T + 15 }, label));
          break;
        }
      }
    }
    s.appendChild(svg("line", { class: "c-usual", x1: L, x2: W - R, y1: y(0), y2: y(0) }));
    s.appendChild(svg("line", { class: "c-axis", x1: L, x2: W - R, y1: yb, y2: yb }));
    s.appendChild(svg("text", { class: "c-gutter", x: L - 8, y: y((ZMAX + band.high_z) / 2) + 4, "text-anchor": "end" }, "above usual"));
    s.appendChild(svg("text", { class: "c-gutter c-gutter-strong", x: L - 8, y: y(0) + 4, "text-anchor": "end" }, "usual"));
    s.appendChild(svg("text", { class: "c-gutter", x: L - 8, y: y((band.low_z + ZMIN) / 2) + 4, "text-anchor": "end" }, "below usual"));
    s.appendChild(svg("text", { class: "c-band-label", x: L + 6, y: y(band.high_z) + 15 }, "own normal"));
    // Week starts on the x axis
    let lastLabelX = -1e9;
    for (const p of pts) {
      if (parseDay(p.date).getUTCDay() !== 1) continue;
      const px = x(p.i) - slot / 2;
      s.appendChild(svg("line", { class: "c-tick", x1: px, x2: px, y1: yb, y2: yb + 6 }));
      if (px - lastLabelX >= 52) {
        s.appendChild(svg("text", { class: "c-date", x: px, y: yb + 46, "text-anchor": "middle" }, fmtDay(p.date)));
        lastLabelX = px;
      }
    }
    // Missing days and days still learning: markers on the axis, never joined by a line.
    for (const p of pts) {
      if (!p.rec) s.appendChild(svg("rect", { class: "c-missing", x: x(p.i) - 1.5, y: yb - 6, width: 3, height: 12 }));
      else if (p.z === null) s.appendChild(svg("rect", { class: "c-learning", x: x(p.i) - 3, y: yb - 3, width: 6, height: 6 }));
    }
    // Suggestions as small markers under the axis
    for (const sg of d.suggestions || []) {
      if (sg.date < first || sg.date > today) continue;
      const i = dayDiff(first, sg.date);
      const done = sg.answer === "did_it" || sg.status === "done" || sg.round_completed;
      const g = svg("g", { class: "c-sug" + (done ? " done" : "") });
      g.appendChild(shapeNodes("diamond", x(i), yb + 22, 5));
      s.appendChild(g);
    }
    // The line: only consecutive days with values are joined.
    let seg = [];
    const flush = () => {
      if (seg.length > 1) s.appendChild(svg("polyline", { class: "c-line", points: seg.join(" ") }));
      seg = [];
    };
    for (const p of pts) {
      if (p.z === null) { flush(); continue; }
      seg.push(x(p.i).toFixed(1) + "," + y(p.z).toFixed(1));
    }
    flush();
    const r = compact ? 4.5 : 5.5;
    for (const p of valid) {
      const k = kindOf(p.z);
      const g = svg("g", { class: "c-pt c-pt-" + k });
      g.appendChild(shapeNodes(k === "low" ? "tri-down" : k === "high" ? "tri-up" : "dot", x(p.i), y(p.z), k === "in" ? r * 1.1 : r * 1.3));
      s.appendChild(g);
    }
    // Selection guide and ring
    const guide = svg("line", { class: "c-guide", x1: 0, x2: 0, y1: T, y2: yb, visibility: "hidden" });
    const ring = svg("circle", { class: "c-ring", cx: 0, cy: 0, r: r + 4, visibility: "hidden" });
    s.appendChild(guide);
    s.appendChild(ring);

    const readout = el("p", { class: "readout", "aria-live": "polite" }, "Choose a day: tap the chart, or tab into it and use the arrow keys.");
    const describe = (p) => {
      const where = kindOf(p.z) === "low" ? "Below own normal" : kindOf(p.z) === "high" ? "Above own normal" : "Within own normal";
      return fmtDayLong(p.date) + ": " + (typeof p.v === "number" ? m.unit(p.v) : "value not sent") + ". " + where + " (z " + fmtZ(p.z) + ")." +
        (usual ? " Usual is about " + usual + "." : "") + (p.example ? " Example data." : "");
    };
    const hits = [];
    const select = (idx, focus) => {
      const p = valid[idx];
      if (!p) return;
      state.chartSel[key] = p.date;
      guide.setAttribute("x1", x(p.i)); guide.setAttribute("x2", x(p.i)); guide.setAttribute("visibility", "visible");
      ring.setAttribute("cx", x(p.i)); ring.setAttribute("cy", y(p.z)); ring.setAttribute("visibility", "visible");
      readout.textContent = describe(p);
      hits.forEach((h, j) => h.setAttribute("tabindex", j === idx ? "0" : "-1"));
      if (focus) hits[idx].focus({ preventScroll: true });
    };
    const hitGroup = svg("g", { class: "c-hits" });
    valid.forEach((p, idx) => {
      const h = svg("rect", { class: "c-hit", x: x(p.i) - slot / 2, y: T, width: slot, height: PH, tabindex: idx === valid.length - 1 ? "0" : "-1",
        role: "img", "aria-label": describe(p), focusable: "true" });
      fk(h, key + ":" + p.date);
      h.addEventListener("focus", () => select(idx, false));
      h.addEventListener("click", () => select(idx, true));
      h.addEventListener("keydown", (ev) => keyMove(ev, idx, valid.length, (j) => select(j, true)));
      hits.push(h);
      hitGroup.appendChild(h);
    });
    s.appendChild(hitGroup);
    s.addEventListener("click", (ev) => {
      if (!s.getBoundingClientRect || !valid.length) return;
      const box = s.getBoundingClientRect();
      if (!box.width) return;
      const vx = (ev.clientX - box.left) * W / box.width;
      let best = 0;
      valid.forEach((p, j) => { if (Math.abs(x(p.i) - vx) < Math.abs(x(valid[best].i) - vx)) best = j; });
      select(best, true);
    });
    const selIdx = valid.findIndex((p) => p.date === state.chartSel[key]);
    if (selIdx >= 0) select(selIdx, false);

    return panel({ eyebrow: "Daily", title: m.title, aside: anyExample ? exampleTag({ example: true }) : null },
      el("p", { class: "caption" }, caption),
      legendRow([{ shape: "dot", cls: "lg-in", label: "Day within own normal" },
        { shape: "tri-down", cls: "lg-low", label: "Below own normal" },
        { shape: "tri-up", cls: "lg-high", label: "Above own normal" },
        { shape: "bar", cls: "lg-missing", label: "No data that day" },
        learning ? { shape: "square-hollow", cls: "lg-learning", label: "Own normal still being learned" } : null,
        { swatch: "sw-episode", label: "Attention held" },
        { shape: "diamond", cls: "lg-sug", label: "Suggestion (filled: done)" }]),
      el("div", { class: "chart-box" }, s),
      readout);
  }

  function keyMove(ev, idx, count, go) {
    let j = null;
    if (ev.key === "ArrowRight" || ev.key === "ArrowDown") j = Math.min(count - 1, idx + 1);
    else if (ev.key === "ArrowLeft" || ev.key === "ArrowUp") j = Math.max(0, idx - 1);
    else if (ev.key === "Home") j = 0;
    else if (ev.key === "End") j = count - 1;
    if (j === null) return;
    ev.preventDefault();
    go(j);
  }

  function weeklyChart(d) {
    const pr = d.progress;
    const band = pr.band || { low_z: -1.5, high_z: 1.5 };
    const weeks = pr.weekly || [];
    const W = state.chartWidth, compact = W < 560;
    const L = compact ? 104 : 150, R = compact ? 56 : 120, T = 34, RH = 46;
    const H = T + RH * weeks.length + 8;
    const ZMAX = 3, ZMIN = -4;
    const xz = (z) => L + (clamp(z, ZMIN, ZMAX) - ZMIN) * (W - L - R) / (ZMAX - ZMIN);
    const caption = "Average daily movement per week (steps and walking speed together), compared with own normal. Bars to the left are below usual.";
    const s = svg("svg", { class: "chart", viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": caption + " " +
      weeks.map((w) => "Week of " + fmtDay(w.week_start) + ": " + (w.mean_movement_z === null ? "not enough history" : fmtZ(w.mean_movement_z)) + ", " + w.days_with_data + " of " + (w.days_with_data + w.days_missing) + " days.").join(" ") });
    s.appendChild(svg("rect", { class: "c-band", x: xz(band.low_z), y: T - 6, width: xz(band.high_z) - xz(band.low_z), height: H - T }));
    s.appendChild(svg("text", { class: "c-band-label", x: xz(0), y: T - 12, "text-anchor": "middle" }, "own normal"));
    s.appendChild(svg("text", { class: "c-gutter", x: xz(ZMIN) + 2, y: T - 12 }, compact ? "below" : "below usual"));
    s.appendChild(svg("text", { class: "c-gutter", x: xz(ZMAX) - 2, y: T - 12, "text-anchor": "end" }, compact ? "above" : "above usual"));
    s.appendChild(svg("line", { class: "c-usual", x1: xz(0), x2: xz(0), y1: T - 6, y2: H }));
    weeks.forEach((w, i) => {
      const cy = T + RH * i + RH / 2;
      const total = w.days_with_data + w.days_missing;
      s.appendChild(svg("text", { class: "c-week", x: 4, y: cy - 3 }, (compact ? "" : "Week of ") + fmtDay(w.week_start)));
      s.appendChild(svg("text", { class: "c-week-sub", x: 4, y: cy + 15 }, w.days_with_data + " of " + total + " days"));
      const v = w.mean_movement_z;
      if (v === null || v === undefined) {
        s.appendChild(svg("text", { class: "c-nohist", x: xz(0) + 8, y: cy + 5 }, "not enough history"));
        return;
      }
      const k = v <= band.low_z ? "low" : v >= band.high_z ? "high" : "in";
      const x0 = Math.min(xz(0), xz(v)), wd = Math.max(2, Math.abs(xz(v) - xz(0)));
      s.appendChild(svg("rect", { class: "c-bar c-bar-" + k, x: x0, y: cy - 11, width: wd, height: 22, rx: 3 }));
      const lbl = fmtZ(v) + (k === "low" ? " below" : k === "high" ? " above" : "");
      s.appendChild(svg("text", { class: "c-bar-value", x: v < 0 && x0 - 6 > L - 40 ? x0 - 6 : x0 + wd + 6, y: cy + 5,
        "text-anchor": v < 0 && x0 - 6 > L - 40 ? "end" : "start" }, lbl));
    });
    return panel({ eyebrow: "Weekly", title: "Week by week" },
      el("p", { class: "caption" }, caption + " Numbers show how far the week was from usual, in this person's typical day-to-day spread."),
      legendRow([{ swatch: "sw-bar-low", label: "Below own normal" }, { swatch: "sw-bar-in", label: "Within own normal" }, { swatch: "sw-bar-high", label: "Above own normal" }]),
      el("div", { class: "chart-box" }, s));
  }

  function offeredPanel(d) {
    const acts = Object.entries(d.progress.actions).filter(([, a]) => a.offered > 0);
    if (!acts.length) return panel({ eyebrow: "Suggestions", title: "What was offered and what followed" }, muted("Nothing offered yet."));
    const measure = acts[0][1].outcome_measure;
    return panel({ eyebrow: "Suggestions", title: "What was offered and what followed" },
      table("What was offered", ["Action", "Offered", "Done", "Not today", "Something else", "No answer", "Open", "Better / same / worse after", "Mean change"],
        acts.map(([k, a]) => [cap(actionWords(k)), a.offered, a.done, a.not_today, a.something_else, a.no_answer, a.open,
          a.outcomes.improved + " / " + a.outcomes.same + " / " + a.outcomes.worse, a.mean_outcome_change === null ? "none" : fmtZ(a.mean_outcome_change)])),
      measure ? el("p", { class: "muted small" }, "Change measured as " + measure + ".") : null);
  }

  // ---- rounds ---------------------------------------------------------------------------------

  function roundsTab(d) {
    const rd = d.progress.rounds;
    const series = rd.energy_series;
    const out = [];
    out.push(energyStrip(d));
    out.push(playedPanel(rd.played_vs_offered));
    if (!series.length) { out.push(panel({ eyebrow: "Rounds", title: "All rounds" }, muted("No rounds yet."))); return out; }
    const sel = state.route.sub;
    const rows = series.slice().reverse().map((x) => [
      fk(el("a", { href: patientHash(d.patient_id, "rounds", x.id), "aria-current": x.id === sel ? "true" : null, class: x.id === sel ? "current" : null }, fmtTime(x.started_at)), "round:" + x.id),
      words(x.mode), words(x.config_id), x.energy_bucket ? words(x.energy_bucket) : "not known yet",
      x.completed ? "yes" : "no (" + words(x.ended_by) + ")", x.after_suggestion ? "yes" : "no",
      x.reading ? words(x.reading) : "", exampleTag(x)]);
    out.push(panel({ eyebrow: "Rounds", title: "All rounds", aside: el("span", { class: "muted small" }, "Choose a date to open the round") },
      table("All rounds", ["Date", "Mode", "Config", "Energy", "Finished", "After a suggestion", "Reading", ""], rows)));
    if (sel) out.push(roundDetail(d, sel));
    return out;
  }

  function energyStrip(d) {
    const series = d.progress.rounds.energy_series;
    const today = d.progress.today || (series.length ? localDay(series[series.length - 1].started_at) : isoDay(new Date()));
    const first = series.length ? localDay(series[0].started_at) : addDays(today, -27);
    const n = Math.max(1, dayDiff(first, today) + 1);
    const W = state.chartWidth, compact = W < 560;
    const L = compact ? 92 : 120, R = 18, T = 16, LH = 34, B = 40;
    const lanes = ["high", "usual", "low", null];
    const laneWord = { high: "high", usual: "usual", low: "low", null: "not known yet" };
    const shape = { high: "tri-up", usual: "dot", low: "tri-down", null: "square-hollow" };
    const H = T + LH * lanes.length + B;
    const slot = (W - L - R) / n;
    const x = (ds) => L + slot * (dayDiff(first, ds) + 0.5);
    const yl = (b) => T + LH * lanes.indexOf(b === undefined ? null : b) + LH / 2;
    const counts = { high: 0, usual: 0, low: 0, null: 0 };
    for (const r of series) counts[r.energy_bucket || null]++;
    const caption = "Energy of each round against this person's usual rounds, over time: " + counts.low + " low, " + counts.usual + " usual, " + counts.high + " high, " + counts.null + " not known yet.";
    const s = svg("svg", { class: "chart", viewBox: "0 0 " + W + " " + H, role: "group", "aria-label": caption });
    lanes.forEach((b) => {
      s.appendChild(svg("line", { class: b === "usual" ? "c-usual" : "c-lane", x1: L, x2: W - R, y1: yl(b), y2: yl(b) }));
      s.appendChild(svg("text", { class: "c-gutter" + (b === "usual" ? " c-gutter-strong" : ""), x: L - 8, y: yl(b) + 4, "text-anchor": "end" }, laneWord[b]));
    });
    const yb = T + LH * lanes.length;
    s.appendChild(svg("line", { class: "c-axis", x1: L, x2: W - R, y1: yb, y2: yb }));
    let lastLabelX = -1e9;
    for (let i = 0; i < n; i++) {
      const ds = addDays(first, i);
      if (parseDay(ds).getUTCDay() !== 1) continue;
      const px = x(ds) - slot / 2;
      s.appendChild(svg("line", { class: "c-tick", x1: px, x2: px, y1: yb, y2: yb + 6 }));
      if (px - lastLabelX >= 52) { s.appendChild(svg("text", { class: "c-date", x: px, y: yb + 26, "text-anchor": "middle" }, fmtDay(ds))); lastLabelX = px; }
    }
    const ring = svg("circle", { class: "c-ring", cx: 0, cy: 0, r: 10, visibility: "hidden" });
    const readout = el("p", { class: "readout", "aria-live": "polite" }, "Choose a round: tap it, or tab into the chart and use the arrow keys. Enter opens it.");
    const describe = (r) => fmtTime(r.started_at) + ": " + words(r.mode) + " round, energy " + laneWord[r.energy_bucket || null] + ", " +
      (r.completed ? "finished" : "not finished") + ", " + (r.after_suggestion ? "played after a suggestion" : "played without a suggestion") + ".";
    const key = "energy:" + d.patient_id;
    const hits = [];
    const select = (idx, focus) => {
      const r = series[idx];
      state.chartSel[key] = r.id;
      ring.setAttribute("cx", x(localDay(r.started_at))); ring.setAttribute("cy", yl(r.energy_bucket || null)); ring.setAttribute("visibility", "visible");
      readout.textContent = describe(r);
      hits.forEach((h, j) => h.setAttribute("tabindex", j === idx ? "0" : "-1"));
      if (focus) hits[idx].focus({ preventScroll: true });
    };
    series.forEach((r, idx) => {
      const cx = x(localDay(r.started_at)), cy = yl(r.energy_bucket || null);
      const b = r.energy_bucket || "unknown";
      const g = svg("g", { class: "c-pt c-pt-" + (b === "low" ? "low" : b === "high" ? "high" : b === "usual" ? "in" : "unknown") + (r.completed ? "" : " c-unfinished") });
      g.appendChild(shapeNodes(shape[r.energy_bucket || null], cx, cy, 7));
      s.appendChild(g);
      const h = fk(svg("circle", { class: "c-hit c-hit-round", cx, cy, r: 13, tabindex: idx === series.length - 1 ? "0" : "-1", role: "link", "aria-label": describe(r) + " Open the round.", focusable: "true" }), key + ":" + r.id);
      h.addEventListener("focus", () => select(idx, false));
      h.addEventListener("click", () => { select(idx, true); navigate(patientHash(d.patient_id, "rounds", r.id)); });
      h.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); state.focusKey = key + ":" + r.id; navigate(patientHash(d.patient_id, "rounds", r.id)); return; }
        keyMove(ev, idx, series.length, (j) => select(j, true));
      });
      hits.push(h);
    });
    s.appendChild(ring);
    hits.forEach((h) => s.appendChild(h));
    const selIdx = series.findIndex((r) => r.id === (state.route.sub || state.chartSel[key]));
    if (selIdx >= 0) select(selIdx, false);
    return panel({ eyebrow: "Rounds over time", title: "Energy of each round", aside: series.some((r) => r.example) ? exampleTag({ example: true }) : null },
      el("p", { class: "caption" }, caption),
      legendRow([{ shape: "tri-up", cls: "lg-high", label: "High" }, { shape: "dot", cls: "lg-in", label: "Usual" },
        { shape: "tri-down", cls: "lg-low", label: "Low" }, { shape: "square-hollow", cls: "lg-learning", label: "Not known yet" },
        { shape: "circle-dashed", cls: "lg-unfinished", label: "Not finished (dashed)" }]),
      series.length ? el("div", { class: "chart-box" }, s) : muted("No rounds yet."),
      series.length ? readout : null);
  }

  function playedPanel(pv) {
    const rows = [["Offered", pv.offered], ["Played when offered", pv.played_when_offered], ["Played without an offer", pv.played_unprompted]];
    const W = state.chartWidth, compact = W < 560;
    const L = compact ? 150 : 200, R = 40, RH = 34;
    const H = RH * rows.length + 4;
    const max = Math.max(1, ...rows.map((r) => r[1]));
    const s = svg("svg", { class: "chart", viewBox: "0 0 " + W + " " + H, role: "img",
      "aria-label": rows.map((r) => r[0] + ": " + r[1]).join(", ") + "." });
    rows.forEach((r, i) => {
      const cy = RH * i + RH / 2;
      s.appendChild(svg("text", { class: "c-week", x: 4, y: cy + 5 }, r[0]));
      const w = Math.max(2, (W - L - R) * r[1] / max);
      s.appendChild(svg("rect", { class: "c-bar " + (i === 0 ? "c-bar-in" : "c-bar-high"), x: L, y: cy - 10, width: w, height: 20, rx: 3 }));
      s.appendChild(svg("text", { class: "c-bar-value", x: L + w + 6, y: cy + 5 }, String(r[1])));
    });
    return panel({ eyebrow: "Rounds", title: "Played and offered" },
      el("p", { class: "caption" }, "How many rounds were offered as a suggestion, and how many were played with and without an offer."),
      el("div", { class: "chart-box" }, s));
  }

  function roundDetail(d, rid) {
    const k = d.patient_id + "/" + rid;
    const r = state.rounds[k];
    if (!r) return panel({ eyebrow: "Round", title: "Loading round" }, loadingOrError(k));
    const out = [];
    out.push(panel({ eyebrow: "Selected round", title: fmtTime(r.started_at), edge: r.energy_bucket === "low" ? "ember" : null,
      aside: exampleTag(r) },
    facts([["Mode", words(r.mode)], ["Config", words(r.config && r.config.config_id)],
      ["Energy", r.energy_bucket ? words(r.energy_bucket) : "not known yet"], ["Energy z", fmtNum(r.energy)],
      ["Duration", fmtNum(r.duration_s, 0) + " s"], ["Finished", r.completed ? "yes" : "no (" + words(r.ended_by) + ")"],
      ["After a suggestion", r.suggestion_id ? "yes" : "no"],
      ["Quality", words(r.quality) + (r.quality_reasons && r.quality_reasons.length ? " (" + r.quality_reasons.map(words).join(", ") + ")" : "")],
      ["Tracking normal", r.tracking ? Math.round(r.tracking.normal_ratio * 100) + "%" : "none"],
      ["Turning", r.turning ? words(r.turning.label) : "none"]])));
    out.push(trailPanel(r));
    const feats = Object.entries(r.features || {});
    out.push(panel({ eyebrow: "Round", title: "Features" },
      feats.length ? table("Features", ["Feature", "Value", "Against own normal"], feats.map(([fkk, v]) => [words(fkk), fmtNum(v, 3),
        r.z && r.z[fkk] !== undefined ? fmtZ(r.z[fkk]) : "no own normal yet"])) : muted("No features.")));
    out.push(readingPanel(d, r));
    const lights = r.lights || [];
    out.push(panel({ eyebrow: "Round", title: "Lights" },
      el("p", { class: "small" }, lights.filter((l) => l.caught).length + " of " + lights.length + " lights caught."),
      disclosure("lights:" + r.id, "Every light (" + lights.length + ")", () => table("Lights", ["Light", "Appeared (s)", "Distance (m)", "Height (m)", "Reaction (s)", "Ended (s)", "Caught"],
        lights.map((l) => [l.i, fmtNum(l.spawn_t, 1), fmtNum(l.dist_m, 1), fmtNum(l.height_m, 1),
          l.first_move_t === null || l.first_move_t === undefined ? "did not move" : fmtNum(l.first_move_t - l.spawn_t, 1),
          fmtNum(l.end_t, 1), l.caught ? "yes" : "no"])))));
    return el("div", { class: "round-detail" }, out);
  }

  function trailPanel(r) {
    const usual = r.usual_round;
    const paths = [r.path, usual && usual.path].filter(Boolean);
    let m = 1;
    for (const p of paths) for (const pt of (p.points || [])) m = Math.max(m, Math.abs(pt[0]), Math.abs(pt[1]));
    const extent = Math.ceil(m * 1.05);
    const figs = el("div", { class: "trails" },
      trailFigure("This round", r, "t-this", extent),
      usual && usual.path ? trailFigure("A usual round, " + fmtTime(usual.started_at), usual, "t-usual", extent)
        : el("p", { class: "muted" }, "No usual round of the same mode to compare with yet."));
    return panel({ eyebrow: "Round", title: "Trail seen from above" },
      el("p", { class: "caption" }, "Where the phone moved during the round, seen from above, both drawn at the same scale. Lights are drawn where the person was when each light ended."),
      legendRow([{ shape: "circle-hollow", cls: "lg-start", label: "Start" }, { shape: "square", cls: "lg-end", label: "End" },
        { shape: "circle", cls: "lg-caught", label: "Light caught" }, { shape: "cross", cls: "lg-missed", label: "Light missed" }]),
      figs);
  }

  function trailFigure(title, rec, cls, extent) {
    const S = 320, pad = 18;
    const sc = (S / 2 - pad) / extent;
    const px = (v) => S / 2 + v * sc;
    const pz = (v) => S / 2 - v * sc;
    const path = rec.path;
    const pts = (path && path.points) || [];
    const hz = (path && path.hz) || 2;
    const lights = rec.lights || [];
    const caught = lights.filter((l) => l.caught).length;
    const label = title + ": " + (pts.length ? "path of " + pts.length + " points" : "no path") + (lights.length ? ", " + caught + " of " + lights.length + " lights caught" : "") + ".";
    const s = svg("svg", { class: "chart trail", viewBox: "0 0 " + S + " " + S, role: "img", "aria-label": label });
    const step = extent > 6 ? 2 : 1;
    for (let g = -Math.floor(extent / step) * step; g <= extent; g += step) {
      s.appendChild(svg("line", { class: g === 0 ? "c-axis" : "c-grid", x1: px(g), x2: px(g), y1: pad, y2: S - pad }));
      s.appendChild(svg("line", { class: g === 0 ? "c-axis" : "c-grid", y1: pz(g), y2: pz(g), x1: pad, x2: S - pad }));
    }
    if (pts.length) {
      s.appendChild(svg("polyline", { class: "c-trail " + cls, points: pts.map((p) => px(p[0]).toFixed(1) + "," + pz(p[1]).toFixed(1)).join(" ") }));
      for (const l of lights) {
        if (typeof l.end_t !== "number") continue;
        const p = pts[clamp(Math.round(l.end_t * hz), 0, pts.length - 1)];
        const g = svg("g", { class: l.caught ? "c-caught" : "c-missed" });
        g.appendChild(shapeNodes(l.caught ? "circle" : "cross", px(p[0]), pz(p[1]), 5));
        s.appendChild(g);
      }
      s.appendChild(svg("circle", { class: "c-start", cx: px(pts[0][0]), cy: pz(pts[0][1]), r: 7 }));
      const last = pts[pts.length - 1];
      s.appendChild(svg("rect", { class: "c-end", x: px(last[0]) - 6, y: pz(last[1]) - 6, width: 12, height: 12 }));
    } else {
      s.appendChild(svg("text", { class: "c-gutter", x: S / 2, y: S / 2, "text-anchor": "middle" }, "No path (screen mode)"));
    }
    // Scale bar
    const sb = svg("g", { class: "c-scale" });
    sb.appendChild(svg("rect", { class: "c-scale-bg", x: pad - 4, y: S - pad - 30, width: sc * step + 28, height: 28, rx: 4 }));
    sb.appendChild(svg("line", { x1: pad + 4, x2: pad + 4 + sc * step, y1: S - pad - 10, y2: S - pad - 10 }));
    sb.appendChild(svg("line", { x1: pad + 4, x2: pad + 4, y1: S - pad - 15, y2: S - pad - 5 }));
    sb.appendChild(svg("line", { x1: pad + 4 + sc * step, x2: pad + 4 + sc * step, y1: S - pad - 15, y2: S - pad - 5 }));
    sb.appendChild(svg("text", { x: pad + 4 + sc * step / 2, y: S - pad - 16, "text-anchor": "middle" }, step + " m"));
    s.appendChild(sb);
    return el("figure", { class: "trail-fig" }, el("figcaption", null, title, rec.example ? " " : "", exampleTag(rec)), s,
      el("p", { class: "small muted" }, lights.length ? caught + " of " + lights.length + " lights caught." : ""));
  }

  function readingPanel(d, r) {
    const a = r.analysis || { status: "off" };
    if (a.status !== "ready") {
      const why = { off: "The movement reading is off on this server.", not_allowed: "This patient's record does not allow outside processing.",
        pending: "The reading is still running.", failed: "The reading failed" + (a.reason ? " (" + words(a.reason) + ")" : "") + "." };
      return panel({ eyebrow: "Level 2", title: "Movement reading" }, el("p", null, why[a.status] || ("Status: " + words(a.status))));
    }
    const rd = a.reading || {};
    const ev = rd.evidence || [];
    const dropped = a.dropped || [];
    return panel({ eyebrow: "Level 2, checked by code", title: "Movement reading" },
      el("p", { class: "small muted" }, "Read by " + words(a.read_by) + ", every claim checked by " + words(a.checked_by) + ", " + fmtTime(a.at) + "."),
      facts(["pattern", "fade_from_light", "reach", "turning", "compared_to_usual", "confidence"].map((k2) =>
        [cap(words(k2)), rd[k2] === null || rd[k2] === undefined ? "none" : words(rd[k2])])),
      el("h3", null, "Claims kept"),
      ev.length ? table("Claims kept", ["Claim", "Lights"], ev.map((e) => [words(e.claim), (e.lights || []).join(", ")])) : muted("None."),
      el("h3", null, "Claims dropped by the code check"),
      dropped.length ? table("Claims dropped", ["Field", "Claimed", "Why dropped"], dropped.map((x) => [words(x.field), typeof x.value === "object" ? JSON.stringify(x.value) : String(x.value), words(x.reason)]))
        : muted("None."));
  }

  // ---- mind ---------------------------------------------------------------------------------

  function ruleText(r) {
    const p = r.params || {};
    if (r.type === "no_action") return "Never suggest " + actionWords(p.action) + ".";
    if (r.type === "seated_only") return "Seated actions only on " + (p.weekdays || []).join(", ") + ".";
    if (r.type === "quiet_hours") return "Quiet from " + p.from + " to " + p.to + ".";
    if (r.type === "max_suggestions_per_day") return "At most " + p.n + " suggestion" + (p.n === 1 ? "" : "s") + " a day.";
    return cap(words(r.type)) + ": " + Object.entries(p).map(([k, v]) => words(k) + " " + v).join(", ") + ".";
  }

  function mindTab(d) {
    const lessons = d.lessons.slice().reverse();
    const les = panel({ eyebrow: "Learned", title: "Lessons" },
      el("p", { class: "muted small" }, "Lessons only re-order suggestions. They never change status, thresholds or attention. Each is recomputed by code from the evidence listed."),
      lessons.length ? el("ul", { class: "items" }, lessons.map((l) => {
        const rejected = l.status === "rejected";
        const stateTag = rejected
          ? el("span", { class: "badge st-rejected" }, marker("cross"), l.end_reason === "patient" ? "Rejected by patient" : "Rejected")
          : l.status === "active" ? el("span", { class: "badge st-active" }, marker("dot"), "Active")
            : el("span", { class: "badge st-ended" }, marker("circle-hollow"), cap(words(l.status)));
        return el("li", { class: "item edge-" + (l.status === "active" ? "sun" : "calm") + (l.status === "active" ? "" : " closed") },
          el("div", { class: "item-head" }, el("strong", null, l.text), stateTag),
          el("p", { class: "small" }, cap(words(l.effect)) + " " + actionWords(l.action) + ", " + (l.context === "any" ? "at any time" : "in the " + words(l.context)) +
            (l.config_id ? ", config " + words(l.config_id) : "") + ". Because: " + words(l.rationale_code) + "."),
          el("p", { class: "small muted" }, "Proposed by " + (l.provenance.model === "code" ? "code" : words(l.provenance.model) + " model") + ", review " + l.provenance.review_id + ", " +
            l.evidence_count + " pieces of evidence, created " + fmtTime(l.created_at) +
            (l.expires_at ? ", expires " + fmtTime(l.expires_at) : "") + (l.end_reason && !rejected ? ", ended: " + words(l.end_reason) : "") + "."),
          disclosure("ev:" + l.id, "Evidence (" + (l.provenance.evidence_ids || []).length + ")", () => el("p", { class: "mono" }, (l.provenance.evidence_ids || []).join(", "))));
      })) : muted("No lessons yet."));
    const rules = panel({ eyebrow: "Set by the patient", title: "The patient's rules" },
      el("p", { class: "muted small" }, "Rules always beat lessons."),
      (d.rules || []).length ? el("ul", { class: "plain" }, d.rules.map((r) => el("li", null, ruleText(r), el("span", { class: "muted small" }, " (since " + fmtDay(r.created_at) + ")"))))
        : muted("No rules set."));
    const qs = d.questions || [];
    const openQ = qs.filter((q) => q.status === "open");
    const doneQ = qs.filter((q) => q.status !== "open");
    const questions = panel({ eyebrow: "Asked to the patient", title: "Questions" },
      el("h3", null, "Open"),
      openQ.length ? table("Open questions", ["Question", "Asked"], openQ.map((q) => [q.text, fmtTime(q.created_at)])) : muted("None open."),
      el("h3", null, "Answered"),
      doneQ.length ? table("Answered questions", ["Question", "Answer", "Asked"], doneQ.map((q) => [q.text, q.answer ? words(q.answer) : words(q.status), fmtTime(q.created_at)])) : muted("None answered yet."));
    return [les, el("div", { class: "grid-2" }, rules, questions)];
  }

  // ---- history ------------------------------------------------------------------------------

  function historyTab(d) {
    const items = d.attention_items.slice().sort((a, b) => String(b.opened_at).localeCompare(String(a.opened_at)));
    const att = panel({ eyebrow: "Attention", title: "Attention episodes" },
      items.length ? el("ul", { class: "items" }, items.map((i) => attentionItem(d, i, false))) : muted("No attention episodes."));
    const sug = panel({ eyebrow: "Response", title: "Suggestions and answers" },
      d.suggestions.length ? table("Suggestions", ["Date", "Action", "Text shown", "Worded by", "Status", "Answer", "Felt", "Because of"],
        d.suggestions.slice().reverse().map((s) => [fmtDay(s.date), cap(actionWords(s.action)), s.text, words(s.wording), words(s.status),
          s.answer ? words(s.answer) : "no answer", s.felt ? words(s.felt) : "", KIND_WORD[s.attention_kind] || words(s.attention_kind)]))
        : muted("No suggestions yet."));
    const notes = panel({ eyebrow: "Patient", title: "Notes" },
      el("p", { class: "muted small" }, d.share_notes ? "The patient shares note text with the clinic." : "Only the time and the labels are shown. The patient does not share the text."),
      d.notes.length ? el("ul", { class: "items" }, d.notes.slice().reverse().map((n) => el("li", { class: "item edge-" + (n.classification.crisis ? "ember" : "calm") },
        el("div", { class: "item-head" }, el("strong", null, fmtTime(n.at))),
        noteLabels(n),
        n.text !== undefined ? el("blockquote", { class: "quote" }, n.text) : null))) : muted("No notes."));
    return [att, sug, notes];
  }

  // ---- safety log -----------------------------------------------------------------------------

  function safetyTab(d) {
    const refusals = d.refusal_log.filter((e) => e.action !== "notify_urgent");
    const detail = (e) => Object.entries(e.detail || {}).map(([k, v]) => words(k) + ": " + (typeof v === "object" ? JSON.stringify(v) : v)).join(", ");
    const ref = panel({ eyebrow: "Gates and checks", title: "What was refused, and why" },
      el("p", { class: "muted small" }, "Codes only, never text."),
      refusals.length ? table("Refusals", ["When", "Who", "What", "Why", "Detail"],
        refusals.map((e) => [fmtTime(e.at), words(e.actor), words(e.action), el("span", { class: "out-refused" }, marker("cross"), words(e.reason)), detail(e)]))
        : muted("Nothing refused."));
    const nl = d.notify_log || [];
    const notif = panel({ eyebrow: "Notifier", title: "Messages to the clinic" },
      el("p", { class: "muted small" }, "Only “needs review” is ever sent: product name, patient label, level, how long. Every send and every suppressed send is listed."),
      nl.length ? table("Notifier events", ["When", "Outcome", "Level", "Channel"],
        nl.map((e) => [fmtTime(e.at), el("span", { class: e.outcome === "ok" ? "out-changed" : "out-none" }, marker(e.outcome === "ok" ? "diamond" : "slash"), NOTIFY_WORD[e.reason] || words(e.reason)),
          LEVEL[(e.detail || {}).level] ? LEVEL[e.detail.level].word : words((e.detail || {}).level), words((e.detail || {}).mode)]))
        : muted("No messages sent or held back."));
    return [ref, notif];
  }

  // ---- demo -----------------------------------------------------------------------------------

  function demoPid() { return state.demo.pid || (state.me && state.me.demo && state.me.demo.patient_id); }

  const DEMO_ACTIONS = [
    { id: "scenario-normal", label: "Scenario: normal", what: "Puts the last five days back to usual for the chosen patient." },
    { id: "scenario-dip", label: "Scenario: dip", what: "Makes the last five days a clear drop, so attention opens and a suggestion follows." },
    { id: "review", label: "Run review", what: "Runs the learning review now: counts evidence, proposes and checks lessons." },
    { id: "tick", label: "Tick", what: "Runs the regular check now: silence, expiry of suggestions, queued messages." },
    { id: "analyze", label: "Run the movement reading again", what: "Sends the chosen round to the outside model again; code checks every claim." },
    { id: "reset", label: "Reset demo patient", what: "Regenerates the demo patient's 28 normal days. Removes its notes, answers and lessons." },
  ];

  function demoView() {
    const pid = demoPid();
    const patients = (state.list && state.list.patients) || [];
    const d = pid ? state.detail[pid] : null;
    const pSel = fk(el("select", { id: "demo-patient" }, patients.map((p) => el("option", { value: p.patient_id, selected: p.patient_id === pid }, p.label + (p.patient_id === (state.me.demo || {}).patient_id ? " (demo patient)" : "")))), "demo-patient");
    pSel.addEventListener("change", async () => {
      state.demo.pid = pSel.value;
      state.demo.rid = null;
      state.focusKey = "demo-patient";
      await load(false);
      render();
    });
    const rounds = d ? d.progress.rounds.energy_series.slice().reverse() : [];
    const rid = state.demo.rid && rounds.some((x) => x.id === state.demo.rid) ? state.demo.rid : (rounds[0] && rounds[0].id);
    state.demo.rid = rid || null;
    const rSel = fk(el("select", { id: "demo-round" }, rounds.map((x) => el("option", { value: x.id, selected: x.id === rid }, fmtTime(x.started_at) + ", " + words(x.mode) + ", energy " + (x.energy_bucket ? words(x.energy_bucket) : "not known")))), "demo-round");
    rSel.addEventListener("change", () => { state.demo.rid = rSel.value; });
    const rows = DEMO_ACTIONS.map((a) => {
      const b = fk(el("button", { type: "button", class: "pill " + (a.id === "reset" ? "pill-outline pill-danger" : "pill-outline"), "data-demo": a.id }, a.label), "demo:" + a.id);
      b.addEventListener("click", () => runDemo(a.id, b));
      const res = state.demo.results[a.id];
      return el("li", { class: "demo-row" }, el("div", null, b), el("div", null,
        el("p", { class: "small" }, a.what),
        el("p", { class: "result small" + (res && res.bad ? " error" : ""), role: "status", "aria-live": "polite", id: "demo-result-" + a.id }, res ? res.text : "")));
    });
    return [
      el("div", { class: "page-head" }, el("div", null, el("p", { class: "eyebrow" }, "Demo mode"), el("h1", null, "Demo controls"))),
      el("p", { class: "lead" }, "These controls change example data only. Every use is logged."),
      panel({ eyebrow: "Acts on", title: "Patient and round" },
        el("div", { class: "form-row" }, el("label", { for: "demo-patient" }, "Patient"), pSel),
        el("div", { class: "form-row" }, el("label", { for: "demo-round" }, "Round, for the movement reading"), rounds.length ? rSel : muted(d ? "This patient has no rounds." : "Loading..."))),
      panel({ eyebrow: "Actions", title: "What you can do" }, el("ul", { class: "demo-list" }, rows)),
    ];
  }

  async function runDemo(what, b) {
    const pid = demoPid();
    let call;
    if (what === "scenario-normal") call = ["POST", "/v1/demo/scenario", { name: "normal", patient_id: pid }];
    else if (what === "scenario-dip") call = ["POST", "/v1/demo/scenario", { name: "dip", patient_id: pid }];
    else if (what === "review") call = ["POST", "/v1/review/run", { patient_id: pid }];
    else if (what === "analyze") {
      if (!state.demo.rid) { state.demo.results[what] = { text: "Choose a round first.", bad: true }; render(); return; }
      call = ["POST", "/v1/demo/analyze", { patient_id: pid, round_id: state.demo.rid }];
    } else if (what === "tick") call = ["POST", "/v1/demo/tick", undefined];
    else if (what === "reset") {
      if (!window.confirm("Reset the demo patient to 28 normal days? This removes its notes, answers and lessons.")) return;
      call = ["POST", "/v1/demo/reset", undefined];
    } else return;
    b.disabled = true;
    state.demo.results[what] = { text: "Working..." };
    $("demo-result-" + what).textContent = "Working...";
    try {
      const res = await api(call[0], call[1], call[2]);
      state.demo.results[what] = { text: demoSummary(what, res) };
    } catch (e) {
      state.demo.results[what] = { text: "Refused: " + e.message, bad: true };
    }
    dropCaches();
    state.focusKey = "demo:" + what;
    await load(true);
    render();
  }

  function demoSummary(what, res) {
    const t = pad2(new Date().getHours()) + ":" + pad2(new Date().getMinutes()) + " ";
    if (what.startsWith("scenario")) return t + "Done. Status now: " + (STATUS[res.status] ? STATUS[res.status].word : words(res.status)) + ".";
    if (what === "review") return t + "Done: " + (res.accepted || []).length + " lessons accepted, " + (res.refused || []).length + " proposals refused.";
    if (what === "analyze") return t + "Movement reading: " + words(res.status) + (res.reason ? " (" + words(res.reason) + ")" : "") + ".";
    if (what === "reset") return t + "Demo patient reset.";
    return t + "Done.";
  }

  // ---- start --------------------------------------------------------------------------

  let resizeTimer = null;

  async function start() {
    loadOpen();
    $("login-form").addEventListener("submit", onLogin);
    $("logout").addEventListener("click", () => logout("You are signed out."));
    wireTabs($("top-tabs"));
    window.addEventListener("hashchange", onHash);
    window.addEventListener("resize", () => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => {
        if (state.token && Math.abs(chartWidth() - state.chartWidth) > 30) render({ scrollY: window.scrollY || 0 });
      }, 200);
    });
    setInterval(() => {
      if (state.token && document.visibilityState !== "hidden" && state.route.name !== "demo") refresh();
    }, REFRESH_MS);
    try {
      const h = await api("GET", "/healthz");
      setProduct(h.product);
    } catch (e) { /* keep the default title */ }
    const t = loadToken();
    if (t) {
      state.token = t;
      try { await afterLogin(); return; } catch (e) { saveToken(null); }
    }
    showLogin();
  }

  document.addEventListener("DOMContentLoaded", start);
})();
