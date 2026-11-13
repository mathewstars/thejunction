/* Clinician page. Numbers and tables first, sentences last.
   Everything from the server is written with textContent or setAttribute, never as HTML. */
(function () {
  "use strict";

  // ---------------------------------------------------------------- helpers
  const $ = (id) => document.getElementById(id);
  const SVG_NS = "http://www.w3.org/2000/svg";

  function el(tag, attrs, ...kids) {
    const n = document.createElement(tag);
    setAttrs(n, attrs);
    add(n, kids);
    return n;
  }
  function svg(tag, attrs, ...kids) {
    const n = document.createElementNS(SVG_NS, tag);
    setAttrs(n, attrs);
    add(n, kids);
    return n;
  }
  function setAttrs(n, attrs) {
    if (!attrs) return;
    for (const k of Object.keys(attrs)) {
      const v = attrs[k];
      if (v === null || v === undefined || v === false) continue;
      if (k === "on") { for (const ev of Object.keys(v)) n.addEventListener(ev, v[ev]); }
      else if (v === true) n.setAttribute(k, "");
      else n.setAttribute(k, String(v));
    }
  }
  function add(n, kids) {
    for (const k of kids) {
      if (k === null || k === undefined || k === false) continue;
      if (Array.isArray(k)) add(n, k);
      else n.appendChild(typeof k === "object" ? k : document.createTextNode(String(k)));
    }
  }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }

  const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  function parseDay(s) { const p = String(s).slice(0, 10).split("-"); return new Date(Date.UTC(+p[0], +p[1] - 1, +p[2])); }
  function dayShort(s) { if (!s) return "–"; const d = parseDay(s); return d.getUTCDate() + " " + MONTHS[d.getUTCMonth()]; }
  function dayLong(s) { const d = parseDay(s); return DAYS[d.getUTCDay()] + " " + d.getUTCDate() + " " + MONTHS[d.getUTCMonth()]; }
  function daysBetween(a, b) { return Math.round((parseDay(b) - parseDay(a)) / 86400000); }
  function ago(day, today) {
    if (!day) return "–";
    const n = daysBetween(day, today);
    return n <= 0 ? "today" : n === 1 ? "yesterday" : n + " d ago";
  }
  function held(day, today) { const n = daysBetween(day, today); return n <= 0 ? "today" : n + " d"; }
  function stamp(iso) {
    if (!iso) return "–";
    const d = new Date(iso);
    const two = (x) => String(x).padStart(2, "0");
    return d.getDate() + " " + MONTHS[d.getMonth()] + " " + two(d.getHours()) + ":" + two(d.getMinutes());
  }
  function num(v, digits) {
    if (v === null || v === undefined) return "–";
    if (typeof v !== "number") return String(v);
    return digits === undefined ? Math.round(v).toLocaleString("en-GB") : v.toFixed(digits);
  }
  function signed(v) { return v === null || v === undefined ? "–" : (v > 0 ? "+" : v < 0 ? "−" : "") + Math.abs(v).toFixed(1); }
  function words(code) { const s = String(code || "").replace(/_/g, " "); return s.charAt(0).toUpperCase() + s.slice(1); }
  function todayStr() { const d = new Date(); return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0"); }

  // ---------------------------------------------------------------- words for codes
  const STATUS = { outside: "Outside normal", no_data: "No data", no_baseline: "Learning", within: "Usual" };
  const LEVEL = { urgent: "Review today", attention: "Attention", watch: "Watch" };
  const LEVEL_ORDER = { urgent: 0, attention: 1, watch: 2 };
  const KIND = {
    deviation: "Low movement", novelty: "Unusual day", silence: "No data", oddity: "Odd values",
    ignored: "Offers unanswered", asked_for_help: "Asked for help", low_notes: "Low notes",
    weak_rounds: "Weak sessions", round_mismatch: "Signals disagree", fading: "Slowing down",
    stopped_early: "Stops early", not_played: "Offers not played", slow_reactions: "Slower reactions",
    flat_face: "Less facial movement", face_flat: "Less facial movement", slower_reactions: "Slower reactions", checkins_stopped: "Check-ins stopped", plans_not_done: "Plans not done",
  };
  const ACTION = {
    ar_round: "Light round", ar_round_seated: "Seated light round", walk_10min: "Short walk",
    daylight_10min: "Daylight", call_someone: "Call someone", breathing_2min: "Breathing",
    focus_game: "Focus game", breathing: "Breathing", checkin: "Evening check-in",
  };
  const ANSWER = { did_it: "Did it", not_today: "Not today", something_else: "Something else" };
  const TRIGGER = {
    day: "Daily data", round: "Session reported", activity: "Activity reported", note: "Note received",
    feedback: "Answer to an offer", rule: "Patient rule changed", tick: "Regular check", scenario: "Demo switch",
    ack: "Clinician acknowledged", lesson_rejected: "Patient rejected a lesson", question_answered: "Patient answered",
    reading: "Movement reading", reading_requested: "Reading requested", queued_message_due: "Queued message due",
    review_seed: "Review", review: "Review", internal: "Internal step", checkin: "Check-in",
  };
  const LAYER = {
    trigger: "Trigger", watchers: "Watchers", attention: "Attention", response: "Response",
    level1: "Model 1 (local)", level2: "Model 2 (outside)", notifier: "Alert", learning: "Learning",
  };
  const METRICS = [
    { key: "movement", label: "Movement", fmt: null },
    { key: "steps", label: "Steps", fmt: (v) => num(v) + " steps" },
    { key: "walking_speed_m_s", label: "Walking speed", fmt: (v) => v.toFixed(2) + " m/s" },
    { key: "hrv_ms", label: "HRV", fmt: (v) => num(v) + " ms" },
    { key: "sleep_h", label: "Sleep", fmt: (v) => v.toFixed(1) + " h" },
  ];
  const kind = (k) => KIND[k] || words(k);
  const action = (a) => ACTION[a] || words(a);

  // ---------------------------------------------------------------- icons (shape carries meaning, not colour alone)
  function icon(shape) {
    const s = svg("svg", { viewBox: "0 0 12 12", "aria-hidden": "true" });
    const c = "currentColor";
    if (shape === "down") s.appendChild(svg("path", { d: "M1 2h10L6 11z", fill: c }));
    else if (shape === "up") s.appendChild(svg("path", { d: "M1 10h10L6 1z", fill: c }));
    else if (shape === "dot") s.appendChild(svg("circle", { cx: 6, cy: 6, r: 4, fill: c }));
    else if (shape === "ring") s.appendChild(svg("circle", { cx: 6, cy: 6, r: 4, fill: "none", stroke: c, "stroke-width": 2 }));
    else if (shape === "dash") s.appendChild(svg("circle", { cx: 6, cy: 6, r: 4, fill: "none", stroke: c, "stroke-width": 2, "stroke-dasharray": "2 2" }));
    else if (shape === "square") s.appendChild(svg("rect", { x: 2, y: 2, width: 8, height: 8, fill: "none", stroke: c, "stroke-width": 2 }));
    else if (shape === "diamond") s.appendChild(svg("path", { d: "M6 1l5 5-5 5-5-5z", fill: c }));
    else if (shape === "diamond-o") s.appendChild(svg("path", { d: "M6 1.5l4.5 4.5L6 10.5 1.5 6z", fill: "none", stroke: c, "stroke-width": 1.5 }));
    return s;
  }
  const STATUS_ICON = { outside: "down", no_data: "dash", no_baseline: "square", within: "dot" };
  const LEVEL_ICON = { urgent: "dot", attention: "diamond", watch: "ring" };
  function statusChip(s) { return el("span", { class: "chip s-" + s }, icon(STATUS_ICON[s] || "dot"), STATUS[s] || words(s)); }
  function levelChip(l) { return l ? el("span", { class: "chip l-" + l }, icon(LEVEL_ICON[l] || "ring"), LEVEL[l] || words(l)) : null; }

  // ---------------------------------------------------------------- state and server
  const S = {
    token: null, me: null, list: null, detail: null, trace: null,
    route: { view: "patients", pid: null, tab: "overview" },
    metric: "movement", open: {}, changedOnly: true, page: 0, demoMsg: "", busy: false, timer: null,
  };
  try { S.token = sessionStorage.getItem("clinic_session") || null; } catch (e) { S.token = null; }

  async function api(method, path, body) {
    const headers = {};
    if (S.token) headers.Authorization = "Bearer " + S.token;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const res = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), cache: "no-store" });
    let data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (res.status === 401 && path !== "/v1/clinic/login") { signOut("Your session ended. Sign in again."); throw new Error("signed out"); }
    if (!res.ok) throw new Error((data && data.error && data.error.message) || "Request failed (" + res.status + ")");
    return data;
  }
  function flash(msg) { const f = $("flash"); f.textContent = msg || ""; f.hidden = !msg; }

  // ---------------------------------------------------------------- routing
  const TABS = [["overview", "Overview"], ["timeline", "Timeline"], ["activity", "Activity"], ["talk", "Conversation"], ["research", "Research"], ["mind", "Learned"], ["log", "Log"]];
  function parseHash() {
    const parts = (location.hash || "").replace(/^#\/?/, "").split("/").filter(Boolean);
    if (parts[0] === "demo") return { view: "demo", pid: null, tab: "overview" };
    if (parts[0] === "blueprint") return { view: "blueprint", pid: null, tab: "overview" };
    if ((parts[0] === "p" || parts[0] === "patient") && parts[1]) {
      const tab = TABS.some((t) => t[0] === parts[2]) ? parts[2] : "overview";
      return { view: "patient", pid: decodeURIComponent(parts[1]), tab };
    }
    return { view: "patients", pid: null, tab: "overview" };
  }
  function go(hash) { if (location.hash === hash) onRoute(); else location.hash = hash; }

  async function onRoute() {
    const prev = S.route;
    S.route = parseHash();
    if (!S.token) return showLogin();
    const samePatient = prev.view === "patient" && S.route.view === "patient" && prev.pid === S.route.pid;
    if (S.route.view === "patient" && !samePatient) { S.detail = null; S.trace = null; S.assoc = null; S.exch = null; S.page = 0; }
    render();
    await load(false);
  }

  async function load(force) {
    if (!S.token || S.busy) return;
    S.busy = true;
    try {
      if (!S.me) S.me = await api("GET", "/v1/clinic/me");
      const r = S.route;
      if (r.view === "patients" || r.view === "demo") {
        if (force || !S.list) S.list = await api("GET", "/v1/clinic/patients");
      } else if (r.view === "patient") {
        const base = "/v1/clinic/patients/" + encodeURIComponent(r.pid);
        if (force || !S.detail) S.detail = await api("GET", base);
        if (r.tab === "timeline" && (force || !S.trace)) {
          try { S.trace = await api("GET", base + "/trace?limit=100"); } catch (e) { S.trace = await api("GET", base + "/trace"); }
        }
        if ((r.tab === "timeline" || r.tab === "mind") && (force || !S.exch)) {
          try { S.exch = (await api("GET", base + "/exchanges?limit=200")).exchanges || []; } catch (e) { S.exch = []; }
        }
        if (r.tab === "research" && (force || !S.assoc)) S.assoc = await api("GET", base + "/associations");
      }
      flash("");
    } catch (e) {
      if (e.message !== "signed out") flash(e.message);
    } finally {
      S.busy = false;
    }
    render();
  }
  async function refresh() { const y = window.scrollY; await load(true); window.scrollTo(0, y); }

  // ---------------------------------------------------------------- sign in and out
  function showLogin(msg) {
    $("view").hidden = true; $("nav").hidden = true; $("who").hidden = true;
    $("view-login").hidden = false;
    const e = $("login-error"); e.textContent = msg || ""; e.hidden = !msg;
  }
  function signOut(msg) {
    clear($("subnav"));
    S.token = null; S.me = null; S.list = null; S.detail = null; S.trace = null;
    try { sessionStorage.removeItem("clinic_session"); } catch (e) { /* storage may be blocked */ }
    showLogin(msg);
  }
  $("login-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    try {
      const out = await api("POST", "/v1/clinic/login", { username: $("login-user").value.trim(), password: $("login-pass").value });
      S.token = out.session_token;
      try { sessionStorage.setItem("clinic_session", S.token); } catch (e) { /* storage may be blocked */ }
      $("login-pass").value = "";
      $("view-login").hidden = true;
      onRoute();
    } catch (e) { showLogin(e.message); }
  });
  $("logout").addEventListener("click", () => signOut(""));

  // ---------------------------------------------------------------- render
  function render() {
    if (!S.token) return;
    $("view-login").hidden = true;
    const view = $("view");
    view.hidden = false;
    $("nav").hidden = false; $("who").hidden = false;
    if (S.me) {
      $("product-name").textContent = S.me.product_name || "Clinician page";
      document.title = (S.me.product_name || "Clinician page") + " · clinic";
      $("clinic-name").textContent = S.me.clinic_name || "";
      $("nav-demo").hidden = !(S.me.demo && S.me.demo.enabled);
      try { sessionStorage.setItem("clinic_demo", S.me.demo && S.me.demo.enabled ? "1" : "0"); } catch (e) { /* storage may be blocked */ }
    } else {
      let was = null; try { was = sessionStorage.getItem("clinic_demo"); } catch (e) { was = null; }
      $("nav-demo").hidden = was !== "1";
    }
    const r = S.route;
    $("nav-patients").toggleAttribute("aria-current", false);
    $("nav-demo").toggleAttribute("aria-current", false);
    $("nav-blueprint").toggleAttribute("aria-current", false);
    (r.view === "demo" ? $("nav-demo") : r.view === "blueprint" ? $("nav-blueprint") : $("nav-patients")).setAttribute("aria-current", "page");
    const focusKey = document.activeElement && document.activeElement.getAttribute ? document.activeElement.getAttribute("data-key") : null;
    clear(view);
    if (r.view !== "patient" || !S.detail) clear($("subnav"));
    if (r.view === "patients") view.appendChild(viewPatients());
    else if (r.view === "demo") view.appendChild(viewDemo());
    else if (r.view === "blueprint") view.appendChild(viewBlueprint());
    else view.appendChild(viewPatient());
    if (focusKey) { const again = view.querySelector('[data-key="' + focusKey + '"]'); if (again) again.focus({ preventScroll: true }); }
  }
  function refreshBtn() { return el("button", { type: "button", class: "btn", "data-key": "refresh", on: { click: refresh } }, "Refresh"); }
  function table(heads, rows, cls) {
    const t = el("table", { class: cls || null });
    t.appendChild(el("thead", null, el("tr", null, heads.map((h) => el("th", { class: h.r ? "r" : null, scope: "col" }, h.t || h)))));
    t.appendChild(el("tbody", null, rows));
    return el("div", { class: "scroll" }, t);
  }
  function panel(title, count, ...body) {
    return el("section", { class: "panel" }, el("h2", null, title, count !== null && count !== undefined ? el("span", { class: "count" }, count) : null), body);
  }
  const empty = (t) => el("p", { class: "empty" }, t);

  // ---------------------------------------------------------------- patients
  function reasonShort(p) {
    if (p.status === "within") return "–";
    if (p.reason_short) return p.reason_short;
    const items = (p.attention || []).slice().sort((a, b) => (LEVEL_ORDER[a.level] ?? 9) - (LEVEL_ORDER[b.level] ?? 9));
    if (!items.length) return p.status === "no_baseline" ? "Not enough history" : "–";
    return kind(items[0].kind) + (items.length > 1 ? " +" + (items.length - 1) : "");
  }
  function oldestSince(p) {
    if (p.since) return p.since;
    const s = (p.attention || []).map((a) => a.since).filter(Boolean).sort();
    return s.length ? s[0] : null;
  }
  function spark(values) {
    const W = 120, H = 28, n = values.length;
    const s = svg("svg", { class: "spark chart", viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "Movement against own normal, last " + n + " days" });
    const y = (z) => H / 2 - Math.max(-4, Math.min(4, z)) * (H / 2 - 2) / 4;
    s.appendChild(svg("rect", { class: "normal", x: 0, y: y(1.5), width: W, height: y(-1.5) - y(1.5) }));
    let d = "", pen = false;
    values.forEach((z, i) => {
      if (z === null || z === undefined) { pen = false; return; }
      d += (pen ? "L" : "M") + (i * (W - 4) / Math.max(1, n - 1) + 2).toFixed(1) + " " + y(z).toFixed(1);
      pen = true;
    });
    if (d) s.appendChild(svg("path", { class: "line", d }));
    return s;
  }
  function viewPatients() {
    const wrap = el("div");
    const list = (S.list && S.list.patients) || [];
    const today = todayStr();
    const counts = {};
    list.forEach((p) => { counts[p.status] = (counts[p.status] || 0) + 1; });
    wrap.appendChild(el("div", { class: "head" },
      el("h1", null, "Patients"),
      el("div", { class: "counts" }, ["outside", "no_data", "no_baseline", "within"].filter((s) => counts[s]).map((s) =>
        el("span", { class: "chip s-" + s }, icon(STATUS_ICON[s]), counts[s] + " " + STATUS[s].toLowerCase()))),
      el("div", { class: "push" }, refreshBtn())));
    if (!S.list) { wrap.appendChild(empty("Loading…")); return wrap; }
    if (!list.length) { wrap.appendChild(empty("No patients yet.")); return wrap; }
    const hasSpark = list.some((p) => Array.isArray(p.spark));
    const heads = ["Status", "Patient", "Why", "Held", hasSpark ? "28 days" : null, "Last data"].filter(Boolean);
    const rowOf = (p) => {
      const href = "#/p/" + encodeURIComponent(p.patient_id);
      const since = oldestSince(p);
      return el("tr", { class: "is-" + p.status, on: { click: () => go(href) } },
        el("td", null, statusChip(p.status)),
        el("td", null, el("a", { href }, p.display_name || p.label),
          el("span", { class: "sub" }, [p.display_name ? p.label : null, p.example ? "example data" : null].filter(Boolean).join(" · "))),
        el("td", null, reasonShort(p), " ", levelChip(p.level)),
        el("td", { class: "num" }, since ? held(since, today) : "–"),
        hasSpark ? el("td", null, Array.isArray(p.spark) ? spark(p.spark) : "–") : null,
        el("td", { class: "num" }, ago(p.last_data_day, today)));
    };
    // Search and paging redraw only the table, so the search box keeps its focus.
    const hay = (p) => [p.display_name, p.label, STATUS[p.status], p.reason_short].filter(Boolean).join(" ").toLowerCase();
    const body = el("div"), info = el("span", { class: "muted small num" });
    const prev = el("button", { type: "button", class: "btn btn-small", "data-key": "pl-prev" }, "← Previous");
    const next = el("button", { type: "button", class: "btn btn-small", "data-key": "pl-next" }, "Next →");
    const draw = () => {
      const terms = (S.q || "").toLowerCase().split(/\s+/).filter(Boolean);
      const found = list.filter((p) => { const h = hay(p); return terms.every((t) => h.indexOf(t) >= 0); });
      const pages = Math.max(1, Math.ceil(found.length / PATIENTS_PAGE));
      S.ppage = Math.min(Math.max(S.ppage || 0, 0), pages - 1);
      const from = S.ppage * PATIENTS_PAGE, shown = found.slice(from, from + PATIENTS_PAGE);
      info.textContent = found.length ? (from + 1) + "–" + (from + shown.length) + " of " + found.length : "0 of " + list.length;
      prev.disabled = S.ppage === 0; next.disabled = S.ppage >= pages - 1;
      body.replaceChildren(found.length ? el("section", { class: "panel" }, table(heads, shown.map(rowOf), "pick"))
        : empty("No patient matches “" + S.q + "”."));
    };
    prev.addEventListener("click", () => { S.ppage -= 1; draw(); });
    next.addEventListener("click", () => { S.ppage += 1; draw(); });
    const box = el("input", { type: "search", class: "search", placeholder: "Search by name, code or status", "aria-label": "Search patients", "data-key": "pl-search" });
    box.value = S.q || "";
    box.addEventListener("input", () => { S.q = box.value; S.ppage = 0; draw(); });
    wrap.appendChild(el("div", { class: "bar" }, box, el("div", { class: "push pager" }, prev, info, next)));
    wrap.appendChild(body);
    draw();
    return wrap;
  }

  // ---------------------------------------------------------------- patient
  function viewPatient() {
    const wrap = el("div");
    const d = S.detail;
    if (!d) { wrap.appendChild(empty("Loading…")); return wrap; }
    const today = (d.progress && d.progress.today) || todayStr();
    wrap.appendChild(el("div", { class: "head" },
      el("h1", null, d.display_name || d.label), d.display_name ? el("span", { class: "muted" }, d.label) : null, statusChip(d.status), levelChip(d.level),
      d.example ? el("span", { class: "chip tag" }, "example data") : null,
      el("div", { class: "push" }, el("span", { class: "muted small" }, "Last data " + ago(d.last_data_day, today)), refreshBtn())));
    const tabs = el("div", { class: "tabs", role: "tablist", "aria-label": "Patient sections" });
    TABS.forEach(([key, label], i) => {
      const sel = S.route.tab === key;
      tabs.appendChild(el("button", {
        type: "button", role: "tab", id: "tab-" + key, "aria-selected": sel ? "true" : "false", "aria-controls": "tabpanel",
        tabindex: sel ? "0" : "-1", "data-key": "tab-" + key,
        on: {
          click: () => go("#/p/" + encodeURIComponent(S.route.pid) + "/" + key),
          keydown: (ev) => {
            const step = ev.key === "ArrowRight" ? 1 : ev.key === "ArrowLeft" ? -1 : 0;
            if (!step) return;
            ev.preventDefault();
            const next = TABS[(i + step + TABS.length) % TABS.length][0];
            go("#/p/" + encodeURIComponent(S.route.pid) + "/" + next);
            setTimeout(() => { const b = $("tab-" + next); if (b) b.focus(); }, 0);
          },
        },
      }, label));
    });
    $("subnav").replaceChildren(tabs);  // the patient's sections live in the top bar
    const body = { overview: tabOverview, timeline: tabTimeline, activity: tabActivity, talk: tabTalk, research: tabResearch, mind: tabMind, log: tabLog }[S.route.tab](d, today);
    wrap.appendChild(el("div", { id: "tabpanel", role: "tabpanel", "aria-labelledby": "tab-" + S.route.tab }, body));
    return wrap;
  }

  // ---- overview
  function zWord(z) {
    if (z === null || z === undefined) return "no comparison yet";
    if (z <= -3) return "far below usual";
    if (z <= -1.5) return "below usual";
    if (z >= 3) return "far above usual";
    if (z >= 1.5) return "above usual";
    return "usual";
  }
  function seriesZ(day, metric) {
    if (metric === "movement") return day.movement_z === undefined ? null : day.movement_z;
    const z = day.z || {};
    return z[metric] === undefined ? null : z[metric];
  }
  // Early days have no score from the server, because the person's own normal was still being
  // learned. So the picture is not half empty, place those days by the same rule (distance from the
  // person's usual value, in units of their usual spread) and draw them hollow.
  function spreadOf(series, key, usual) {
    const vals = series.map((s) => (s.values || {})[key]).filter((v) => typeof v === "number");
    if (vals.length < 5 || typeof usual !== "number") return null;
    const dev = vals.map((v) => Math.abs(v - usual)).sort((a, b) => a - b);
    const mad = dev[Math.floor(dev.length / 2)] * 1.4826;
    return mad > 0 ? mad : null;
  }
  function estimateZ(d, day, metric) {
    const pr = d.progress || {};
    const usual = pr.usual || {};
    const one = (key) => {
      const v = (day.values || {})[key];
      const sp = spreadOf(pr.series || [], key, usual[key]);
      return typeof v === "number" && sp ? (v - usual[key]) / sp : null;
    };
    if (metric !== "movement") return one(metric);
    const parts = [one("steps"), one("walking_speed_m_s")].filter((z) => z !== null);
    return parts.length ? parts.reduce((a, b) => a + b, 0) / parts.length : null;
  }
  function readoutFor(day, metric) {
    const p = el("p", { class: "readout", id: "readout" });
    if (!day) return p;
    const v = day.values || {};
    const parts = [];
    if (v.steps !== undefined && v.steps !== null) parts.push(num(v.steps) + " steps");
    if (v.walking_speed_m_s !== undefined && v.walking_speed_m_s !== null) parts.push(v.walking_speed_m_s.toFixed(2) + " m/s");
    if (metric === "hrv_ms" && v.hrv_ms != null) parts.push(num(v.hrv_ms) + " ms");
    if (metric === "sleep_h" && v.sleep_h != null) parts.push(v.sleep_h.toFixed(1) + " h sleep");
    const z = seriesZ(day, metric);
    add(p, [el("b", null, dayLong(day.date)), " · ", parts.length ? parts.join(" · ") : "no data", parts.length ? " · " + (z !== null ? zWord(z) + " (" + signed(z) + ")" : "own normal still being learned") : ""]);
    return p;
  }
  function chart(d, metric, today) {
    const series = (d.progress && d.progress.series) || [];
    const band = (d.progress && d.progress.band) || { low_z: -1.5, high_z: 1.5 };
    const episodes = (d.progress && d.progress.episodes) || [];
    const offers = d.suggestions || [];
    const n = series.length;
    const L = 104, R = 10, T = 10, PH = 190, AX = 22, LANE = 18;
    const lanes = episodes.length + 1;
    const W = 760, H = T + PH + AX + lanes * LANE + 6;
    const x = (i) => L + (n <= 1 ? 0 : i * (W - L - R) / (n - 1));
    const step = n <= 1 ? W - L - R : (W - L - R) / (n - 1);
    const y = (z) => T + PH / 2 - Math.max(-4, Math.min(4, z)) * (PH / 2 - 6) / 4;
    const index = {}; series.forEach((s, i) => { index[s.date] = i; });
    const s = svg("svg", { class: "chart", viewBox: "0 0 " + W + " " + H, role: "img",
      "aria-label": "Each day for the last " + n + " days against this person's own normal, with attention periods and offers below." });
    s.appendChild(svg("rect", { class: "normal", x: L, y: y(band.high_z), width: W - L - R, height: y(band.low_z) - y(band.high_z) }));
    s.appendChild(svg("line", { class: "zero", x1: L, x2: W - R, y1: y(0), y2: y(0) }));
    [["above", band.high_z + 1.2], ["usual", 0], ["below", band.low_z - 1.2]].forEach(([t, z]) =>
      s.appendChild(svg("text", { x: L - 8, y: y(z) + 4, "text-anchor": "end" }, t)));
    s.appendChild(svg("line", { class: "axis", x1: L, x2: W - R, y1: T + PH, y2: T + PH }));
    series.forEach((day, i) => {
      const dt = parseDay(day.date);
      if (dt.getUTCDay() === 1 || i === n - 1) s.appendChild(svg("text", { x: x(i), y: T + PH + 15, "text-anchor": i === n - 1 ? "end" : "middle" }, i === n - 1 ? "today" : dayShort(day.date)));
    });
    const zs = series.map((day) => {
      const z = seriesZ(day, metric);
      if (z !== null) return { z, est: false };
      const e = estimateZ(d, day, metric);
      return e === null ? null : { z: e, est: true };
    });
    let dpath = "", pen = false;
    zs.forEach((p, i) => {
      if (!p) { pen = false; return; }
      dpath += (pen ? "L" : "M") + x(i).toFixed(1) + " " + y(p.z).toFixed(1);
      pen = true;
    });
    if (dpath) s.appendChild(svg("path", { class: "line", d: dpath }));
    series.forEach((day, i) => {
      const p = zs[i];
      const hasData = day.values && Object.keys(day.values).length > 0;
      if (!hasData) { s.appendChild(svg("line", { class: "miss", x1: x(i), x2: x(i), y1: T + PH - 5, y2: T + PH + 5 })); return; }
      if (!p) return;
      const z = p.z, cx = x(i), cy = y(z);
      if (p.est) s.appendChild(svg("circle", { class: "pt-est", cx, cy, r: 3 }));
      else if (z <= band.low_z) s.appendChild(svg("path", { class: "pt-low", d: "M" + (cx - 5) + " " + (cy - 4) + "h10l-5 9z" }));
      else if (z >= band.high_z) s.appendChild(svg("path", { class: "pt-high", d: "M" + (cx - 5) + " " + (cy + 4) + "h10l-5 -9z" }));
      else s.appendChild(svg("circle", { class: "pt", cx, cy, r: 3 }));
    });
    // lanes: one row per attention period, then one row for offers
    const laneY = (k) => T + PH + AX + k * LANE;
    episodes.forEach((ep, k) => {
      const a = index[ep.start] !== undefined ? index[ep.start] : 0;
      const b = ep.end && index[ep.end] !== undefined ? index[ep.end] : n - 1;
      s.appendChild(svg("text", { class: "lane", x: L - 8, y: laneY(k) + 12, "text-anchor": "end" }, kind(ep.kind)));
      s.appendChild(svg("rect", { class: "ep l-" + (ep.peak_level || "watch"), x: x(a) - 3, y: laneY(k) + 4, width: Math.max(6, x(b) - x(a) + 6), height: 9 }));
    });
    const oy = laneY(episodes.length);
    s.appendChild(svg("text", { class: "lane", x: L - 8, y: oy + 12, "text-anchor": "end" }, "Offers"));
    offers.forEach((o) => {
      const i = index[o.date];
      if (i === undefined) return;
      const cx = x(i), cy = oy + 9;
      s.appendChild(svg("path", { class: "offer" + (o.answer === "did_it" ? " done" : ""), d: "M" + cx + " " + (cy - 5) + "l5 5-5 5-5-5z" },
        svg("title", null, action(o.action) + " · " + (ANSWER[o.answer] || "no answer"))));
    });
    // one target per day: hover, tap or focus shows the day in the readout
    const cursor = svg("line", { class: "cursor", x1: -9, x2: -9, y1: T, y2: T + PH });
    s.appendChild(cursor);
    series.forEach((day, i) => {
      const show = () => {
        cursor.setAttribute("x1", x(i)); cursor.setAttribute("x2", x(i));
        const old = $("readout"); if (old) old.replaceWith(readoutFor(day, metric));
      };
      s.appendChild(svg("rect", { class: "hit", x: x(i) - step / 2, y: T, width: step, height: PH, tabindex: "0",
        "aria-label": dayLong(day.date) + ", " + zWord(seriesZ(day, metric)), on: { mouseenter: show, focus: show, click: show } }));
    });
    return s;
  }
  function factTile(v, k) { return el("div", { class: "fact" }, el("span", { class: "v" }, v), el("span", { class: "k" }, k)); }
  function detailText(detail) {
    const d = detail || {};
    const out = [];
    if (d.low_days !== undefined) out.push(d.low_days + " low days");
    if (d.mean_low_z !== undefined) out.push("mean " + signed(d.mean_low_z));
    if (d.days_silent !== undefined) out.push(d.days_silent + " days silent");
    if (d.rounds !== undefined) out.push(d.rounds + " sessions");
    if (d.z !== undefined) out.push(signed(d.z) + (d.metric ? " " + words(d.metric).toLowerCase() : ""));
    if (d.unanswered !== undefined) out.push(d.unanswered + " unanswered");
    if (!out.length) Object.keys(d).slice(0, 3).forEach((k) => { if (typeof d[k] !== "object") out.push(words(k).toLowerCase() + " " + d[k]); });
    return out.join(" · ");
  }
  function ackButton(item) {
    return el("button", { type: "button", class: "btn btn-small", "data-key": "ack-" + item.id,
      "aria-label": "Acknowledge " + kind(item.kind), on: { click: async () => {
        try { await api("POST", "/v1/clinic/attention/" + encodeURIComponent(item.id) + "/ack"); await refresh(); } catch (e) { flash(e.message); }
      } } }, "Acknowledge");
  }
  function tabOverview(d, today) {
    const series = (d.progress && d.progress.series) || [];
    const available = METRICS.filter((m) => m.key === "movement" || series.some((s) => s.z && s.z[m.key] !== undefined));
    if (!available.some((m) => m.key === S.metric)) S.metric = "movement";
    const seg = el("div", { class: "seg", role: "group", "aria-label": "Measure" }, available.map((m) =>
      el("button", { type: "button", class: "btn btn-small", "aria-pressed": S.metric === m.key ? "true" : "false", "data-key": "metric-" + m.key,
        on: { click: () => { S.metric = m.key; render(); } } }, m.label)));
    const last = series.length ? series[series.length - 1] : null;
    const usual = (d.progress && d.progress.usual) || {};
    const left = el("section", { class: "panel" },
      el("h2", null, "Last " + series.length + " days against own normal",
        usual.steps ? el("span", { class: "count" }, "usual " + num(usual.steps) + " steps") : null),
      seg, readoutFor(last, S.metric), chart(d, S.metric, today),
      el("ul", { class: "legend" },
        el("li", null, icon("dot"), "usual"), el("li", null, icon("down"), "below own normal"), el("li", null, icon("up"), "above"),
        el("li", null, icon("ring"), "early days, while own normal was learned"),
        el("li", null, icon("diamond"), "offer done"), el("li", null, icon("diamond-o"), "offer not done")));

    const items = (d.attention_items || []).filter((i) => i.state === "open" || !i.closed_at)
      .sort((a, b) => (LEVEL_ORDER[a.level] ?? 9) - (LEVEL_ORDER[b.level] ?? 9));
    const att = panel("Needs attention", items.length || "", items.length ? el("div", { class: "rows" }, items.map((i) =>
      el("div", { class: "row" },
        el("div", { class: "top" }, levelChip(i.level), el("span", { class: "t" }, kind(i.kind)), el("span", { class: "muted small num" }, held(i.since, today))),
        ackButton(i),
        detailText(i.detail) ? el("div", { class: "d" }, detailText(i.detail)) : null,
        i.kind === "asked_for_help" ? helpQuote(d) : null))) : empty("Nothing held."));

    const sug = (d.suggestions || []).slice().sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)))[0];
    const offer = panel("Last offer", null, sug ? el("div", { class: "row" },
      el("div", { class: "top" }, el("span", { class: "t" }, action(sug.action)), el("span", { class: "muted small num" }, dayShort(sug.date))),
      el("span", { class: "chip " + (sug.answer === "did_it" ? "good" : sug.answer ? "" : "bad") }, ANSWER[sug.answer] || "No answer"),
      el("div", { class: "d" }, "for " + kind(sug.attention_kind).toLowerCase() + (sug.wording && sug.wording !== "template" ? " · worded by model" : ""))) : empty("No offer yet."));

    const week = series.slice(-7);
    const withData = week.filter((s) => s.values && Object.keys(s.values).length).length;
    const zs = week.map((s) => s.movement_z).filter((z) => z !== null && z !== undefined);
    const meanZ = zs.length ? zs.reduce((a, b) => a + b, 0) / zs.length : null;
    const weekOffers = (d.suggestions || []).filter((s) => week.some((w) => w.date === s.date));
    const answered = weekOffers.filter((s) => s.answer).length;
    const facts = panel("Last 7 days", null, el("div", { class: "facts" },
      factTile(withData + "/7", "days with data"),
      factTile(weekOffers.length ? answered + "/" + weekOffers.length : "–", "offers answered"),
      factTile(meanZ === null ? "–" : signed(meanZ), zWord(meanZ))));
    return el("div", { class: "grid" }, left, el("div", { class: "stack" }, att, offer, facts));
  }

  // ---- timeline
  function chainSummary(c) {
    const chips = [];
    (c.entries || []).forEach((e) => {
      const d = e.detail || {};
      if (e.layer === "attention" && e.code === "opened") chips.push(el("span", { class: "chip l-" + (d.level || "watch") }, icon(LEVEL_ICON[d.level] || "ring"), kind(d.kind) + " opened"));
      else if (e.layer === "attention" && e.code === "raised") chips.push(el("span", { class: "chip l-" + (d.level || "attention") }, icon("up"), kind(d.kind) + " raised"));
      else if (e.layer === "attention" && (e.code === "closed" || e.code === "lowered")) chips.push(el("span", { class: "chip" }, kind(d.kind) + " " + e.code));
      else if (e.layer === "response" && e.code === "suggested") chips.push(el("span", { class: "chip good" }, icon("diamond"), "Offered " + action(d.action).toLowerCase()));
      else if ((e.layer === "level1" || e.layer === "level2") && /refus/.test(e.code)) chips.push(el("span", { class: "chip bad" }, "Model answer refused"));
      else if (e.layer === "notifier" && e.code === "sent") chips.push(el("span", { class: "chip l-urgent" }, icon("dot"), "Alert sent"));
      else if (e.layer === "notifier") chips.push(el("span", { class: "chip" }, "Alert " + words(e.code).toLowerCase()));
      else if (e.layer === "learning" && d.accepted && d.accepted.length) chips.push(el("span", { class: "chip" }, d.accepted.length + " lesson" + (d.accepted.length > 1 ? "s" : "")));
    });
    return chips;
  }
  function flat(obj, prefix, out, depth) {
    Object.keys(obj || {}).forEach((k) => {
      const v = obj[k];
      const name = k === "facts" || k === "ranking" ? prefix : (prefix ? prefix + " " : "") + words(k).toLowerCase();
      if (v === null || v === undefined || /(^|_)id$|_ids$|^chain|^attention_id$/.test(k)) return;
      if (Array.isArray(v)) { if (v.length && typeof v[0] !== "object") out.push([name, v.map((x) => ACTION[x] || KIND[x] || x).join(", ")]); else if (v.length) out.push([name, v.length]); }
      else if (typeof v === "object") { if (depth < 2) flat(v, name, out, depth + 1); }
      else if (typeof v === "boolean") out.push([name, v ? "yes" : "no"]);
      else out.push([name, typeof v === "number" && !Number.isInteger(v) ? v.toFixed(2) : ACTION[v] || KIND[v] || v]);
    });
    return out;
  }
  function entryRow(e) {
    const pairs = flat(e.detail, "", [], 0).slice(0, 10);
    return el("tr", null,
      el("td", { class: "layer" }, LAYER[e.layer] || words(e.layer)),
      el("td", null, words(e.code)),
      el("td", null, pairs.length ? el("div", { class: "kv" }, pairs.map(([k, v]) => el("span", null, el("b", null, k), String(v)))) : null));
  }
  const TL_COLS = [["watchers", "Watchers"], ["attention", "Attention"], ["response", "Response"], ["level1", "Model 1"], ["level2", "Model 2"], ["notifier", "Alert"], ["learning", "Learning"]];
  const PAGE = 15;
  const PATIENTS_PAGE = 10;
  // Why the system made no offer at a check.
  const NO_OFFER = { quiet_hours: "patient's quiet hours", one_open_already: "an offer is still open", daily_cap: "enough offers today",
    cooldown: "too soon after the last offer", already_answered_today: "already answered today", no_held_item_to_answer: "nothing to answer",
    held_items_need_a_clinician: "left for the clinician" };
  function layerCell(c, layer) {
    const es = (c.entries || []).filter((e) => e.layer === layer);
    if (!es.length) return el("span", { class: "muted" }, "–");
    const out = [];
    es.forEach((e) => {
      const d = e.detail || {};
      if (layer === "watchers") out.push(e.code === "fired" ? el("span", { class: "chip l-attention" }, "fired") : el("span", { class: "muted" }, words(e.code).toLowerCase()));
      else if (layer === "attention") out.push(el("span", { class: "chip l-" + (d.level || "watch") }, icon(e.code === "raised" ? "up" : LEVEL_ICON[d.level] || "ring"), kind(d.kind) + " " + e.code));
      else if (layer === "response") {
        if (e.code === "suggested") out.push(el("span", { class: "chip good" }, icon("diamond"), action(d.action)));
        else if (e.code === "blocked") out.push(el("span", null, "no offer: " + (NO_OFFER[d.because] || words(d.because).toLowerCase())));
        else if (e.code === "none") out.push(el("span", { class: "muted" }, NO_OFFER[d.because] || words(d.because || d.reason || e.code).toLowerCase()));
        else out.push(el("span", { class: "muted" }, words(d.reason || e.code).toLowerCase()));
      }
      else if (layer === "level1" || layer === "level2") {
        const task = d.task ? words(d.task).toLowerCase() + ": " : "";
        const why = Array.isArray(d.reasons) && d.reasons.length ? d.reasons : d.reason ? [d.reason] : [];
        const whyText = why.length ? " (" + Array.from(new Set(why)).map((w) => words(w).toLowerCase()).join(", ") + ")" : "";
        if (e.code === "partly_refused") out.push(el("span", null, task + "kept part, dropped " + why.length + whyText));
        else if (/refus/.test(e.code)) out.push(el("span", { class: "chip bad" }, task + "refused" + whyText));
        else out.push(el("span", { class: e.code === "off" ? "muted" : null }, task + words(e.code).toLowerCase()));
      }
      else if (layer === "notifier") out.push(e.code === "sent" ? el("span", { class: "chip l-urgent" }, icon("dot"), "sent") : el("span", null, words(e.code).toLowerCase()));
      else if (layer === "learning") out.push(el("span", null, d.accepted && d.accepted.length ? d.accepted.length + " lesson" + (d.accepted.length > 1 ? "s" : "") : words(e.code).toLowerCase()));
    });
    return el("div", { class: "cellstack" }, out);
  }
  // The raw exchange with a model: what was sent and what came back, word for word.
  const TASK = { note: "Label the patient's words", wording: "Choose the wording of an offer", review: "Learning: propose lessons", second_opinion: "Second opinion on proposed lessons",
    session_reading: "Read one session", association: "Appraise the research table", reading: "Read one round" };
  function pretty(text) {
    if (text === null || text === undefined) return "(no reply)";
    try { return JSON.stringify(JSON.parse(text), null, 2); } catch (e) { return String(text); }
  }
  function exchangeBox(x) {
    const key = "ex-" + x.id, open = !!S.open[key];
    const head = el("button", { type: "button", class: "linklike", "aria-expanded": open ? "true" : "false", "data-key": key,
      on: { click: (ev) => { ev.stopPropagation(); S.open[key] = !open; render(); } } },
      (open ? "▾ " : "▸ ") + "Model " + x.level + " · " + (TASK[x.task] || words(x.task)) + " · " + x.model + " · " + (x.ms / 1000).toFixed(1) + " s" + (x.reply === null ? " · no reply" : ""));
    const box = el("div", { class: "exch", on: { click: (ev) => ev.stopPropagation() } }, head);
    if (open) {
      (x.messages || []).forEach((m) => box.appendChild(el("div", null,
        el("div", { class: "exch-h" }, m.role === "system" ? "Sent: instructions" : "Sent: data"), el("pre", { class: "raw" }, m.role === "user" ? pretty(m.content) : m.content))));
      box.appendChild(el("div", null, el("div", { class: "exch-h" }, "Model answered"), el("pre", { class: "raw" }, pretty(x.reply))));
    }
    return box;
  }
  function tabTimeline() {
    const wrap = el("div");
    const t = S.trace;
    if (!t) { wrap.appendChild(empty("Loading…")); return wrap; }
    const chains = (t.chains || []).filter((c) => !S.changedOnly || c.changed);
    const pages = Math.max(1, Math.ceil(chains.length / PAGE));
    if (S.page >= pages) S.page = pages - 1;
    const from = S.page * PAGE, shown = chains.slice(from, from + PAGE);
    const pager = (key) => el("div", { class: "bar pager" },
      el("button", { type: "button", class: "btn btn-small", disabled: S.page === 0, "data-key": key + "-prev", on: { click: () => { S.page -= 1; render(); } } }, "← Newer"),
      el("span", { class: "muted small num" }, chains.length ? (from + 1) + "–" + (from + shown.length) + " of " + chains.length : "0"),
      el("button", { type: "button", class: "btn btn-small", disabled: S.page >= pages - 1, "data-key": key + "-next", on: { click: () => { S.page += 1; render(); } } }, "Older →"));
    wrap.appendChild(el("div", { class: "bar" },
      el("button", { type: "button", class: "btn btn-small", "aria-pressed": S.changedOnly ? "true" : "false", "data-key": "changed-only",
        on: { click: () => { S.changedOnly = !S.changedOnly; S.page = 0; render(); } } }, "Changes only"),
      el("span", { class: "muted small" }, "One row per trigger, one column per step of the system. Select a row for the numbers behind it."),
      el("div", { class: "push" }, pager("top"))));
    if (!chains.length) { wrap.appendChild(empty(S.changedOnly ? "No changes recorded. Turn off “Changes only” to see every check." : "Nothing recorded yet.")); return wrap; }
    const rows = [];
    shown.forEach((c) => {
      const key = "chain-" + c.chain_id;
      const open = !!S.open[key];
      rows.push(el("tr", { class: (c.changed ? "changed" : "") + (open ? " open" : ""), on: { click: () => { S.open[key] = !open; render(); } } },
        el("td", { class: "num nowrap" }, el("button", { type: "button", class: "linklike", "aria-expanded": open ? "true" : "false", "data-key": key }, stamp(c.at))),
        el("td", null, c.headline || TRIGGER[c.trigger] || words(c.trigger)),
        TL_COLS.map(([layer]) => el("td", null, layerCell(c, layer)))));
      if (open) rows.push(el("tr", { class: "detail" }, el("td", { colspan: 2 + TL_COLS.length },
        el("div", { class: "tl-body" }, el("table", null, el("tbody", null, (c.entries || []).map(entryRow))),
          (S.exch || []).filter((x) => x.chain_id === c.chain_id).slice().reverse().map(exchangeBox)))));
    });
    wrap.appendChild(el("section", { class: "panel" }, table(["When", "Trigger"].concat(TL_COLS.map((x) => x[1])), rows, "pick tl-table")));
    if (pages > 1) wrap.appendChild(pager("bottom"));
    return wrap;
  }

  // ---- activity
  function outcomeWord(v) { return v === null || v === undefined ? "–" : v > 0.3 ? "better after" : v < -0.3 ? "worse after" : "no change"; }
  function tabActivity(d) {
    const wrap = el("div", { class: "stack" });
    const acts = (d.progress && d.progress.actions) || {};
    const used = Object.keys(acts).filter((a) => acts[a].offered > 0).sort((a, b) => acts[b].offered - acts[a].offered);
    wrap.appendChild(panel("What was offered", null, used.length ? table(
      ["Offer", { t: "Offered", r: 1 }, { t: "Done", r: 1 }, { t: "Not today", r: 1 }, { t: "No answer", r: 1 }, "Days after"],
      used.map((a) => el("tr", null, el("td", null, action(a)), el("td", { class: "r num" }, acts[a].offered), el("td", { class: "r num" }, acts[a].done),
        el("td", { class: "r num" }, acts[a].not_today), el("td", { class: "r num" }, (acts[a].no_answer || 0) + (acts[a].open || 0)),
        el("td", null, outcomeWord(acts[a].mean_outcome_change))))) : empty("Nothing offered yet.")));
    const A = d.activities || {};
    const zCell = (z) => el("td", { class: "num" }, z === null || z === undefined ? "–" : zWord(z) + " (" + signed(z) + ")");
    const faceCell = (f) => {
      if (!f) return el("td", { class: "muted" }, "no camera");
      if (f.quality && f.quality !== "good") return el("td", { class: "muted" }, "poor tracking");
      const z = f.z || {};
      const off = [["facial_activity", "movement"], ["smile_intensity", "smile"], ["blink_rate_per_min", "blinking"], ["look_down_share", "looking down"]]
        .filter(([k]) => typeof z[k] === "number" && Math.abs(z[k]) >= 1.5).map(([k, w]) => w + " " + signed(z[k]));
      return el("td", null, off.length ? off.join(" · ") : "as usual");
    };
    const readCell = (r) => {
      if (!r || r.status === "off" || r.status === "not_applicable") return el("td", { class: "muted" }, "–");
      const rd = r.reading;
      if (!rd) return el("td", null, words(r.status));
      const said = [rd.reactions, rd.expression, rd.eyes].filter((v) => v && !/^(steady|as_usual|unclear)$/.test(v)).map((v) => words(v).toLowerCase());
      const dropped = (r.dropped || []).length;
      return el("td", null, said.length ? said.join(" · ") : "as usual",
        el("span", { class: "sub" }, (r.read_by === "level1" ? "local model" : "outside model") + ", checked by code" + (dropped ? " · " + dropped + " claim" + (dropped > 1 ? "s" : "") + " dropped" : "")));
    };
    const yes = (b) => (b ? "yes" : "no");
    const recent = (g) => ((g && g.sessions) || []).slice(-14).reverse();
    const c7 = (A.counts && A.counts.last_7_days) || {};
    if (A.focus || A.breathing || A.checkin) {
      const tile = (key, label) => factTile(c7[key] ? c7[key].finished + "/" + c7[key].played : "–", label + " finished, 7 d");
      wrap.appendChild(panel("Lanvi", d.lanvi ? words(d.lanvi.stage) + " · " + num(d.lanvi.xp) + " XP" : null,
        el("div", { class: "facts" }, tile("focus", "focus games"), tile("breathing", "breathing"), tile("checkin", "check-ins"))));
    }
    if (recent(A.focus).length) wrap.appendChild(panel("Focus game", A.focus.sessions.length, table(["Date", "Finished", { t: "Reaction", r: 1 }, "Against own normal", { t: "Errors", r: 1 }, "Face", "Model reading"],
      recent(A.focus).map((x) => el("tr", null, el("td", { class: "num" }, dayShort(x.date)), el("td", null, yes(x.completed)),
        el("td", { class: "r num" }, x.values && x.values.median_reaction_ms != null ? num(x.values.median_reaction_ms) + " ms" : "–"),
        el("td", { class: "num" }, !x.z || x.z.median_reaction_ms == null ? "–" : (x.z.median_reaction_ms >= 1.5 ? "slower than usual" : x.z.median_reaction_ms <= -1.5 ? "faster than usual" : "usual") + " (" + signed(x.z.median_reaction_ms) + ")"),
        el("td", { class: "r num" }, x.values && x.values.error_rate != null ? Math.round(x.values.error_rate * 100) + " %" : "–"),
        faceCell(x.face), readCell(x.reading))))));
    if (recent(A.breathing).length) wrap.appendChild(panel("Breathing", A.breathing.sessions.length, table(["Date", "Finished", { t: "Time", r: 1 }, "Face", "Model reading"],
      recent(A.breathing).map((x) => el("tr", null, el("td", { class: "num" }, dayShort(x.date)), el("td", null, yes(x.completed)),
        el("td", { class: "r num" }, x.values && x.values.time_played_s != null ? num(x.values.time_played_s) + " s" : "–"), faceCell(x.face), readCell(x.reading))))));
    if (recent(A.checkin).length) wrap.appendChild(panel("Evening check-in", A.checkin.sessions.length, table(["Date", { t: "Good things", r: 1 }, "Plan for next day", "Plan done", "Asked for help"],
      recent(A.checkin).map((x) => el("tr", null, el("td", { class: "num" }, dayShort(x.date)),
        el("td", { class: "r num" }, x.values ? x.values.good_things : "–"),
        el("td", null, x.plan ? x.plan.label || (x.plan.catalog_id ? words(x.plan.catalog_id) : "own words") : "–"),
        el("td", null, x.plan_done === "yes" ? "yes" : x.plan_done === "no" ? "no" : "–"),
        el("td", null, x.asked_for_help ? el("span", { class: "chip l-urgent" }, icon("dot"), "Yes") : "No"))))));
    const offers = (d.suggestions || []).slice().sort((a, b) => String(b.created_at).localeCompare(String(a.created_at))).slice(0, 14);
    wrap.appendChild(panel("Offers and answers", offers.length || "", offers.length ? table(["Date", "Offer", "Because of", "Answer", "Felt"],
      offers.map((o) => el("tr", null, el("td", { class: "num" }, dayShort(o.date)), el("td", null, action(o.action)), el("td", null, kind(o.attention_kind)),
        el("td", null, el("span", { class: "chip " + (o.answer === "did_it" ? "good" : o.answer ? "" : "bad") }, ANSWER[o.answer] || "No answer")),
        el("td", null, o.felt ? words(o.felt) : "–")))) : empty("No offers yet.")));
    const rounds = (d.progress && d.progress.rounds && d.progress.rounds.energy_series) || [];
    if (rounds.length) {
      wrap.appendChild(el("details", { class: "more panel" }, el("summary", null, "Earlier sessions (" + rounds.length + ")"),
        table(["Date", "Mode", "Finished", "Energy"], rounds.slice(-14).reverse().map((r) => el("tr", null,
          el("td", { class: "num" }, dayShort(r.started_at)), el("td", null, words(r.mode)), el("td", null, r.completed ? "yes" : "no"), el("td", null, r.energy_bucket ? words(r.energy_bucket) : "–"))))));
    }
    return wrap;
  }

  // ---- learned
  function tabMind(d) {
    const wrap = el("div", { class: "stack" });
    const runs = (S.exch || []).filter((x) => x.task === "review" || x.task === "second_opinion");
    wrap.appendChild(panel("How it learns", runs.length || "",
      el("p", { class: "muted small" }, "After new answers, code gathers the evidence (what was offered, what the person did, how the next days went). Model 1 proposes lessons and questions from it. Model 2 may object. Code keeps only proposals that the evidence supports, and a lesson can only change the order of offers. Open a run to read exactly what each model was sent and what it answered."),
      runs.length ? el("div", null, runs.slice(0, 12).map((x) => el("div", null, el("span", { class: "muted small num" }, stamp(x.at) + " "), exchangeBox(x)))) : empty("No learning run recorded yet.")));
    const lessons = d.lessons || [];
    wrap.appendChild(panel("Lessons", lessons.length || "", lessons.length ? table(["Lesson", "When", { t: "Evidence", r: 1 }, "Found by", "State"],
      lessons.map((l) => el("tr", null,
        el("td", null, (l.effect === "prefer" ? "Prefers " : l.effect === "avoid" ? "Avoids " : words(l.effect) + " ") + action(l.action).toLowerCase(), el("span", { class: "sub" }, "Patient sees: " + l.text)),
        el("td", null, words(l.context)), el("td", { class: "r num" }, l.evidence_count),
        el("td", null, (l.provenance && l.provenance.model) === "code" || l.source === "code" ? "Code" : "Model, checked by code"),
        el("td", null, el("span", { class: "chip " + (l.status === "active" ? "good" : "bad") }, words(l.status)))))) : empty("Nothing learned yet.")));
    const qs = d.questions || [];
    wrap.appendChild(panel("Questions to the patient", qs.length || "", qs.length ? table(["Question", "About", "Answer"],
      qs.map((q) => el("tr", null, el("td", null, q.text), el("td", null, action(q.action)), el("td", null, q.answer ? words(q.answer) : words(q.status))))) : empty("No questions.")));
    const rules = d.rules || [];
    wrap.appendChild(panel("The patient's own rules", rules.length || "", rules.length ? table(["Rule", "Setting"],
      rules.map((r) => el("tr", null, el("td", null, words(r.type)), el("td", null, Object.keys(r.params || {}).map((k) => words(k).toLowerCase() + " " + r.params[k]).join(" · ") || "–")))) : empty("No rules set. Rules always win over lessons.")));
    return wrap;
  }

  // ---- log
  // What the patient wrote and what Lanvi answered, in time order, with what the system did.
  // The note that asked for help, shown where the clinician first looks.
  function helpQuote(d) {
    const n = (d.notes || []).filter((x) => (x.classification || {}).asks_for_help).sort((a, b) => String(b.at).localeCompare(String(a.at)))[0];
    if (!n) return null;
    return el("div", { class: "quote" },
      el("div", { class: "text" }, n.text ? "“" + n.text + "”" : el("span", { class: "muted" }, "The words are not shared by this patient.")),
      el("div", { class: "muted small" }, "Written " + stamp(n.at) + " · ",
        el("a", { href: "#/p/" + encodeURIComponent(d.patient_id) + "/talk" }, "Open the conversation")));
  }
  function tabTalk(d) {
    const wrap = el("div");
    const ev = [];
    (d.notes || []).forEach((n) => ev.push({ at: n.at, kind: "note", n }));
    (d.suggestions || []).forEach((s) => { if (s.created_at && s.attention_kind !== "example") ev.push({ at: s.created_at, kind: "offer", s }); });
    (d.notify_log || []).forEach((a) => ev.push({ at: a.at, kind: "alert", a }));
    ev.sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : 0));
    wrap.appendChild(el("p", { class: "muted small" }, d.share_notes
      ? "The patient agreed to share the words they write. Lanvi answers only with lines from a fixed set; a model labels the words and does not write to the patient."
      : "This patient has not shared the words they write, so only the labels are shown. Lanvi answers only with lines from a fixed set."));
    if (!ev.length) { wrap.appendChild(empty("Nothing written or offered yet.")); return wrap; }
    const chat = el("div", { class: "chat" });
    const who = d.display_name || d.label;
    let day = "";
    ev.forEach((e) => {
      const dd = String(e.at).slice(0, 10);
      if (dd !== day) { day = dd; chat.appendChild(el("div", { class: "chat-day" }, dd)); }
      if (e.kind === "note") {
        const c = e.n.classification || {};
        chat.appendChild(el("div", { class: "msg from-patient" + (c.asks_for_help ? " help" : "") },
          el("div", { class: "who" }, who + " · " + (e.n.source === "checkin" ? "evening check-in" : "note") + " · " + stamp(e.at)),
          el("div", { class: "text" }, e.n.text ? e.n.text : el("span", { class: "muted" }, "words not shared")),
          el("div", { class: "tags" },
            el("span", { class: "chip" }, "mood: " + words(c.mood).toLowerCase()),
            el("span", { class: "chip" }, "about: " + words(c.topic).toLowerCase()),
            c.asks_for_help ? el("span", { class: "chip l-urgent" }, "asks for help") : null)));
        if (e.n.reply) chat.appendChild(el("div", { class: "msg from-lanvi" },
          el("div", { class: "who" }, "Lanvi · fixed line"), el("div", { class: "text" }, e.n.reply)));
        if (c.crisis) chat.appendChild(el("div", { class: "chat-event urgent" }, "Help screen opened on the phone"));
      } else if (e.kind === "offer") {
        chat.appendChild(el("div", { class: "msg from-lanvi" },
          el("div", { class: "who" }, "Lanvi · offer · " + stamp(e.at)), el("div", { class: "text" }, e.s.text)));
        if (e.s.answer) chat.appendChild(el("div", { class: "msg from-patient" },
          el("div", { class: "who" }, who + " · answer"), el("div", { class: "text" }, ANSWER[e.s.answer] || words(e.s.answer))));
      } else {
        chat.appendChild(el("div", { class: "chat-event urgent" },
          e.a.outcome === "ok" ? "Needs-review message sent to the clinic · " + stamp(e.at) : "Needs-review message not sent (" + words(e.a.reason).toLowerCase() + ") · " + stamp(e.at)));
      }
    });
    wrap.appendChild(chat);
    return wrap;
  }
  // ---- blueprint: how the learning loop works
  function viewBlueprint() {
    const wrap = el("div", { class: "stack" });
    wrap.appendChild(el("div", { class: "head" }, el("h1", null, "How the system learns")));
    wrap.appendChild(el("p", { class: "lead" }, "The system learns which small things suit one person. A model proposes, code decides. Nothing a model writes reaches the patient, and a lesson can only change the order of offers that we wrote ourselves."));
    const W = 960, H = 318, BW = 262, BH = 88;
    const s = svg("svg", { viewBox: "0 0 " + W + " " + H, class: "bp", role: "img",
      "aria-label": "The learning loop: the phone sends answers, code gathers evidence, model 1 proposes lessons, code checks them, model 2 may object, accepted lessons go to memory and change the order of the next offers." });
    const box = (x, y, n, title, l1, l2, cls) => {
      s.appendChild(svg("rect", { x, y, width: BW, height: BH, rx: 10, class: "bp-box " + cls }));
      s.appendChild(svg("text", { x: x + 14, y: y + 26, class: "bp-t" }, n + "  " + title));
      s.appendChild(svg("text", { x: x + 14, y: y + 48, class: "bp-s" }, l1));
      s.appendChild(svg("text", { x: x + 14, y: y + 66, class: "bp-s" }, l2));
    };
    const arrow = (x1, y1, x2, y2, label, lx, ly, anchor) => {
      s.appendChild(svg("line", { x1, y1, x2, y2, class: "bp-line" }));
      const ang = Math.atan2(y2 - y1, x2 - x1), hx = (da, len) => (x2 - len * Math.cos(ang + da)).toFixed(1) + "," + (y2 - len * Math.sin(ang + da)).toFixed(1);
      s.appendChild(svg("polygon", { points: x2 + "," + y2 + " " + hx(0.4, 10) + " " + hx(-0.4, 10), class: "bp-head" }));
      if (label) s.appendChild(svg("text", { x: lx, y: ly, class: "bp-l", "text-anchor": anchor || "middle" }, label));
    };
    const X = [10, 349, 688], Y = [14, 216];
    box(X[0], Y[0], "1", "The person", "offers answered, sessions played,", "a few words written", "code");
    box(X[1], Y[0], "2", "Evidence · code", "what was offered, what was done,", "how the next days went", "code");
    box(X[2], Y[0], "3", "Model 1 proposes", "lessons and up to 3 questions,", "only from lists it is given", "model");
    box(X[2], Y[1], "4", "Check · code", "every proposal must point at evidence", "that supports it, or it is dropped", "code");
    box(X[1], Y[1], "5", "Model 2 may object", "weak evidence, contradicts recent days,", "too broad", "model");
    box(X[0], Y[1], "6", "Memory", "accepted lessons, open questions,", "the person's own rules", "code");
    arrow(X[0] + BW, Y[0] + BH / 2, X[1], Y[0] + BH / 2, "numbers", (X[0] + BW + X[1]) / 2, Y[0] + BH / 2 - 8);
    arrow(X[1] + BW, Y[0] + BH / 2, X[2], Y[0] + BH / 2, "anonymous", (X[1] + BW + X[2]) / 2, Y[0] + BH / 2 - 8);
    arrow(X[2] + BW / 2, Y[0] + BH, X[2] + BW / 2, Y[1], "raw reply", X[2] + BW / 2 + 10, (Y[0] + BH + Y[1]) / 2 + 4, "start");
    arrow(X[2], Y[1] + BH / 2, X[1] + BW, Y[1] + BH / 2, "kept", (X[1] + BW + X[2]) / 2, Y[1] + BH / 2 - 8);
    arrow(X[1], Y[1] + BH / 2, X[0] + BW, Y[1] + BH / 2, "not objected", (X[0] + BW + X[1]) / 2, Y[1] + BH / 2 - 8);
    arrow(X[0] + BW / 2, Y[1], X[0] + BW / 2, Y[0] + BH, "changes only the order of the next offers", X[0] + BW / 2 + 10, (Y[0] + BH + Y[1]) / 2 + 4, "start");
    wrap.appendChild(el("section", { class: "panel" }, el("figure", { class: "bp-fig" }, s,
      el("figcaption", { class: "muted small" }, "Amber boxes are models, the others are plain code. The loop runs after new answers arrive and once a day."))));
    const step = (n, t, body) => el("div", { class: "row" }, el("div", { class: "top" }, el("span", { class: "chip" }, n), el("span", { class: "t" }, t)), el("div", { class: "d" }, body));
    wrap.appendChild(panel("Step by step", null, el("div", { class: "rows" },
      step("1", "The person answers", "Each offer ends as did it, not today or no answer. Sessions and daily steps arrive from the phone. Typed words are turned into labels on this server and are never part of learning as text."),
      step("2", "Code gathers the evidence", "One row per offer: the action, the situation (weekday, time of day, what was held), the answer, and whether the following days were better or worse against the person's own normal. Each row gets a short reference that means nothing outside this one request."),
      step("3", "Model 1 proposes", "The local model receives those rows and lists of allowed actions, situations and reason codes. It returns lessons of the form “prefer or avoid this action in this situation, because of these rows”, and at most three questions it would like answered."),
      step("4", "Code checks every proposal", "A lesson is kept only if its rows exist, there are enough of them, and they really point the way the lesson claims. A question already asked is dropped. Anything outside the lists is dropped. Every drop is written to the refusal log with its reason."),
      step("5", "Model 2 gives a second opinion", "A second model sees the kept lessons with their evidence, with no identity, and can only object with one of three codes. An objection removes the lesson. It cannot add one."),
      step("6", "Memory and the next offer", "Accepted lessons go into the person's memory. When the next offer is due, code picks from our fixed list of actions; lessons move suited actions up and unsuited ones down. The person's own rules, such as quiet hours, always win."))));
    wrap.appendChild(el("div", { class: "grid" },
      panel("A lesson can", null, el("ul", { class: "plain" }, el("li", null, "move an action up or down in the order of offers"), el("li", null, "apply only in the situation it was learned in"), el("li", null, "be withdrawn when later evidence points the other way"))),
      panel("A lesson cannot", null, el("ul", { class: "plain" }, el("li", null, "add an action that is not on our list"), el("li", null, "write or change any text the person sees"), el("li", null, "open, raise or close attention, or send an alert"), el("li", null, "override the person's own rules")))));
    wrap.appendChild(panel("See it on real runs", null, el("p", { class: "small" }, "Open a patient, then Learned. “How it learns” lists each run with exactly what each model was sent and what it answered. The Timeline shows the same exchange inside the trigger that caused it, next to what code kept and dropped.")));
    return wrap;
  }

  // ---- research: how this person's measures moved with the reference
  const R_PATTERN = { consistent_with_worse_state: "Moves as expected when the state is worse", partly_consistent: "Partly as expected",
    no_clear_relation: "No clear relation", opposite_to_expectation: "Opposite to what was expected", insufficient_data: "Not enough data" };
  const R_NEXT = { collect_more_sessions: "Collect more sessions", add_reference_rating: "Add a reference rating", review_tracking_quality: "Review tracking quality",
    discuss_with_patient: "Discuss with the patient", none: "None" };
  const R_STATUS = { insufficient: "too few days", no_variation: "did not vary", is_reference: "is the reference" };
  const SRC = { model: "model", code: "code", code_corrected: "model, corrected by code" };
  function f2(v) { return v === null || v === undefined ? "–" : (v > 0 ? "+" : "") + Number(v).toFixed(2); }
  function rhoBar(r) {
    // Interval and point on a fixed -1..+1 scale; right of the middle = as expected.
    const W = 120, H = 16, x = (v) => (W / 2) + Math.max(-1, Math.min(1, v)) * (W / 2 - 2);
    const s = svg("svg", { viewBox: "0 0 " + W + " " + H, class: "rho", role: "img", "aria-label": "rho " + f2(r.rho) + ", interval " + f2(r.ci_low) + " to " + f2(r.ci_high) });
    s.appendChild(svg("line", { class: "axis", x1: W / 2, y1: 1, x2: W / 2, y2: H - 1 }));
    if (r.ci_low !== null && r.ci_high !== null) s.appendChild(svg("line", { class: "ci", x1: x(r.ci_low), y1: H / 2, x2: x(r.ci_high), y2: H / 2 }));
    s.appendChild(svg("circle", { class: "pt " + (r.agreement || ""), cx: x(r.rho), cy: H / 2, r: 3.5 }));
    return s;
  }
  // Every session the phone sent, one row each: the raw sample behind the statistics.
  const SAMPLE_COLS = [["smile_time_share", "Smiling", 100, "%"], ["eye_smile_share", "Reach eyes", 100, "%"], ["smile_response_share", "Smiled at moment", 100, "%"],
    ["facial_activity", "Face movement", 1, ""], ["blink_rate_per_min", "Blinks/min", 1, ""], ["look_down_share", "Looking down", 100, "%"], ["head_movement", "Head movement", 1, ""]];
  function sampleCell(v, z, mult, unit) {
    if (v === null || v === undefined) return el("td", { class: "r num muted" }, "–");
    const shown = mult === 100 ? Math.round(v * 100) + unit : (Math.abs(v) >= 10 ? Math.round(v) : Number(v).toFixed(2));
    const off = z !== null && z !== undefined && Math.abs(z) >= 2;
    return el("td", { class: "r num" + (off ? " off" : "") }, shown, off ? el("span", { class: "sub" }, (z > 0 ? "▲ " : "▼ ") + Math.abs(z).toFixed(1)) : null);
  }
  function samplesPanel(d) {
    const A = d.activities || {};
    const all = [];
    ["focus", "breathing"].forEach((t) => ((A[t] || {}).sessions || []).forEach((x) => all.push(Object.assign({ type: t }, x))));
    all.sort((a, b) => String(b.started_at).localeCompare(String(a.started_at)));
    if (!all.length) return panel("Samples collected", "", empty("No sessions yet."));
    const heads = ["When", "Activity", { t: "Reaction ms", r: 1 }, { t: "Errors", r: 1 }].concat(SAMPLE_COLS.map((c) => ({ t: c[1], r: 1 })), ["Tracking", "Model reading"]);
    const rows = all.slice(0, 40).map((x) => {
      const f = x.face || {}, fz = f.z || {}, v = x.values || {}, z = x.z || {}, rd = (x.reading || {}).reading;
      const said = rd ? [rd.reactions, rd.expression, rd.eyes].filter((w) => w && !/^(steady|as_usual|unclear)$/.test(w)).map((w) => words(w).toLowerCase()).join(" · ") || "as usual" : "–";
      return el("tr", null,
        el("td", { class: "num nowrap" }, stamp(x.started_at)),
        el("td", null, x.type === "focus" ? "Focus game" : "Breathing", x.completed ? null : el("span", { class: "sub" }, "stopped early")),
        sampleCell(v.median_reaction_ms, z.median_reaction_ms, 1, ""),
        sampleCell(v.error_rate, z.error_rate, 100, "%"),
        SAMPLE_COLS.map((c) => sampleCell(f[c[0]], fz[c[0]], c[2], c[3])),
        el("td", null, x.face ? words(f.quality || "") : el("span", { class: "muted" }, "no camera")),
        el("td", { class: "small" }, said));
    });
    return panel("Samples collected", all.length, el("p", { class: "muted small" }, "One row per session from the phone. ▲ ▼ mark a value at least 2 spreads from this person's own usual."),
      el("div", { class: "scroll-x" }, table(heads, rows, "samples")));
  }
  function caveatCell(r) {
    const cs = r.caveats || [];
    if (!cs.length) return el("td", { class: "muted" }, "–");
    const key = "cav-" + r.key, open = !!S.open[key];
    return el("td", { class: "cav" },
      el("button", { type: "button", class: "btn btn-small", "aria-expanded": open ? "true" : "false", "data-key": key,
        on: { click: () => { Object.keys(S.open).forEach((k) => { if (k.indexOf("cav-") === 0 && k !== key) delete S.open[k]; }); S.open[key] = !open; render(); } } },
        cs.length + (cs.length === 1 ? " caveat" : " caveats")),
      open ? el("div", { class: "pop", role: "dialog", "aria-label": "Caveats for " + r.label },
        el("div", { class: "pop-h" }, r.label),
        el("ul", { class: "plain" }, cs.map((c) => el("li", null, c.text, el("span", { class: "muted" }, c.by === "model" ? " (named by the model)" : " (added by code)")))),
        el("button", { type: "button", class: "linklike small", on: { click: () => { delete S.open[key]; render(); } } }, "Close")) : null);
  }
  function tabResearch(d) {
    const wrap = el("div", { class: "stack" });
    const a = S.assoc;
    const run = el("button", { type: "button", class: "btn btn-small", "data-key": "assoc-run", on: { click: async () => {
      S.demoMsg = ""; flash("Running the appraisal…");
      try { S.assoc = await api("POST", "/v1/clinic/patients/" + encodeURIComponent(d.patient_id) + "/associations/run"); flash(""); } catch (e) { flash(e.message); }
      render();
    } }, title: "Compute the statistics again from the data held now and ask the model for a new judgement. Takes about 15 seconds." }, "Recalculate");
    if (!a) { wrap.appendChild(empty("Loading…")); return wrap; }
    wrap.appendChild(el("div", { class: "bar" },
      el("span", { class: "muted small" }, a.disclaimer || ""), el("div", { class: "push" }, run)));
    if (a.status !== "ready") { wrap.appendChild(empty("Not computed yet. Select “Recalculate”.")); return wrap; }
    const o = a.overall || {}, ref = a.reference || {}, des = a.design || {}, src = o.sources || {};
    wrap.appendChild(panel("Overall", null,
      el("div", { class: "facts" },
        factTile(R_PATTERN[o.pattern] || words(o.pattern), "pattern · " + (SRC[src.pattern] || "")),
        factTile(words(o.confidence), "confidence · " + (SRC[src.confidence] || "")),
        factTile(String(o.independent_lines), "independent kinds of measure agree"),
        factTile(o.leads_reference ? "Yes" : "No", "measures move before the reference"),
        factTile(R_NEXT[o.next_step] || words(o.next_step), "next step · " + (SRC[src.next_step] || ""))),
      el("p", { class: "small" }, "Most plausible other explanation: ", o.main_alternative_text || words(o.main_alternative)),
      el("p", { class: "muted small" },
        "Reference: " + (ref.label || ref.key) + (ref.kind === "proxy" ? " (a proxy, not a clinical rating)" : " (" + (ref.ratings || 0) + " ratings)") +
        " · " + des.days + " days, " + des.sessions + " sessions, " + des.rows_tested + " measures tested" +
        " · appraised by " + (a.appraised_by === "model" ? "the local model (" + ((a.inputs || {}).model || "") + ")" : "code only") + ", checked by code" +
        " · " + stamp(a.generated_at) + (a.hypotheses_reviewed_by_clinician ? "" : " · hypothesis list not yet reviewed by a clinician"))));
    const strongest = new Set(o.strongest || []);
    const GROUP = { face: "Face", activity: "Activities", daily: "Daily data" };
    ["face", "activity", "daily"].forEach((g) => {
      const rows = (a.rows || []).filter((r) => r.group === g);
      if (!rows.length) return;
      wrap.appendChild(panel(GROUP[g], rows.length, table(
        ["Measure", "Expected when worse", { t: "Days", r: 1 }, "Opposite ← rho → as expected", { t: "p adj.", r: 1 }, { t: "Lead", r: 1 }, "Judgement", "Caveats"],
        rows.map((r) => {
          const tested = r.status === "tested";
          return el("tr", { class: strongest.has(r.key) ? "changed" : "" },
            el("td", null, r.label, el("span", { class: "sub" }, r.why)),
            el("td", null, r.expected, el("span", { class: "sub" }, r.support + " support")),
            el("td", { class: "r num" }, r.n),
            el("td", null, tested ? el("div", { class: "rhocell" }, rhoBar(r), el("span", { class: "num small" }, f2(r.rho) + " [" + f2(r.ci_low) + ", " + f2(r.ci_high) + "]")) : el("span", { class: "muted" }, R_STATUS[r.status] || words(r.status))),
            el("td", { class: "r num" }, tested && r.p_adj !== null ? Number(r.p_adj).toFixed(3) : "–"),
            el("td", { class: "r num" }, tested && r.lead_days !== null && r.lead_days !== undefined ? (r.lead_days > 0 ? "+" : "") + r.lead_days + " d" : "–"),
            el("td", null, tested ? [el("span", { class: "chip " + (r.agreement === "consistent" ? "good" : r.agreement === "opposite" ? "bad" : "") }, words(r.agreement).toLowerCase() + (r.strength ? ", " + r.strength : "")),
              el("span", { class: "sub" }, SRC[r.agreement_source] || "")] : "–"),
            caveatCell(r));
        }), "assoc")));
    });
    wrap.appendChild(samplesPanel(d));
    const cor = a.corrections || [];
    wrap.appendChild(panel("What code corrected in the model's answer", cor.length || "", cor.length ? table(["Where", "Field", "Model said", "Code set", "Why"],
      cor.map((c) => el("tr", null, el("td", null, c.where === "row" ? c.key : "overall"), el("td", null, words(c.field)),
        el("td", null, c.model === null || c.model === undefined ? "–" : String(c.model)), el("td", null, c.code === null || c.code === undefined ? "–" : String(c.code)),
        el("td", null, words(c.reason).toLowerCase())))) : empty(a.appraised_by === "model" ? "Nothing: the model's judgements matched the numbers." : "No model took part in this appraisal.")));
    const notes = a.data_notes || [];
    if (notes.length) wrap.appendChild(panel("Notes on the data", notes.length, el("ul", { class: "plain" }, notes.map((n) => el("li", null, n.text)))));
    return wrap;
  }
  function tabLog(d) {
    const wrap = el("div", { class: "stack" });
    const ref = d.refusal_log || [];
    wrap.appendChild(panel("Model answers refused by the gates", ref.length || "", ref.length ? table(["When", "Step", "Reason", "Used instead"],
      ref.slice(0, 30).map((r) => el("tr", null, el("td", { class: "num" }, stamp(r.at)), el("td", null, words(r.task || r.gate || r.layer || "")),
        el("td", null, words(r.reason || r.code || "")), el("td", null, words(r.fallback || r.used || "–"))))) : empty("No refusals.")));
    const nl = d.notify_log || [];
    wrap.appendChild(panel("Alerts to the clinic", nl.length || "", nl.length ? table(["When", "Level", "Result", "Why"],
      nl.slice(0, 30).map((n) => el("tr", null, el("td", { class: "num" }, stamp(n.at)), el("td", null, levelChip(n.level) || "–"),
        el("td", null, words(n.result || n.event || n.code || "")), el("td", null, words(n.reason || kind(n.kind) || "–"))))) : empty("No alerts.")));
    const notes = d.notes || [];
    wrap.appendChild(panel("Notes from the patient", notes.length || "", notes.length ? table(["When", "Mood", "Asked for help", "Text"],
      notes.slice(0, 30).map((n) => { const c = n.classification || n.labels || n; return el("tr", null, el("td", { class: "num" }, stamp(n.at || n.created_at)),
        el("td", null, words(c.mood || "–")), el("td", null, c.asks_for_help || n.crisis ? el("span", { class: "chip l-urgent" }, icon("dot"), "Yes") : "No"),
        el("td", null, n.text ? n.text : el("span", { class: "muted" }, "not shared"))); })) : empty("No notes.")));
    const dw = d.draft_wording || {};
    wrap.appendChild(panel("Settings", null, el("div", { class: "facts" },
      factTile(d.share_notes ? "Yes" : "No", "note text shared"),
      factTile(d.allow_outside_processing ? "Yes" : "No", "outside model allowed"),
      factTile(dw.help_block_reviewed_by_clinician ? "Reviewed" : "Draft", "help screen wording"),
      factTile(dw.note_lexicon_reviewed_by_clinician ? "Reviewed" : "Draft", "help word list"))));
    return wrap;
  }

  // ---------------------------------------------------------------- demo
  function viewDemo() {
    const wrap = el("div");
    wrap.appendChild(el("div", { class: "head" }, el("h1", null, "Demo")));
    const pid = S.me && S.me.demo && S.me.demo.patient_id;
    const run = (label, method, path, body) => el("button", { type: "button", class: "btn", "data-key": "demo-" + label, on: { click: async () => {
      S.demoMsg = label + "…"; render();
      try { await api(method, path, body); S.list = null; S.detail = null; S.trace = null; S.demoMsg = label + ": done at " + stamp(new Date().toISOString()); }
      catch (e) { S.demoMsg = label + ": " + e.message; }
      render();
    } } }, label);
    wrap.appendChild(el("section", { class: "panel" },
      el("h2", null, "Demo patient"),
      el("div", { class: "demo-actions" },
        run("Usual days", "POST", "/v1/demo/scenario", { name: "normal", patient_id: pid }),
        run("Dip", "POST", "/v1/demo/scenario", { name: "dip", patient_id: pid }),
        run("Run learning", "POST", "/v1/review/run", { patient_id: pid }),
        run("Regular check", "POST", "/v1/demo/tick", undefined),
        run("Reset", "POST", "/v1/demo/reset", undefined)),
      el("p", { class: "result", role: "status" }, S.demoMsg),
      pid ? el("p", null, el("a", { href: "#/p/" + encodeURIComponent(pid) }, "Open the demo patient")) : null));
    return wrap;
  }

  // ---------------------------------------------------------------- start
  window.addEventListener("hashchange", onRoute);
  S.timer = setInterval(() => { if (S.token && !document.hidden) refresh(); }, 60000);
  onRoute();
})();
