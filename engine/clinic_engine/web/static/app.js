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
    metric: "movement", open: {}, tbl: {}, actTab: "summary", tq: "", changedOnly: true, page: 0, demoMsg: "", busy: false, timer: null,
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
    if (parts[0] === "blueprint") { if (["research", "gemini", "learning"].indexOf(parts[1]) >= 0) S.bpTab = parts[1]; return { view: "blueprint", pid: null, tab: "overview" }; }
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
      if (r.view === "patients" || r.view === "demo" || r.view === "blueprint") {
        if (force || !S.list) S.list = await api("GET", "/v1/clinic/patients");
        if (r.view === "blueprint" && S.me.demo && S.me.demo.patient_id && (force || !S.bpAssoc)) {
          try { S.bpAssoc = await api("GET", "/v1/clinic/patients/" + encodeURIComponent(S.me.demo.patient_id) + "/associations"); } catch (e) { S.bpAssoc = null; }
          const nul = ((S.list && S.list.patients) || []).find((q) => q.label === "Example R-001");
          if (nul) { try { S.bpNull = await api("GET", "/v1/clinic/patients/" + encodeURIComponent(nul.patient_id) + "/associations"); } catch (e) { S.bpNull = null; } }
        }
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
      // Not in the menu: the page wipes example data with one click. It stays reachable at #/demo.
      $("nav-demo").hidden = !(S.me.demo && S.me.demo.enabled && S.route.view === "demo");
      try { sessionStorage.setItem("clinic_demo", S.me.demo && S.me.demo.enabled ? "1" : "0"); } catch (e) { /* storage may be blocked */ }
    } else {
      let was = null; try { was = sessionStorage.getItem("clinic_demo"); } catch (e) { was = null; }
      $("nav-demo").hidden = was !== "1" || S.route.view !== "demo";
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
  // Every table: search by typing, an optional filter on one column, and pages.
  // The bar appears once a table is long enough to need it. Typing redraws only the
  // table body, so the search box keeps its focus. State is kept per table in S.tbl.
  const TABLE_PER = 10, TABLE_BAR_FROM = 7;
  function cellKey(td) { return td && td.firstChild ? String(td.firstChild.textContent || "").split(",")[0].trim() : ""; }
  function table(heads, rows, cls, opt) {
    opt = opt || {};
    rows = (rows || []).filter(Boolean);
    const t = el("table", { class: cls || null });
    t.appendChild(el("thead", null, el("tr", null, heads.map((h) => el("th", { class: h.r ? "r" : null, scope: "col" }, h.t || h)))));
    const body = el("tbody");
    t.appendChild(body);
    const box = el("div", { class: "scroll" }, t);
    if (opt.plain || rows.length < TABLE_BAR_FROM) { rows.forEach((r) => body.appendChild(r)); return box; }
    const id = opt.id || (cls || "t") + ":" + heads.map((h) => h.t || h).join("|");
    const st = S.tbl[id] || (S.tbl[id] = { q: "", page: 0, f: "" });
    const per = opt.per || TABLE_PER;
    const hay = rows.map((r) => r.textContent.toLowerCase());
    const fcol = typeof opt.filter === "number" ? opt.filter : -1;
    const fkeys = fcol >= 0 ? rows.map((r) => cellKey(r.children[fcol])) : [];
    const info = el("span", { class: "muted small num" });
    const prev = el("button", { type: "button", class: "btn btn-small", "data-key": id + "-prev" }, "←");
    const next = el("button", { type: "button", class: "btn btn-small", "data-key": id + "-next" }, "→");
    const none = el("tr", null, el("td", { colspan: heads.length, class: "muted" }, "Nothing matches."));
    const draw = () => {
      const terms = st.q.toLowerCase().split(/\s+/).filter(Boolean);
      const found = rows.filter((r, i) => (!st.f || fkeys[i] === st.f) && terms.every((w) => hay[i].indexOf(w) >= 0));
      const pages = Math.max(1, Math.ceil(found.length / per));
      st.page = Math.min(Math.max(st.page, 0), pages - 1);
      const from = st.page * per, shown = found.slice(from, from + per);
      info.textContent = found.length ? (from + 1) + "–" + (from + shown.length) + " of " + found.length : "0 of " + rows.length;
      prev.disabled = st.page === 0; next.disabled = st.page >= pages - 1;
      body.replaceChildren.apply(body, shown.length ? shown : [none]);
    };
    prev.addEventListener("click", () => { st.page -= 1; draw(); });
    next.addEventListener("click", () => { st.page += 1; draw(); });
    const search = el("input", { type: "search", class: "search", placeholder: "Search", "aria-label": "Search this table", "data-key": id + "-q" });
    search.value = st.q;
    search.addEventListener("input", () => { st.q = search.value; st.page = 0; draw(); });
    let pick = null;
    if (fcol >= 0) {
      const values = Array.from(new Set(fkeys.filter(Boolean))).sort();
      if (values.length > 1) {
        pick = el("select", { class: "search pick", "aria-label": "Filter by " + (heads[fcol].t || heads[fcol]), "data-key": id + "-f" },
          el("option", { value: "" }, (heads[fcol].t || heads[fcol]) + ": all"), values.map((v) => el("option", { value: v }, v)));
        if (values.indexOf(st.f) < 0) st.f = "";
        pick.value = st.f;
        pick.addEventListener("change", () => { st.f = pick.value; st.page = 0; draw(); });
      } else { st.f = ""; }
    }
    draw();
    return el("div", null, el("div", { class: "bar tbar" }, search, pick, el("div", { class: "push pager" }, prev, info, next)), box);
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
    // the stretch below the person's usual range, drawn again in the warning colour
    let low = "", on = false;
    values.forEach((z, i) => {
      const below = z !== null && z !== undefined && z < -1.5;
      const prev = i > 0 ? values[i - 1] : null;
      if (!below) { on = false; return; }
      const px = (k) => (k * (W - 4) / Math.max(1, n - 1) + 2).toFixed(1);
      if (!on && i > 0 && prev !== null && prev !== undefined) low += "M" + px(i - 1) + " " + y(prev).toFixed(1) + "L" + px(i) + " " + y(z).toFixed(1);
      else low += (on ? "L" : "M") + px(i) + " " + y(z).toFixed(1);
      on = true;
    });
    if (low) s.appendChild(svg("path", { class: "line low", d: low }));
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
    const heads = ["Status", "Patient", "Why", "Flagged for", hasSpark ? "Movement vs own normal, 28 d" : null, "Last data"].filter(Boolean);
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
    if (S.route.tab === "overview" && body && body.appendChild) { const dp = daysPanel(d); if (dp) body.appendChild(dp); }
    if (S.route.tab === "overview" && d.summary) wrap.appendChild(el("p", { class: "lead" },
      String(d.summary).replace(/\s*Last suggestion:[^.]*\.?/, "").replace(/held since/g, "flagged since").replace(/\b\d{4}-\d{2}-\d{2}\b/g, (m) => dayShort(m))));
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
    const mv = metric === "movement";
    if ((mv || metric === "steps") && v.steps !== undefined && v.steps !== null) parts.push(num(v.steps) + " steps");
    if ((mv || metric === "walking_speed_m_s") && v.walking_speed_m_s !== undefined && v.walking_speed_m_s !== null) parts.push(v.walking_speed_m_s.toFixed(2) + " m/s");
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
    const L = 150, R = 10, T = 10, PH = 190, AX = 22, LANE = 18;
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
    // The scale is the person's own spread: 0 is their usual, the band is their usual range.
    [["+2 above usual", 2], ["own usual", 0], ["−2 below usual", -2]].forEach(([t, z]) => {
      if (z !== 0) s.appendChild(svg("line", { class: "axis", x1: L - 4, x2: L, y1: y(z), y2: y(z) }));
      s.appendChild(svg("text", { x: L - 8, y: y(z) + 4, "text-anchor": "end" }, t));
    });
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

  // ---- the day reading: two readers on the daily numbers from Apple Health
  // Code's fixed rule (each day against the person's own normal) and the
  // level-2 model read the same series. The series is the one that was sent.
  const DAY_CH = { steps: "Steps", walk_speed: "Walking speed", sleep_h: "Sleep, hours", hrv: "HRV", rest_hr: "Resting heart rate", active_kcal: "Active energy", exercise_min: "Exercise minutes", daylight_min: "Daylight minutes" };
  const WEEKDAY = ["", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"];
  function daysPanel(d) {
    const f = d.days_reading, types = d.health_types || [];
    if (!f || f.status === "off") return null;
    const title = "Two readers on the daily numbers";
    const typesLine = types.length ? el("p", { class: "muted fr-note" }, "Apple Health types stored for this person: " + types.length + " (" + types.slice(0, 6).map((t) => t.type.replace(/^HK(Quantity|Category)TypeIdentifier/, "")).join(", ") + (types.length > 6 ? ", …" : "") + ").") : null;
    if (f.status !== "ready") {
      return panel(title, null, empty(f.status === "not_allowed" ? "The patient has not allowed outside processing, so the daily numbers were not sent to the model. Code's comparison with the person's own normal is in the chart above."
        : f.status === "too_few_days" ? "Fewer than three weeks of days so far; the model reads the series once there are more."
        : f.status === "pending" ? "The model has not read the daily numbers yet." : "The model did not return a usable reading" + (f.reason ? " (" + words(f.reason).toLowerCase() + ")." : ".")), typesLine);
    }
    const st = f.stream, ag = f.agreement || {}, model = f.model || "the model";
    const chans = st.channels.slice(2);
    const ch = chans.indexOf(S.dayCh) >= 0 ? S.dayCh : "steps";
    const k = st.channels.indexOf(ch), n = st.days;
    const vals = st.rows.map((r) => r[k]);
    const have = vals.filter((v) => v !== null);
    const lo = Math.min.apply(null, have), hi = Math.max.apply(null, have);
    const first = parseDay(st.first_date);
    const dayLabel = (i) => { const t = new Date(first.getTime() + i * 86400000); return t.getUTCDate() + " " + MONTHS[t.getUTCMonth()]; };
    const W = 920, L = 150, R = 14, T = 12, PH = 120, LANE = 26, H = T + PH + 18 + LANE * 2 + 26;
    const x = (i) => L + (W - L - R) * (i + 0.5) / n, bw = (W - L - R) / n;
    const y = (v) => T + PH - PH * (hi > lo ? (v - lo * 0.9) / (hi - lo * 0.9) : 0.5);
    const c = svg("svg", { class: "chart fr", viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": DAY_CH[ch] + " by day: stretches found by code's fixed rule and named by " + model });
    c.appendChild(svg("line", { class: "axis", x1: L, x2: W - R, y1: T + PH, y2: T + PH }));
    c.appendChild(svg("text", { class: "lane", x: L - 8, y: T + 10, "text-anchor": "end" }, DAY_CH[ch]));
    c.appendChild(svg("text", { x: L - 8, y: T + 26, "text-anchor": "end" }, num(lo, ch === "walk_speed" ? 2 : 0) + " to " + num(hi, ch === "walk_speed" ? 2 : 0)));
    let dpath = "", pen = false;
    vals.forEach((v, i) => { if (v === null) { pen = false; return; } dpath += (pen ? "L" : "M") + x(i).toFixed(1) + " " + y(v).toFixed(1); pen = true; });
    c.appendChild(svg("path", { class: "line", d: dpath }));
    for (let i = 0; i < n; i += 14) c.appendChild(svg("text", { x: x(i), y: H - 4, "text-anchor": i === 0 ? "start" : "middle" }, dayLabel(i)));
    c.appendChild(svg("text", { x: W - R, y: H - 4, "text-anchor": "end" }, dayLabel(n - 1)));
    const lane = (q) => T + PH + 18 + LANE * q;
    const bar = (cls, a, b, q, title) => c.appendChild(svg("rect", { class: "fr-bar " + cls, x: x(a) - bw / 2, y: lane(q) + 5, width: Math.max(4, x(b) - x(a) + bw), height: LANE - 12, rx: 3 }, svg("title", null, title)));
    const span = (a, b) => dayLabel(a) + " to " + dayLabel(b);
    c.appendChild(svg("text", { class: "lane", x: L - 8, y: lane(0) + 17, "text-anchor": "end" }, "Code, fixed rule"));
    c.appendChild(svg("text", { class: "lane", x: L - 8, y: lane(1) + 17, "text-anchor": "end" }, "Model"));
    const mine = (b) => b.channel === ch;
    f.stretches.filter(mine).forEach((b) => {
      if (b.status === "same") bar("code", b.code_start_d, b.code_end_d, 0, "Code: " + b.direction + ", " + span(b.code_start_d, b.code_end_d));
      bar(b.status === "same" ? "same" : "faint", b.start_d, b.end_d, 1, "Model: " + b.direction + ", " + words(b.shape).toLowerCase() + ", " + span(b.start_d, b.end_d) + ". " + (b.status === "same" ? "Code's fixed rule flagged the same stretch." : "The fixed rule did not flag this stretch; code confirmed the change in the numbers (" + num(b.z, 1) + " spreads from before).")); });
    f.missed_stretches.filter(mine).forEach((b) => bar("code", b.start_d, b.end_d, 0, "Code: " + b.direction + ", " + span(b.start_d, b.end_d) + " (the model did not name it)"));
    (f.dropped || []).filter((b) => b.item === "stretch" && mine(b)).forEach((b) => bar("drop", b.start_d, b.end_d, 1, "Model: named " + b.direction + ", " + span(b.start_d, b.end_d) + ". Dropped by code: " + words(b.reason).toLowerCase() + "."));
    const m = (q, one, many) => q + " " + (q === 1 ? one : many);
    const lines = [el("p", { class: "readout" }, el("b", null, model), " named " + m(ag.stretches_reported || 0, "stretch", "stretches") + " that changed. Code's fixed rule flagged " + (ag.stretches_code || 0) + "; " + (ag.stretches_same || 0) + " are the same.")];
    if (ag.stretches_model_only) lines.push(el("p", { class: "readout fr-faint" }, el("b", null, m(ag.stretches_model_only, "stretch", "stretches")), " named by the model only: not flagged by the fixed rule (too mild on any single day, or a slow slide), and code confirmed the change in the numbers."));
    if (ag.stretches_not_in_numbers || ag.stretches_missed) lines.push(el("p", { class: "readout" }, (ag.stretches_not_in_numbers ? m(ag.stretches_not_in_numbers, "named stretch is", "named stretches are") + " not in the numbers, and code dropped " + (ag.stretches_not_in_numbers === 1 ? "it. " : "them. ") : "") + (ag.stretches_missed ? m(ag.stretches_missed, "stretch", "stretches") + " of code's not named by the model." : "")));
    const wk = (f.weekly || []).filter((w) => w.low_weekdays.length).map((w) => DAY_CH[w.channel].toLowerCase() + " lower on " + w.low_weekdays.map((q) => WEEKDAY[q]).join(" and "));
    if (wk.length) lines.push(el("p", { class: "readout muted" }, "This person's weekly rhythm, named by the model and confirmed by code: " + wk.join("; ") + ". A low day that belongs to the rhythm is not a change."));
    const pick = chans.length > 1 ? el("div", { class: "seg", role: "group", "aria-label": "Measure" }, chans.map((q) =>
      el("button", { type: "button", class: "btn btn-small", "aria-pressed": q === ch ? "true" : "false", on: { click: () => { S.dayCh = q; render(); } } }, DAY_CH[q]))) : null;
    const legend = el("ul", { class: "legend" },
      el("li", null, el("span", { class: "fr-key code" }), "code's fixed rule"),
      el("li", null, el("span", { class: "fr-key same" }), "model, same stretch as code"),
      el("li", null, el("span", { class: "fr-key faint" }), "model only: change confirmed by code"),
      el("li", null, el("span", { class: "fr-key drop" }), "model only: dropped by code"));
    return panel(title, null, pick, lines, c, legend,
      el("p", { class: "muted fr-note" }, "The model receives " + n + " days as numbers with a day number and the weekday: no dates, name or text. The line is what was sent. Two methods read the same numbers; neither says how the person feels, and the thresholds are estimates."), typesLine);
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
        (() => { const m = S.metric, u = usual;
          const t = m === "walking_speed_m_s" ? (u.walking_speed_m_s != null ? Number(u.walking_speed_m_s).toFixed(2) + " m/s" : null)
            : m === "hrv_ms" ? (u.hrv_ms != null ? num(Math.round(u.hrv_ms)) + " ms" : null)
            : m === "sleep_h" ? (u.sleep_h != null ? Number(u.sleep_h).toFixed(1) + " h sleep" : null)
            : (u.steps != null ? num(u.steps) + " steps" : null);
          return t ? el("span", { class: "count" }, "usual " + t) : null; })()),
      seg, readoutFor(last, S.metric), chart(d, S.metric, today),
      el("ul", { class: "legend" },
        el("li", null, icon("dot"), "usual"), el("li", null, icon("down"), "below own normal"), el("li", null, icon("up"), "above"),
        series.some((day) => seriesZ(day, S.metric) === null && estimateZ(d, day, S.metric) !== null) ? el("li", null, icon("ring"), "early days, while own normal was learned") : null,
        el("li", null, el("span", { class: "bandkey" }), "grey band: own usual range"),
        el("li", null, icon("diamond"), "offer done"), el("li", null, icon("diamond-o"), "offer not done")));

    const items = (d.attention_items || []).filter((i) => i.state === "open" || !i.closed_at)
      .sort((a, b) => (LEVEL_ORDER[a.level] ?? 9) - (LEVEL_ORDER[b.level] ?? 9));
    const plain = (i) => {
      const x = i.detail || {};
      if (i.kind === "deviation") return "movement below own normal, " + x.low_days + " low days";
      if (i.kind === "slower_reactions") return "slower than usual in " + x.slower_sessions + " of the last " + x.of_last + " focus games";
      if (i.kind === "face_flat") return "less facial movement in " + x.flat_sessions + " of the last " + x.of_last + " sessions";
      if (i.kind === "plans_not_done") return x.in_a_row + " plans in a row not carried out";
      if (i.kind === "low_notes") return x.low_notes + " notes labelled low";
      if (i.kind === "weak_rounds") return x.rounds + " weak sessions in a row";
      if (i.kind === "novelty") return words(x.metric || "a measure").toLowerCase() + " far " + (x.direction === "down" ? "below" : "above") + " usual today";
      if (i.kind === "silence") return "no data for " + x.days_silent + " days";
      if (i.kind === "ignored") return x.unanswered + " offers left unanswered";
      return detailText(i.detail) || "";
    };
    const ackLink = (i) => el("button", { type: "button", class: "linklike small ack", "data-key": "ack-" + i.id, "aria-label": "Acknowledge " + kind(i.kind),
      on: { click: async () => { try { await api("POST", "/v1/clinic/attention/" + encodeURIComponent(i.id) + "/ack"); await refresh(); } catch (e) { flash(e.message); } } } }, "Acknowledge");
    const helpItem = items.find((i) => i.kind === "asked_for_help");
    const others = items.filter((i) => i !== helpItem);
    const att = panel("Needs attention", items.length || "", items.length ? el("div", { class: "rows" },
      helpItem ? el("div", { class: "row" },
        el("div", { class: "top" }, levelChip(helpItem.level), el("span", { class: "t" }, kind(helpItem.kind))),
        ackButton(helpItem), helpQuote(d)) : null,
      others.length ? el("ul", { class: "attlist" }, others.map((i) => el("li", null,
        el("span", { class: "dotk l-" + i.level }), el("span", { class: "what" }, plain(i).charAt(0).toUpperCase() + plain(i).slice(1)),
        el("span", { class: "muted since" }, i.since ? "since " + dayShort(i.since) : ""), ackLink(i)))) : null) : empty("Nothing held."));

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
      factTile(meanZ === null ? "–" : signed(meanZ), "average movement, in own spreads (" + zWord(meanZ) + ")")));
    return el("div", { class: "grid" }, el("div", { class: "stack" }, left, facts), el("div", { class: "stack" }, att, offer));
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
  const TL_COLS = [["watchers", "Watchers"], ["attention", "Attention"], ["response", "Response"], ["level1", "Local model"], ["level2", "Second model"], ["notifier", "Alert"], ["learning", "Learning"]];
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
        const whyText = why.length ? " (" + Array.from(new Set(why.map(plainReason))).slice(0, 2).join("; ") + (new Set(why.map(plainReason)).size > 2 ? "; …" : "") + ")" : "";
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
      (open ? "▾ " : "▸ ") + (x.level === 2 ? "Second model" : "Local model") + " (" + modelName(x.model) + ") · " + (TASK[x.task] || words(x.task)) + " · " + (x.ms / 1000).toFixed(1) + " s" + (x.reply === null ? " · no reply" : ""));
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
    const tterms = (S.tq || "").toLowerCase().split(/\s+/).filter(Boolean);
    const chainText = (c) => [c.headline, TRIGGER[c.trigger] || c.trigger, c.outcome, stamp(c.at)].concat((c.entries || []).map((e) => [LAYER[e.layer] || e.layer, e.code, (e.detail || {}).kind, (e.detail || {}).task, (e.detail || {}).action, (e.detail || {}).because].join(" "))).join(" ").replace(/_/g, " ").toLowerCase();
    const chains = (t.chains || []).filter((c) => (!S.changedOnly || c.changed) && (!tterms.length || tterms.every((w) => chainText(c).indexOf(w) >= 0)));
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
      (() => { const q = el("input", { type: "search", class: "search", placeholder: "Search the timeline", "aria-label": "Search the timeline", "data-key": "tl-q" });
        q.value = S.tq || ""; q.addEventListener("input", () => { S.tq = q.value; S.page = 0; const at = q.selectionStart; render(); const again = document.querySelector('[data-key="tl-q"]'); if (again) { again.focus(); again.setSelectionRange(at, at); } }); return q; })(),
      el("div", { class: "push" }, pager("top"))));
    if (!chains.length) { wrap.appendChild(empty(tterms.length ? "Nothing in the timeline matches “" + S.tq + "”." : S.changedOnly ? "No changes recorded. Turn off “Changes only” to see every check." : "Nothing recorded yet.")); return wrap; }
    const rows = [];
    shown.forEach((c) => {
      const key = "chain-" + c.chain_id;
      const open = !!S.open[key];
      rows.push(el("tr", { class: (c.changed ? "changed" : "") + (open ? " open" : ""), on: { click: () => { S.open[key] = !open; render(); } } },
        el("td", { class: "num nowrap" }, el("button", { type: "button", class: "linklike", "aria-expanded": open ? "true" : "false", "data-key": key }, stamp(c.at))),
        el("td", null, /refused/i.test(c.headline || "") && c.trigger === "appraisal" ? "Research appraisal: code corrected the model" : c.headline || TRIGGER[c.trigger] || words(c.trigger)),
        TL_COLS.map(([layer]) => el("td", null, layerCell(c, layer)))));
      if (open) rows.push(el("tr", { class: "detail" }, el("td", { colspan: 2 + TL_COLS.length },
        el("div", { class: "tl-body" }, el("table", null, el("tbody", null, (c.entries || []).map(entryRow))),
          (S.exch || []).filter((x) => x.chain_id === c.chain_id).slice().reverse().map(exchangeBox)))));
    });
    wrap.appendChild(el("section", { class: "panel" }, table(["When", "Trigger"].concat(TL_COLS.map((x) => x[1])), rows, "pick tl-table", { plain: true })));
    if (pages > 1) wrap.appendChild(pager("bottom"));
    return wrap;
  }


  // ---- the frame reading: two readers on one session
  // Code's fixed rule and the level-2 model read the same numbers. The bars
  // come from the stored reading; the curve is the audited raw download.
  const FR = { onset: 0.25 };
  function framesPanel(sessions, agreement) {
    const ready = sessions.filter((x) => x.frames_reading && x.frames_reading.status === "ready");
    const waiting = sessions.filter((x) => x.frames_reading && /^(pending|failed|not_allowed)$/.test(x.frames_reading.status));
    if (!ready.length) {
      if (!waiting.length) return null;
      const st = waiting[0].frames_reading;
      return panel("Two readers on one session", null, empty(st.status === "not_allowed"
        ? "The patient has not allowed outside processing, so no frames were sent to the model. Code's summary is in the table above."
        : st.status === "pending" ? "The model is reading the latest session." : "The model did not return a usable reading" + (st.reason ? " (" + words(st.reason).toLowerCase() + ")." : ".")));
    }
    const cur = ready.find((x) => x.id === S.frId) || ready[0];
    const f = cur.frames_reading, ag = f.agreement || {};
    const model = f.model || "the model";
    const dur = cur.raw && cur.raw.frames && cur.raw.rate_hz ? cur.raw.frames / cur.raw.rate_hz
      : Math.max(10, ...[].concat(f.smiles, f.faint_smiles, f.missed_smiles).map((b) => b.end_s || 0));
    const dropped = (f.dropped || []).filter((d) => d.item === "smile");
    const codeBars = f.smiles.map((b) => ({ a: b.code_start_s, b: b.code_end_s })).concat(f.missed_smiles.map((b) => ({ a: b.start_s, b: b.end_s, missed: 1 })));
    const curve = S.frCurve && S.frCurve.id === cur.id ? S.frCurve : null;

    const W = 920, L = 150, R = 14, T = 12, PH = 120, LANE = 26, H = T + PH + 18 + LANE * 2 + 26;
    const x = (t) => L + (W - L - R) * Math.min(1, Math.max(0, t / dur));
    const peak = curve ? Math.max(0.5, ...curve.v) : 0.5;
    const y = (v) => T + PH - PH * Math.min(1, v / peak);
    const c = svg("svg", { class: "chart fr", viewBox: "0 0 " + W + " " + H, role: "img",
      "aria-label": "Smiles in one session: found by code's fixed rule and reported by " + model });
    c.appendChild(svg("line", { class: "axis", x1: L, x2: W - R, y1: T + PH, y2: T + PH }));
    c.appendChild(svg("line", { class: "fr-onset", x1: L, x2: W - R, y1: y(FR.onset), y2: y(FR.onset) }));
    c.appendChild(svg("text", { x: L - 8, y: y(FR.onset) + 4, "text-anchor": "end" }, "fixed rule " + FR.onset));
    if (f.resting_smile !== null && f.resting_smile !== undefined) {
      c.appendChild(svg("line", { class: "fr-rest", x1: L, x2: W - R, y1: y(f.resting_smile), y2: y(f.resting_smile) }));
      c.appendChild(svg("text", { x: L - 8, y: y(f.resting_smile) + 4, "text-anchor": "end" }, "own rest " + num(f.resting_smile, 2)));
    }
    c.appendChild(svg("text", { class: "lane", x: L - 8, y: T + 10, "text-anchor": "end" }, "Smile, 0 to " + num(peak, 1)));
    if (curve) c.appendChild(svg("path", { class: "line", d: curve.v.map((v, i) => (i ? "L" : "M") + x(curve.t[i]).toFixed(1) + " " + y(v).toFixed(1)).join("") }));
    else c.appendChild(svg("text", { x: (L + W - R) / 2, y: T + PH / 2, "text-anchor": "middle" }, "The curve is not loaded. The bars below come from the stored reading."));
    const step = dur > 90 ? 20 : dur > 30 ? 10 : 5;
    for (let t = 0; t <= dur + 0.01; t += step) c.appendChild(svg("text", { x: x(t), y: H - 4, "text-anchor": t === 0 ? "start" : "middle" }, t + " s"));
    const lane = (k) => T + PH + 18 + LANE * k;
    const bar = (cls, a, b, k, title) => c.appendChild(svg("rect", { class: "fr-bar " + cls, x: x(a), y: lane(k) + 5, width: Math.max(4, x(b) - x(a)), height: LANE - 12, rx: 3 }, svg("title", null, title)));
    const span = (b) => num(b.start_s !== undefined ? b.start_s : b.a, 1) + " to " + num(b.end_s !== undefined ? b.end_s : b.b, 1) + " s";
    c.appendChild(svg("text", { class: "lane", x: L - 8, y: lane(0) + 17, "text-anchor": "end" }, "Code, fixed rule"));
    c.appendChild(svg("text", { class: "lane", x: L - 8, y: lane(1) + 17, "text-anchor": "end" }, "Model"));
    codeBars.forEach((b) => bar("code", b.a, b.b, 0, "Code: smile, " + span(b) + (b.missed ? " (the model did not report it)" : "")));
    f.smiles.forEach((b) => bar("same", b.start_s, b.end_s, 1, "Model: smile, " + span(b) + ". Code found the same smile" + (b.corrected && b.corrected.length ? "; code corrected " + b.corrected.map((w) => words(w).toLowerCase()).join(" and ") : "") + "."));
    f.faint_smiles.forEach((b) => bar("faint", b.start_s, b.end_s, 1, b.status === "inside_long"
      ? "Model: smile, " + span(b) + ", peak " + num(b.peak, 2) + ". The fixed rule counted a far longer stretch here as one smile; code confirmed a clear rise and return inside it."
      : b.status === "brief"
      ? "Model: brief smile, " + span(b) + ". Peak " + num(b.peak, 2) + ": above the fixed rule's level, but shorter than the rule's minimum length. Code confirmed the rise in the numbers."
      : "Model: faint smile, " + span(b) + ". Peak " + num(b.peak, 2) + ", under the fixed rule; it rises " + num(b.rise, 2) + " above the resting level around it, and code confirmed that rise in the numbers."));
    dropped.forEach((b) => bar("drop", b.start_s, b.end_s, 1, "Model: reported a smile, " + span(b) + ". Dropped by code: " + words(b.reason).toLowerCase() + "."));
    (f.moments || []).forEach((m) => c.appendChild(svg("path", { class: "fr-moment", d: "M" + x(m.at_s) + " " + (T + PH + 2) + "l4 8h-8z" }, svg("title", null, "Pleasant moment at " + num(m.at_s, 1) + " s: " + (m.smiled ? "a smile followed" : "no smile followed")))));

    const n = (k, one, many) => k + " " + (k === 1 ? one : many);
    const lines = [cur.example ? el("p", { class: "readout muted" }, "Generated example session: no person was recorded. The numbers come from a generator with smiles planted at known places.") : null,
      el("p", { class: "readout" }, el("b", null, model), " reported " + n(ag.smiles_reported || 0, "smile", "smiles") + ". Code's fixed rule found " + n(ag.smiles_code || 0, "smile", "smiles") + "; " + (ag.smiles_matched || 0) + " are the same.")];
    if (ag.smiles_faint) lines.push(el("p", { class: "readout fr-faint" }, el("b", null, n(ag.smiles_faint, "faint smile", "faint smiles")), " reported by the model only: under the fixed rule, above this person's own resting level, and code confirmed the rise in the numbers."));
    if (ag.smiles_brief) lines.push(el("p", { class: "readout fr-faint" }, el("b", null, n(ag.smiles_brief, "brief smile", "brief smiles")), " reported by the model only: too short for the fixed rule's minimum length; code confirmed the rise in the numbers."));
    if (ag.smiles_inside_long) lines.push(el("p", { class: "readout fr-faint" }, el("b", null, n(ag.smiles_inside_long, "smile", "smiles")), " reported by the model inside a far longer stretch that the fixed rule counted as one smile; code confirmed each rise and return in the numbers."));
    const notIn = ag.smiles_not_in_numbers || 0, poor = ag.smiles_poor_match || 0;
    if (notIn || poor || ag.smiles_missed) lines.push(el("p", { class: "readout" },
      (notIn ? n(notIn, "reported smile is", "reported smiles are") + " not in the numbers, and code dropped " + (notIn === 1 ? "it. " : "them. ") : "") +
      (poor ? n(poor, "report", "reports") + " of a real smile matched it poorly (a sliver, far too wide, or twice). " : "") +
      (ag.smiles_missed ? n(ag.smiles_missed, "smile", "smiles") + " of code's not reported by the model." : "")));
    const blinkOk = f.blinks && f.blinks.status === "confirmed";
    lines.push(el("p", { class: "readout muted" }, "Blink counts " + (blinkOk ? "agree" : "differ") + ". Segments confirmed: " + (ag.segments_confirmed || 0) + " of " + (ag.segments_reported || 0) + ". Overall words the same: " + (ag.overall_same === null || ag.overall_same === undefined ? "–" : ag.overall_same + " of 4") + "."));
    if (typeof f.resting_smile === "number" && f.resting_smile >= FR.onset - 0.05) lines.push(el("p", { class: "readout fr-faint" }, "This person's mouth rests at " + num(f.resting_smile, 2) + ", close to the fixed rule's level of " + FR.onset + ". The fixed rule is not reliable here; read its smiles with care."));

    const pick = ready.length > 1 ? el("div", { class: "seg", role: "group", "aria-label": "Session" }, ready.slice(0, 8).map((sx) =>
      el("button", { type: "button", class: "btn btn-small", "aria-pressed": sx.id === cur.id ? "true" : "false", on: { click: () => { S.frId = sx.id; render(); } } }, dayShort(sx.date) + " " + String(sx.started_at).slice(11, 16)))) : null;
    const load = curve ? null : el("button", { type: "button", class: "btn btn-small", disabled: S.frBusy ? "disabled" : null, on: { click: async () => {
      S.frBusy = true; render();
      try {
        const raw = await api("GET", "/v1/clinic/patients/" + encodeURIComponent(S.route.pid) + "/activities/" + encodeURIComponent(cur.id) + "/face-raw");
        const li = raw.channels.indexOf("mouthSmileLeft"), ri = raw.channels.indexOf("mouthSmileRight");
        const k = Math.max(1, Math.round(raw.rate_hz / 10)), t = [], v = [];
        for (let i = 0; i < raw.samples.length; i += k) {
          let sum = 0, cnt = 0;
          for (let j = i; j < Math.min(raw.samples.length, i + k); j++) { if (!raw.tracked || raw.tracked[j]) { sum += (raw.samples[j][li] + raw.samples[j][ri]) / 2; cnt++; } }
          if (cnt) { t.push(i / raw.rate_hz); v.push(sum / cnt); }
        }
        S.frCurve = { id: cur.id, t, v };
      } catch (e) { flash(e.message); }
      S.frBusy = false; render();
    } } }, S.frBusy ? "Loading…" : "Show the smile curve (the download is written to the audit log)");
    const legend = el("ul", { class: "legend" },
      el("li", null, el("span", { class: "fr-key code" }), "code's fixed rule"),
      el("li", null, el("span", { class: "fr-key same" }), "model, same smile as code"),
      el("li", null, el("span", { class: "fr-key faint" }), "model only: rise confirmed by code"),
      el("li", null, el("span", { class: "fr-key drop" }), "model only: dropped by code"));
    let over = null;
    if (agreement && agreement.sessions) {
      const pct = (v) => (v === null || v === undefined ? "–" : Math.round(v * 100) + " %");
      over = el("div", { class: "facts" },
        factTile(String(agreement.sessions), "sessions read by the model"),
        factTile(pct(agreement.smile_recall), "of code's smiles also reported by the model (" + agreement.smiles_matched + " of " + agreement.smiles_code + ")"),
        factTile(pct(agreement.smile_precision), "of the model's smiles at code's level also found by code"),
        factTile(String((agreement.smiles_faint || 0) + (agreement.smiles_brief || 0) + (agreement.smiles_inside_long || 0)), "smiles from the model only, rise confirmed by code"),
        factTile(String(agreement.smiles_not_in_numbers || 0), "reported smiles not in the numbers, dropped by code"),
        factTile(agreement.smile_start_error_s === null ? "–" : num(agreement.smile_start_error_s, 2) + " s", "mean difference in where a smile starts (the model marks the rise, the rule the crossing)"));
    }
    return panel("Two readers on one session", null, pick, lines, c, legend, load,
      el("p", { class: "muted fr-note" }, "The model receives numbers only: no picture, name, date or text. Two methods read the same numbers; neither is the truth, and neither says how the person feels. The fixed rule's thresholds are estimates, not yet calibrated on recordings."),
      over ? el("h3", { class: "fr-h" }, "Every session the model has read") : null, over);
  }

  // ---- activity
  function outcomeWord(v) { return v === null || v === undefined ? "–" : v > 0.3 ? "better after" : v < -0.3 ? "worse after" : "no change"; }
  function tabActivity(d) {
    const wrap = el("div", { class: "stack" });
    const acts = (d.progress && d.progress.actions) || {};
    const used = Object.keys(acts).filter((a) => acts[a].offered > 0).sort((a, b) => acts[b].offered - acts[a].offered);
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
        el("span", { class: "sub" }, (r.read_by === "level1" ? "model 1" : "model 2") + ", checked by code" + (dropped ? " · " + dropped + " claim" + (dropped > 1 ? "s" : "") + " dropped" : "")));
    };
    const yes = (b) => (b ? "yes" : "no");
    const recent = (g) => ((g && g.sessions) || []).slice().reverse();
    const offers = (d.suggestions || []).slice().sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
    const rounds = (d.progress && d.progress.rounds && d.progress.rounds.energy_series) || [];
    const SUB = [["summary", "Summary", null], ["focus", "Focus game", recent(A.focus).length], ["breathing", "Breathing", recent(A.breathing).length],
      ["checkin", "Evening check-in", recent(A.checkin).length], ["offers", "Offers and answers", offers.length], ["earlier", "Earlier sessions", rounds.length]]
      .filter((x) => x[2] === null || x[2] > 0);
    if (!SUB.some((x) => x[0] === S.actTab)) S.actTab = "summary";
    wrap.appendChild(el("div", { class: "seg", role: "group", "aria-label": "Activity sections" }, SUB.map(([key, label, n]) =>
      el("button", { type: "button", class: "btn btn-small", "aria-pressed": S.actTab === key ? "true" : "false", "data-key": "act-" + key,
        on: { click: () => { S.actTab = key; render(); } } }, label + (n ? " · " + n : "")))));
    const sub = S.actTab;
    if (sub === "summary") {
      if (A.focus || A.breathing || A.checkin) {
        const c7 = (A.counts && A.counts.last_7_days) || {};
        const tile = (key, label) => factTile(c7[key] ? c7[key].finished + "/" + c7[key].played : "–", label + " finished, 7 d");
        wrap.appendChild(panel("Last 7 days", null,
          el("div", { class: "facts" }, tile("focus", "focus games"), tile("breathing", "breathing"), tile("checkin", "check-ins"))));
      }
      wrap.appendChild(panel("What was offered", null, used.length ? table(
        ["Offer", { t: "Offered", r: 1 }, { t: "Done", r: 1 }, { t: "Not today", r: 1 }, { t: "No answer", r: 1 }, "Days after"],
        used.map((a) => el("tr", null, el("td", null, action(a)), el("td", { class: "r num" }, acts[a].offered), el("td", { class: "r num" }, acts[a].done),
          el("td", { class: "r num" }, acts[a].not_today), el("td", { class: "r num" }, (acts[a].no_answer || 0) + (acts[a].open || 0)),
          el("td", null, acts[a].done < 5 ? el("span", { class: "muted" }, "too few to say (" + acts[a].done + " done)") : outcomeWord(acts[a].mean_outcome_change))))) : empty("Nothing offered yet.")));
    }
    if (sub === "focus") wrap.appendChild(panel("Focus game", A.focus.sessions.length, table(["Date", "Finished", { t: "Reaction", r: 1 }, "Against own normal", { t: "Errors", r: 1 }, "Face", "Model reading"],
      recent(A.focus).map((x) => el("tr", null, el("td", { class: "num" }, dayShort(x.date)), el("td", null, yes(x.completed)),
        el("td", { class: "r num" }, x.values && x.values.median_reaction_ms != null ? num(x.values.median_reaction_ms) + " ms" : "–"),
        el("td", { class: "num" }, !x.z || x.z.median_reaction_ms == null ? "–" : (x.z.median_reaction_ms >= 1.5 ? "slower than usual" : x.z.median_reaction_ms <= -1.5 ? "faster than usual" : "usual") + " (" + signed(x.z.median_reaction_ms) + ")"),
        el("td", { class: "r num" }, x.values && x.values.error_rate != null ? Math.round(x.values.error_rate * 100) + " %" : "–"),
        faceCell(x.face), readCell(x.reading))), null, { filter: 1 })));
    if (sub === "focus" || sub === "breathing") { const fp = framesPanel(recent(A[sub]), A.frames_agreement); if (fp) wrap.appendChild(fp); }
    if (sub === "breathing") wrap.appendChild(panel("Breathing", A.breathing.sessions.length, table(["Date", "Finished", { t: "Time", r: 1 }, "Face", "Model reading"],
      recent(A.breathing).map((x) => el("tr", null, el("td", { class: "num" }, dayShort(x.date)), el("td", null, yes(x.completed)),
        el("td", { class: "r num" }, x.values && x.values.time_played_s != null ? num(x.values.time_played_s) + " s" : "–"), faceCell(x.face), readCell(x.reading))), null, { filter: 1 })));
    if (sub === "checkin") wrap.appendChild(panel("Evening check-in", A.checkin.sessions.length, table(["Date", { t: "Good things", r: 1 }, "Plan for next day", "Plan done", "Asked for help"],
      recent(A.checkin).map((x) => el("tr", null, el("td", { class: "num" }, dayShort(x.date)),
        el("td", { class: "r num" }, x.values ? x.values.good_things : "–"),
        el("td", null, x.plan ? x.plan.label || (x.plan.catalog_id ? words(x.plan.catalog_id) : "own words") : "–"),
        el("td", null, x.plan_done === "yes" ? "yes" : x.plan_done === "no" ? "no" : "–"),
        el("td", null, x.asked_for_help ? el("span", { class: "chip l-urgent" }, icon("dot"), "Yes") : "No"))), null, { filter: 3 })));
    if (sub === "offers") wrap.appendChild(panel("Offers and answers", offers.length || "", table(["Date", "Offer", "Because of", "Answer", "Felt"],
      offers.map((o) => el("tr", null, el("td", { class: "num" }, dayShort(o.date)), el("td", null, action(o.action)), el("td", null, o.attention_kind === "example" ? "–" : kind(o.attention_kind)),
        el("td", null, el("span", { class: "chip " + (o.answer === "did_it" ? "good" : o.answer ? "" : "bad") }, ANSWER[o.answer] || "No answer")),
        el("td", null, o.felt ? words(o.felt) : "–"))), null, { filter: 3 })));
    if (sub === "earlier") wrap.appendChild(panel("Earlier sessions", rounds.length,
      table(["Date", "Mode", "Finished", "Energy"], rounds.slice().reverse().map((r) => el("tr", null,
        el("td", { class: "num" }, dayShort(r.started_at)), el("td", null, words(r.mode)), el("td", null, r.completed ? "yes" : "no"), el("td", null, r.energy_bucket ? words(r.energy_bucket) : "–"))), null, { filter: 1 })));
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
    const firstSaid = ev.findIndex((e) => e.kind !== "alert");
    if (firstSaid > 0) ev.splice(0, firstSaid);
    const localDay = (iso) => { const t = new Date(iso); return new Date(t.getTime() - t.getTimezoneOffset() * 60000).toISOString().slice(0, 10); };
    const chatOn = d.chat_mode === "gemini";
    wrap.appendChild(el("p", { class: "muted small" }, d.share_notes
      ? (chatOn
        ? "The patient agreed to share the words they write. Chat mode is on: Lanvi's reply to a note may be written by Gemini (an outside model) and checked by code; each such reply is marked. A note that asks for help always gets the fixed line."
        : "The patient agreed to share the words they write. Lanvi answers only with lines from a fixed set; a model labels the words and does not write to the patient.")
      : (chatOn
        ? "This patient has not shared the words they write, so only the labels are shown. Chat mode is on: Lanvi's replies written by Gemini are marked."
        : "This patient has not shared the words they write, so only the labels are shown. Lanvi answers only with lines from a fixed set.")));
    if (!ev.length) { wrap.appendChild(empty("Nothing written or offered yet.")); return wrap; }
    const chat = el("div", { class: "chat" });
    const who = d.display_name || d.label;
    let day = "";
    ev.forEach((e) => {
      const dd = localDay(e.at);
      if (dd !== day) { day = dd; chat.appendChild(el("div", { class: "chat-day" }, dayShort(dd))); }
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
          el("div", { class: "who" }, e.n.reply_by === "model" ? "Lanvi · written by Gemini, checked by code" : "Lanvi · fixed line"), el("div", { class: "text" }, e.n.reply)));
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
  // ---- blueprint: the research, for someone who has never heard of a PHQ-9
  const BP_KEY = "face.smile_rate_per_min";
  // the weeks of one example person: every rating, with that week's smiling where there were games
  function bpWeeks(a) {
    const sr = a && a.series, ref = (a && a.reference) || {};
    if (!sr || ref.key !== "phq9" || !(sr.measures || {})[BP_KEY]) return [];
    return sr.reference.slice().sort((p, q) => p[0] - q[0]).map((rp) => {
      const wk = sr.measures[BP_KEY].filter((m) => rp[0] - m[0] >= 0 && rp[0] - m[0] < 7);
      return { day: rp[0], score: rp[1], smiles: wk.length ? wk.reduce((t, m) => t + m[1], 0) / wk.length : null };
    });
  }
  // the score above, "smiling less" below, on one time axis; big for the first screen, tiny for the cards
  function bpPair(weeks, o) {
    const big = !!o.big, CW = big ? 960 : 420, L = big ? 300 : 44, R = big ? 16 : 8;
    const AT = big ? 20 : 6, AH = big ? 96 : 34, GAP = big ? 44 : 8, BT = AT + AH + GAP, BH = big ? 96 : 34, CH = BT + BH + (big ? 30 : 6);
    const n0 = weeks[0].day, n1 = weeks[weeks.length - 1].day;
    const x = (d) => L + ((d - n0) / ((n1 - n0) || 1)) * (CW - L - R);
    const ya = (v) => AT + (1 - Math.min(20, v) / 20) * AH;
    const yb = (v) => BT + ((v - o.sLo) / ((o.sHi - o.sLo) || 1)) * (BH - 12) + 6;  // fewer smiles = higher on the page
    const c = svg("svg", { viewBox: "0 0 " + CW + " " + CH, class: big ? "bp" : "bp mini", role: "img", "aria-label": o.label });
    weeks.forEach((w, i) => {
      if (w.score < 10) return;
      const xa = i === 0 ? x(w.day) - (big ? 20 : 4) : (x(weeks[i - 1].day) + x(w.day)) / 2, xb = i === weeks.length - 1 ? x(w.day) + (big ? 14 : 4) : (x(w.day) + x(weeks[i + 1].day)) / 2;
      c.appendChild(svg("rect", { x: xa, y: AT, width: xb - xa, height: BT + BH - AT, class: "tg-band" }));
    });
    c.appendChild(svg("line", { x1: L, y1: ya(10), x2: CW - R, y2: ya(10), class: "tg-cut" }));
    if (big) {
      c.appendChild(svg("text", { x: 4, y: AT + 26, class: "bp-l" }, "EVERY WEEK"));
      c.appendChild(svg("text", { x: 4, y: AT + 50, class: "bp-t" }, "Questionnaire score"));
      c.appendChild(svg("text", { x: 4, y: AT + 70, class: "bp-s" }, "nine questions, 0 to 27 · up = worse"));
      const calm = weeks.reduce((m, w) => (w.score < m.score ? w : m), weeks[0]);  // put the label where the line is far below it
      c.appendChild(svg("text", { x: Math.min(CW - R - 90, Math.max(L + 90, x(calm.day))), y: ya(10) - 7, class: "tg-ax", "text-anchor": "middle" }, "10: the line clinics watch"));
      c.appendChild(svg("text", { x: 4, y: BT + 26, class: "bp-l" }, "EVERY DAY"));
      c.appendChild(svg("text", { x: 4, y: BT + 50, class: "bp-t" }, "The phone: smiling less"));
      c.appendChild(svg("text", { x: 4, y: BT + 70, class: "bp-s" }, "in a short game · weekly average · up = worse"));
    }
    if (!big) {
      c.appendChild(svg("text", { x: 2, y: AT + 10, class: "tg-ax" }, "score"));
      c.appendChild(svg("text", { x: 2, y: BT + 10, class: "tg-ax" }, "phone"));
    }
    c.appendChild(svg("polyline", { points: weeks.map((w) => x(w.day).toFixed(1) + "," + ya(w.score).toFixed(1)).join(" "), class: big ? "tg-ref" : "tg-ref thin" }));
    weeks.forEach((w) => {
      c.appendChild(svg("circle", { cx: x(w.day), cy: ya(w.score), r: big ? 5 : 2.5, class: "tg-refpt" }));
      if (big) c.appendChild(svg("text", { x: x(w.day), y: ya(w.score) - 10, class: "tg-v", "text-anchor": "middle" }, String(w.score)));
    });
    let run = [];
    const flush = () => { if (run.length > 1) c.appendChild(svg("polyline", { points: run.map((w) => x(w.day).toFixed(1) + "," + yb(w.smiles).toFixed(1)).join(" "), class: big ? "tg-avg" : "tg-avg thin" })); run = []; };
    weeks.forEach((w) => {
      if (w.smiles === null) { flush(); if (big) c.appendChild(svg("text", { x: x(w.day), y: BT + BH - 2, class: "tg-ax", "text-anchor": "middle" }, "no games this week")); return; }
      run.push(w);
      c.appendChild(svg("circle", { cx: x(w.day), cy: yb(w.smiles), r: big ? 4 : 2, class: "tg-pt" }));
    });
    flush();
    if (big) {
      c.appendChild(svg("text", { x: L, y: CH - 6, class: "tg-ax" }, "week 1"));
      c.appendChild(svg("text", { x: CW - R, y: CH - 6, class: "tg-ax", "text-anchor": "end" }, "week " + weeks.length));
    }
    return c;
  }
  function bpResearch(wrap) {
    const P = (text) => el("p", { class: "bp-text" }, text);
    const a = S.bpAssoc, row = a && (a.rows || []).find((r) => r.key === BP_KEY);
    const weeks = bpWeeks(a), played = weeks.filter((w) => w.smiles !== null);
    const have = !!(row && row.status === "tested" && played.length >= 6);
    const sm = played.map((w) => w.smiles), sLo = sm.length ? Math.min.apply(null, sm) : 0, sHi = sm.length ? Math.max.apply(null, sm) : 1;
    wrap.appendChild(P("After TMS treatment for depression (magnetic stimulation given at a clinic), a person sees the clinic rarely, but their phone is with them every day. Do things a phone can measure change when the depression gets worse again? In a study we check the phone against a weekly questionnaire; in real life nobody fills in a form every week."));
    // 1. the whole idea as one picture, on the first screen
    if (have) wrap.appendChild(el("section", { class: "panel" },
      el("figure", { class: "bp-fig" }, bpPair(weeks, { big: true, sLo, sHi, label: "Weeks of one example person. Above, the questionnaire score. Below, how much less she smiled. The two lines rise and fall in the same weeks." })),
      P("One example person, Anna, over " + weeks.length + " weeks. Example data: it shows the idea, not a finding. In the shaded weeks her score was 10 or more, and in those same weeks she smiled less. Do the two lines move together? That is the whole question.")));
    // 6. the second question, drawn as what we would look for
    const q = svg("svg", { viewBox: "0 0 420 206", class: "bp", role: "img", "aria-label": "A sketch, not data: the phone's line starts to rise one week before the questionnaire score does." });
    const qa = [[0, 150], [1, 150], [2, 150], [3, 150], [4, 118], [5, 84], [6, 62]], qb = [[0, 150], [1, 150], [2, 150], [3, 120], [4, 88], [5, 66], [6, 54]];
    const qx = (i) => 20 + i * 62;
    q.appendChild(svg("polyline", { points: qa.map((v) => qx(v[0]) + "," + (v[1] - 44)).join(" "), class: "tg-ref" }));
    qa.forEach((v) => q.appendChild(svg("circle", { cx: qx(v[0]), cy: v[1] - 44, r: 4.5, class: "tg-refpt" })));
    q.appendChild(svg("polyline", { points: qb.map((v) => qx(v[0]) + "," + (v[1] + 36)).join(" "), class: "tg-avg" }));
    qb.forEach((v) => q.appendChild(svg("circle", { cx: qx(v[0]), cy: v[1] + 36, r: 4, class: "tg-pt" })));
    q.appendChild(svg("text", { x: 20, y: 84, class: "bp-s" }, "questionnaire score"));
    q.appendChild(svg("text", { x: 20, y: 164, class: "bp-s" }, "the phone"));
    q.appendChild(svg("line", { x1: qx(2), y1: 30, x2: qx(2), y2: 196, class: "tg-cross" }));
    q.appendChild(svg("line", { x1: qx(3), y1: 30, x2: qx(3), y2: 196, class: "tg-cross" }));
    q.appendChild(svg("line", { x1: qx(2), y1: 24, x2: qx(3), y2: 24, class: "bp-line" }));
    q.appendChild(svg("text", { x: (qx(2) + qx(3)) / 2, y: 16, class: "tg-v", "text-anchor": "middle" }, "one week earlier?"));
    wrap.appendChild(el("section", { class: "panel hero" }, el("p", { class: "hero-k" }, "The second question"), el("p", { class: "hero-t" }, "Do the phone’s numbers change first?"),
      el("div", { class: "grid2" },
        el("div", null,
          P("The picture above compares the same week with the same week. That can show the phone’s numbers move with the score. It cannot show that they move earlier. Only if they change before the score does could a clinic be told sooner."),
          P("The study we want to run: twenty to thirty people after TMS, twelve weeks, the questionnaire every week, and this app. We compare this week’s phone numbers with next week’s score, for each person and across all of them.")),
        el("figure", { class: "bp-fig" }, q, el("figcaption", { class: "bp-text" }, "What we would look for. A sketch, not data: this is not established.")))));
    wrap.appendChild(el("h2", { class: "bp-sub" }, "The details: what is measured, the yardstick, how sure, and the limits"));
    // 2. what the phone measures
    const card = (title, where, items) => el("section", { class: "panel" }, el("h2", null, title), el("p", { class: "bp-text" }, where), el("ul", { class: "plain big" }, items.map((t) => el("li", null, t))));
    wrap.appendChild(P("Smiling is one example. When depression deepens, people often smile less, move less and react more slowly; doctors see this in the room. Whether a phone at home can see it is an open question: early studies are small and mixed. These are the things we let the phone count:"));
    wrap.appendChild(el("div", { class: "grid3" },
      card("The face", "The front camera, during a 45-second game or a minute of breathing. People smile and frown a little even while concentrating. For each frame the phone sends only numbers, such as how far the mouth corners are up or how closed the eyes are. No photo, no video and no face shape leaves it. The clinic’s server works out the measures from those numbers, so a rule can be changed and old sessions recomputed.",
        ["how often and how strongly the person smiles", "how much the face moves at all", "how much they look down"]),
      card("The game", "A short focus game: tap the right lights.", ["how fast they react", "how steady their speed is", "how many mistakes"]),
      card("Apple Health", "What the phone and watch already collect all day, with the person’s permission.", ["steps and walking speed", "hours of sleep"])));
    // 3. the yardstick
    const s2 = svg("svg", { viewBox: "0 0 960 92", class: "bp", role: "img", "aria-label": "The score from 0 to 27 in five bands: 0 to 4 minimal, 5 to 9 mild, 10 to 14 moderate, 15 to 19 moderately severe, 20 to 27 severe." });
    const X = (v) => 10 + (v / 27) * 940;
    [[0, 5, "minimal", 0.1], [5, 10, "mild", 0.22], [10, 15, "moderate", 0.42], [15, 20, "moderately severe", 0.62], [20, 27.0001, "severe", 0.85]].forEach(([lo, hi, name, op]) => {
      const r = svg("rect", { x: X(lo) + 1, y: 34, width: X(hi) - X(lo) - 2, height: 24, rx: 4, class: "phq-band" });
      r.setAttribute("opacity", op);
      s2.appendChild(r);
      s2.appendChild(svg("text", { x: (X(lo) + X(hi)) / 2, y: 78, class: "tg-ax", "text-anchor": "middle" }, name));
      s2.appendChild(svg("text", { x: X(lo) + 2, y: 28, class: "tg-ax" }, String(lo)));
    });
    s2.appendChild(svg("text", { x: 950, y: 28, class: "tg-ax", "text-anchor": "end" }, "27"));
    s2.appendChild(svg("line", { x1: X(10), y1: 14, x2: X(10), y2: 62, class: "fp-ci" }));
    s2.appendChild(svg("text", { x: X(10) + 8, y: 12, class: "bp-l" }, "10 or more: symptoms count as moderate. This is the line clinics watch."));
    wrap.appendChild(el("section", { class: "panel" }, el("h2", null, "The yardstick: a nine-question score (PHQ-9)"),
      P("Nine questions about things like low mood, loss of interest, sleep and energy. For each, the person says how often it bothered them lately, from “not at all” (0) to “nearly every day” (3). The points add up to a score from 0 to 27. It is widely used in clinics, so it is our yardstick: the phone’s numbers are never compared with a diagnosis, only with this score."),
      el("figure", { class: "bp-fig" }, s2)));
    // 4. how sure: the same weeks as dots, and the range
    if (have) {
      const SW = 420, SH = 250, L = 40, R = 14, T = 16, B = 40;
      const xMax = Math.max(20, Math.max.apply(null, played.map((w) => w.score)) + 1), yLo = sLo * 0.8, yHi = sHi * 1.12;
      const sx = (v) => L + (v / xMax) * (SW - L - R), sy = (v) => T + (1 - (v - yLo) / (yHi - yLo)) * (SH - T - B);
      const s3 = svg("svg", { viewBox: "0 0 " + SW + " " + SH, class: "bp", role: "img", "aria-label": "One dot per week: the questionnaire score across, smiles per minute up. Weeks with a higher score have fewer smiles." });
      [0, 10, 20].forEach((g) => { s3.appendChild(svg("line", { x1: sx(g), y1: T, x2: sx(g), y2: SH - B, class: g === 10 ? "tg-cut" : "fp-grid" })); s3.appendChild(svg("text", { x: sx(g), y: SH - B + 16, class: "tg-ax", "text-anchor": "middle" }, String(g))); });
      s3.appendChild(svg("line", { x1: L, y1: SH - B, x2: SW - R, y2: SH - B, class: "fp-zero" }));
      s3.appendChild(svg("text", { x: (L + SW - R) / 2, y: SH - 6, class: "tg-ax", "text-anchor": "middle" }, "questionnaire score that week →"));
      [1, 2, 3].forEach((g) => { if (g < yLo || g > yHi) return; s3.appendChild(svg("text", { x: L - 6, y: sy(g) + 4, class: "tg-ax", "text-anchor": "end" }, String(g))); });
      s3.appendChild(svg("text", { x: 2, y: 10, class: "tg-ax" }, "↑ smiles a minute"));
      s3.appendChild(svg("text", { x: sx(10) + 5, y: T + 10, class: "tg-ax" }, "the line clinics watch"));
      played.forEach((w) => s3.appendChild(svg("circle", { cx: sx(w.score), cy: sy(w.smiles), r: 6, class: "dotw" })));
      const thumb = (kind, label) => {
        const t = svg("svg", { viewBox: "0 0 96 60", class: "thumb", role: "img", "aria-label": label });
        const pts = kind === 0 ? [[10, 40], [22, 14], [34, 46], [46, 22], [58, 38], [70, 12], [82, 44], [28, 30], [64, 26]]
          : kind === 2 ? [[10, 10], [20, 15], [30, 20], [40, 25], [50, 30], [60, 35], [70, 40], [80, 45], [88, 49]]
          : played.map((w) => [8 + (w.score / xMax) * 80, 8 + (1 - (w.smiles - yLo) / (yHi - yLo)) * 44]);  // Anna's own dots
        pts.forEach((q) => t.appendChild(svg("circle", { cx: q[0], cy: q[1], r: 3, class: "dotw" })));
        return el("div", { class: "thumbbox" }, t, el("span", null, label));
      };
      const rho = Math.abs(row.rho), lo = Math.max(0, row.ci_low), hi = Math.min(1, row.ci_high);
      const rb = svg("svg", { viewBox: "0 0 420 52", class: "rangebar", role: "img", "aria-label": "The link is " + rho.toFixed(2) + "; it could plausibly be anywhere from " + lo.toFixed(2) + " to " + hi.toFixed(2) + "." });
      const rx = (v) => 14 + v * 392;
      rb.appendChild(svg("line", { x1: rx(0), y1: 22, x2: rx(1), y2: 22, class: "fp-zero" }));
      [[0, "0  no link"], [0.5, "0.5"], [1, "1  perfect"]].forEach(([g, t]) => { rb.appendChild(svg("line", { x1: rx(g), y1: 14, x2: rx(g), y2: 30, class: "fp-zero" })); rb.appendChild(svg("text", { x: rx(g), y: 46, class: "tg-ax", "text-anchor": g === 0 ? "start" : g === 1 ? "end" : "middle" }, t)); });
      rb.appendChild(svg("line", { x1: rx(lo), y1: 22, x2: rx(hi), y2: 22, class: "rb-bar" }));
      rb.appendChild(svg("circle", { cx: rx(rho), cy: 22, r: 6, class: "rb-pt" }));
      rb.appendChild(svg("text", { x: rx(rho), y: 9, class: "tg-v", "text-anchor": "middle" }, rho.toFixed(2)));
      wrap.appendChild(el("section", { class: "panel" }, el("h2", null, "How sure can we be?"),
        el("div", { class: "grid2" },
          el("div", null, el("figure", { class: "bp-fig" }, s3), P("The same weeks, one dot each. More symptoms, fewer smiles: the dots fall from left to right.")),
          el("div", null,
            P("One number says how tightly the dots follow a line:"),
            el("div", { class: "thumbs" }, thumb(0, "0: no link"), thumb(1, rho.toFixed(2) + ": Anna"), thumb(2, "1: a perfect line")),
            rb,
            P((played.length === 12 ? "Twelve" : played.length) + " dots is few" + (played.length < weeks.length ? " (one week had no games)" : "") + ", so the real link could be anywhere on the thick bar. The bar does not touch 0, so we say “they move together”. If it touched 0, we would say “we cannot tell”. On the patient pages a bar left of 0 means the measure moved the opposite way.")))));
    }
    // 5. the two answers, each with its picture
    const list = (S.list && S.list.patients) || [];
    const anna = S.me && S.me.demo && S.me.demo.patient_id, elina = (list.find((q) => q.label === "Example R-001") || {}).patient_id;
    const nweeks = bpWeeks(S.bpNull);
    const mini = (wk, label) => (wk.filter((w) => w.smiles !== null).length >= 4 ? el("figure", { class: "bp-fig" }, bpPair(wk, { big: false, sLo, sHi, label })) : null);
    wrap.appendChild(el("div", { class: "grid2" },
      el("section", { class: "panel" }, el("h2", null, "Answer one: “they move together”"),
        have ? mini(weeks, "Anna: the score rises and falls, and smiling less follows it.") : null,
        P("Anna’s score went up, came down and went up again. In the same weeks she smiled less, reacted more slowly and walked less."),
        anna ? el("p", { class: "bp-text" }, el("a", { href: "#/p/" + encodeURIComponent(anna) + "/research" }, "Open Anna’s research page")) : null),
      el("section", { class: "panel" }, el("h2", null, "Answer two: “we cannot tell”"),
        nweeks.length ? mini(nweeks, "Elina: the score stays low and flat, so there is nothing to follow.") : null,
        P("Elina stayed well. Her score hardly moved, so there was nothing for the phone’s numbers to follow, and the tool says so. In twelve weeks many people will stay well, like Elina. A tool that always finds something would be worthless."),
        elina ? el("p", { class: "bp-text" }, el("a", { href: "#/p/" + encodeURIComponent(elina) + "/research" }, "Open Elina’s research page")) : null)));
    // 7. limits, and who does what
    wrap.appendChild(panel("What this does not show", null, el("ul", { class: "plain big" },
      el("li", null, "Everything on this page is example data. Whether a phone can see this in real patients is not known."),
      el("li", null, "It is about one person over time. It never says “people who smile less are depressed”."),
      el("li", null, "We look at many measures, so some will line up by luck. And one week resembles the next, so 12 dots count for fewer than 12 and the bar should be wider."),
      el("li", null, "People who feel worse play less, so the bad weeks have the least data."),
      el("li", null, "Other things move these numbers too: light, glasses, how the phone is held, medication, getting better at the game, the season."),
      el("li", null, "The questionnaire asks about sleep and slowed movement itself, so sleep and steps partly overlap with the yardstick."))));
    wrap.appendChild(P("Who does what: the phone only collects numbers and sends them. The clinic’s server computes every measure and the statistics with plain code. A language model sees only the summary numbers (such as " + (have ? Math.abs(row.rho).toFixed(2) : "0.67") + "), never the daily measurements, the name or the face, and puts the result into words. Code then checks those words against the numbers."));
  }

  // ---- blueprint: what Gemini does (the page to send a Gemini-track judge to)
  // Measured on generated sessions and series, 14 November 2026 (docs/face-raw.md, docs/health-data.md).
  const BP_FRAMES = [
    ["Code, fixed rule (in the product)", "121 of 121", "0 of 89", "0 of 121", "20 of 28", "0 of 13", "3 of 23"],
    ["Code, simple rule relative to the person's rest", "121 of 121", "89 of 89", "0 of 210", "28 of 28", "13 of 13", "22 of 63"],
    ["Gemini, as reported", "121 of 121", "89 of 89", "0 of 210", "28 of 28", "13 of 13", "0 of 41"],
    ["Gemini, after code's check", "121 of 121", "89 of 89", "0 of 210", "28 of 28", "13 of 13", "0 of 41"]];
  const BP_DAYS = [
    ["Code, fixed rule (in the product)", "8 of 8", "2 of 8", "10 of 20"],
    ["Gemini, as reported", "8 of 8", "8 of 8", "0 of 16"],
    ["Gemini, after code's check", "8 of 8", "8 of 8", "0 of 16"]];
  function bpGemini(wrap) {
    wrap.appendChild(el("p", { class: "lead" }, "Gemini is the second reader. It reads numbers that plain code has already read with fixed rules, and code then checks every single item Gemini reports. It sees no name, no date, no picture and none of the person's words. What it returns is shown to the clinician beside code's own reading; it never reaches the patient and never decides anything."));
    const W = 960, H = 150, BW = 172, BH = 96, GAP = 25;
    const s = svg("svg", { viewBox: "0 0 " + W + " " + H, class: "bp", role: "img",
      "aria-label": "How a Gemini reading is made: numbers only, an input gate in code, Gemini, an output gate in code, then code checks each item before the clinician sees it." });
    const boxes = [["1", "Numbers only", ["face movement per moment,", "or one row per day;", "rounded, no name or date"], "code"],
      ["2", "Input gate · code", ["a fixed list of allowed", "fields; checked again", "right before sending"], "code"],
      ["3", "Gemini reads", ["a fixed instruction,", "a fixed answer shape,", "nothing else"], "model"],
      ["4", "Output gate · code", ["the exact shape, or the", "whole answer is refused", "and logged"], "code"],
      ["5", "Each item checked", ["same as code · Gemini", "only, in the numbers ·", "not in the numbers: dropped"], "code"]];
    boxes.forEach(([n, t, lines, cls], i) => {
      const x = 4 + i * (BW + GAP), y = 26;
      s.appendChild(svg("rect", { x, y, width: BW, height: BH, rx: 10, class: "bp-box " + cls }));
      s.appendChild(svg("text", { x: x + 12, y: y + 24, class: "bp-t" }, n + "  " + t));
      lines.forEach((l, k) => s.appendChild(svg("text", { x: x + 12, y: y + 46 + k * 17, class: "bp-s" }, l)));
      if (i < boxes.length - 1) {
        const x1 = x + BW, x2 = x + BW + GAP, ym = y + BH / 2;
        s.appendChild(svg("line", { x1, y1: ym, x2: x2 - 2, y2: ym, class: "bp-line" }));
        s.appendChild(svg("polygon", { points: (x2) + "," + ym + " " + (x2 - 9) + "," + (ym - 5) + " " + (x2 - 9) + "," + (ym + 5), class: "bp-head" }));
      }
    });
    wrap.appendChild(el("section", { class: "panel" }, el("figure", { class: "bp-fig" }, s,
      el("figcaption", { class: "muted small" }, "The amber box is Gemini; the others are plain code. The same five steps for every job below. Only with the patient's record allowing outside processing; without it nothing is sent."))));

    const list = (S.list && S.list.patients) || [];
    const pidOf = (label) => { const p = list.find((q) => q.label === label); return p ? p.patient_id : null; };
    const leo = pidOf("Example F-001"), anna = S.me && S.me.demo && S.me.demo.patient_id;
    const go2 = (pid, tab, text) => pid ? el("a", { href: "#/p/" + encodeURIComponent(pid) + "/" + tab }, text) : el("span", { class: "muted" }, text);
    const job = (n, t, sent, back, check, see) => el("div", { class: "row" }, el("div", { class: "top" }, el("span", { class: "chip" }, n), el("span", { class: "t" }, t)),
      el("div", { class: "d" }, el("b", null, "Sent: "), sent, el("br"), el("b", null, "Gemini returns: "), back, el("br"), el("b", null, "Code then: "), check, el("br"), el("b", null, "See it: "), see));
    wrap.appendChild(panel("The four jobs", null, el("div", { class: "rows" },
      job("1", "Reads how a face moved during one short game",
        "about 225 rows, five per second, each with a time and up to 14 numbers (smile, cheeks, blink, brows, gaze, head angle). The phone sent numbers only; a picture never existed on the server.",
        "every smile with its start and end, a blink count, longer stretches such as looking down, and whether a smile followed each pleasant moment.",
        "compares each smile with its own detection on the full 30 rows per second. Our fixed rule only counts a smile above one fixed level. Gemini judges against this person's own resting level, so it also finds faint smiles. Code keeps such a smile only when the rise is really in the numbers, and shows it apart. A smile that is not in the numbers is dropped.",
        [go2(leo, "activity", "Leo Virtanen (generated example) → Activity → Focus game"), ", the panel “Two readers on one session”. In his last session the fixed rule counts no smile and Gemini finds three faint ones."]),
      job("2", "Reads the daily numbers from Apple Health",
        "up to 84 days, one row per day with a day number and the weekday instead of a date: steps, walking speed, sleep, heart-rate variability, and more when a watch sends it.",
        "the stretches where something changed against the weeks before, sudden or as a slow slide, and the person's weekly rhythm (for example always fewer steps on Sundays).",
        "tests each stretch against the same numbers. Our fixed rule flags a day only when it is far outside the person's normal, so it sees sudden drops and mostly misses slow slides. A stretch only Gemini names is kept when the change is in the numbers.",
        [go2(anna, "overview", "Anna Korhonen (example) → Overview"), ", the panel “Two readers on the daily numbers” at the bottom."]),
      job("3", "Compares one session with the same person's earlier ones",
        "the session's numbers (reaction time, errors, the face summary) and the person's own usual values, with no identity.",
        "a few fixed words (for example slower, less expressive, blinking less), each pointing at the numbers it rests on.",
        "recomputes every claim from the numbers and drops the ones they do not support.",
        [go2(anna, "activity", "Anna Korhonen → Activity → Focus game"), ", the column “Model reading”."]),
      job("4", "Gives a second opinion on what the system learned",
        "the lessons code has already accepted, with their evidence rows: rounded values, days counted back from today, a random label used once.",
        "only objections, each one of three codes: weak evidence, contradicts recent days, too broad.",
        "removes a lesson Gemini objects to. Gemini cannot add or change a lesson.",
        [go2(anna, "mind", "Anna Korhonen → Learned"), ", “How it learns”, and the Blueprint section of the same name."]))));

    const th = (t) => ({ t, r: 1 });
    wrap.appendChild(panel("What we measured", null,
      el("p", { class: "small" }, "Nobody can collect real recordings of patients in a weekend, so we did not pretend to. We generated sessions and daily series with events planted at known places, let every reader go through them, and counted. Run on 14 November 2026 through the same gates as real data."),
      el("h3", { class: "fr-h" }, "Face numbers: 40 clean sessions and 10 hard ones (talking, the phone moving, a mouth that rests high)"),
      table(["Reader", th("Clean: strong smiles"), th("Clean: faint smiles"), th("Clean: wrong reports"), th("Hard: strong smiles"), th("Hard: faint smiles"), th("Hard: wrong reports")],
        BP_FRAMES.map((r) => el("tr", null, r.map((v, i) => el("td", { class: i ? "r num" : null }, v)))), null, { plain: true }),
      el("h3", { class: "fr-h" }, "Daily numbers: 24 series of 84 days (8 sudden dips, 8 slow declines, 8 with nothing planted)"),
      table(["Reader", th("Sudden dips found"), th("Slow declines found"), th("Wrong reports")],
        BP_DAYS.map((r) => el("tr", null, r.map((v, i) => el("td", { class: i ? "r num" : null }, v)))), null, { plain: true }),
      el("p", { class: "muted small" }, "Code's ten wrong reports are mostly short pieces of a slow decline that it flagged without seeing the whole. Of 35 planted low weekdays, code and Gemini each named 34, and Gemini named none that was not planted."),
      el("ul", { class: "plain" },
        el("li", null, "This says how the readers handle a known signal. It says nothing about real faces or real lives; the generated data is cleaner than any recording."),
        el("li", null, "Gemini's instruction names talking and a shifting baseline as things that are not smiles, and the hard sessions contain exactly those. The simple code rule was not told. A more careful rule would do better than 22 wrong reports."),
        el("li", null, "The first step of the study we propose is the same count on real recordings, with two people marking the events. If a rule does as well there, the rule is used and Gemini is dropped from that job."))));

    wrap.appendChild(el("div", { class: "grid" },
      panel("How the calls are made", null, el("ul", { class: "plain" },
        el("li", null, "Model: gemini-3.8-flash through the Gemini API, with a response schema, so the answer has a fixed shape."),
        el("li", null, "Asked to think little: a reading takes about 4 seconds instead of about 30, for a fraction of the tokens."),
        el("li", null, "A busy or failing service is tried again after a growing wait, then with a second model. An empty answer is asked again with more thinking, or a larger limit when the model ran out of tokens."),
        el("li", null, "Readings are made in the background and stored. No page waits for Gemini."),
        el("li", null, "Every call is kept for the clinician: open a patient, then Timeline. Each Gemini row shows exactly what was sent and the raw answer."))),
      panel("What Gemini never gets", null, el("ul", { class: "plain" },
        el("li", null, "a name, an id, a date or a clock time"),
        el("li", null, "a picture, a video or the shape of a face"),
        el("li", null, "the person's typed words"),
        el("li", null, "anything at all without the patient's record allowing outside processing")),
        el("p", { class: "muted small" }, "One exception, off unless the clinic turns it on: a chat mode in which Gemini writes Lanvi's short reply to a note that does not ask for help. Then that note is sent, without any name or id, and code checks the reply before it is shown."))));
    wrap.appendChild(panel("Where it is in the code", null, el("p", { class: "small" }, "Public repository: github.com/mathewstars/thejunction (written out, not linked: this page loads and links nothing outside the clinic's server). The instructions Gemini receives: engine/clinic_engine/data/frames_prompt.txt and days_prompt.txt. The gates: engine/clinic_engine/mind/gates.py. The checks of each item: mind/frame_reading.py and mind/day_reading.py. The call with its retries: outreach.py. The generated test sets: frames_reference.py and days_reference.py. Written out for a reader: docs/face-raw.md and docs/health-data.md.")));
  }

  // ---- blueprint: how the system learns, told with one example
  function bpLearning(wrap) {
    wrap.appendChild(el("p", { class: "lead" }, "The system learns one thing only: which of our small offers to show this person first, and at what time of day. It learns it from what the person did with earlier offers and how the days after went. It cannot learn anything else."));
    const cell = (v, cls) => el("td", { class: cls || null }, v);
    const ev = [["3 weeks ago, evening", "Breathe with Lanvi", "did it", "better"], ["3 weeks ago, afternoon", "a short walk", "not today", "–"],
      ["2½ weeks ago, evening", "Breathe with Lanvi", "did it", "better"], ["2½ weeks ago, afternoon", "a short walk", "not today", "–"],
      ["2 weeks ago, evening", "Breathe with Lanvi", "did it", "better"], ["2 weeks ago, afternoon", "a short walk", "not today", "–"]];
    const step = (n, t, ...body) => el("div", { class: "row" }, el("div", { class: "top" }, el("span", { class: "chip" }, n), el("span", { class: "t" }, t)), el("div", { class: "d" }, body));
    wrap.appendChild(panel("One example, start to finish", null, el("div", { class: "rows" },
      step("1", "What happened", "Over three weeks Lanvi made six offers to one person. This is all the system knows about them:",
        table(["When", "Offer", "Answer", "Movement in the days after, against her own normal"], ev.map((r) => el("tr", null, r.map((v) => cell(v)))), null, { plain: true }),
        el("p", { class: "small muted" }, "Code builds this table. It holds no words the person typed.")),
      step("2", "A model proposes a lesson", "The local model (on the clinic's own hardware) gets the table and a list of sentences it may fill in. It proposes two:",
        el("ul", { class: "plain" }, el("li", null, "“Prefer breathing in the evening: done three times, and the days after were better.”"), el("li", null, "“Avoid the short walk in the afternoon: offered three times, not done.”")),
        el("p", { class: "small muted" }, "It can only choose from our six offers, a time of day (morning, afternoon, evening or any) and eight fixed reasons. It cannot write a sentence of its own.")),
      step("3", "Code checks the lesson", "Code counts again, by itself. A lesson is kept only when at least three rows of the table back it, they really say what the lesson claims, and at least six in ten of all rows about that offer agree. Both lessons pass. A lesson that fails is dropped and written to the log with the reason."),
      step("4", "Gemini may object", "Gemini sees the two kept lessons with their rows, without any identity. It can only say “weak evidence”, “contradicts recent days” or “too broad”. An objection removes the lesson. Here it objects to neither."),
      step("5", "What changes for the person", "Our usual order of offers is: breathing, the spark game, a short walk, some daylight, reaching out to someone, the evening check-in. With the two lessons, when an offer is due in the evening breathing stays first, and in the afternoon the short walk moves down the list, so she is offered something else first.",
        el("p", { class: "small muted" }, "That is the whole effect. The words Lanvi says, the alerts to the clinic and what the clinician sees do not change.")),
      step("6", "And if it stops being true", "The check runs again after new answers and once a day. When later rows point the other way, or no fresh rows have backed a lesson for a long time, it is withdrawn. The clinician can also reject a lesson by hand; it does not come back."))));

    const W = 960, H = 318, BW = 262, BH = 88;
    const s = svg("svg", { viewBox: "0 0 " + W + " " + H, class: "bp", role: "img",
      "aria-label": "The same six steps as a loop: the person answers offers, code builds the table, the local model proposes lessons, code checks them, Gemini may object, and kept lessons change the order of the next offers." });
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
    box(X[0], Y[0], "1", "The person answers", "did it, not today, or no answer;", "the phone sends the days after", "code");
    box(X[1], Y[0], "", "Code builds the table", "one row per offer: when, what,", "the answer, the days after", "code");
    box(X[2], Y[0], "2", "Local model proposes", "“prefer” or “avoid” an offer at a time", "of day, pointing at rows", "model");
    box(X[2], Y[1], "3", "Code checks", "counts the rows again; a lesson they", "do not back is dropped", "code");
    box(X[1], Y[1], "4", "Gemini may object", "weak evidence, contradicts recent", "days, too broad", "model");
    box(X[0], Y[1], "5", "Kept lessons", "change the order of our offers,", "nothing else", "code");
    arrow(X[0] + BW, Y[0] + BH / 2, X[1], Y[0] + BH / 2, "", 0, 0);
    arrow(X[1] + BW, Y[0] + BH / 2, X[2], Y[0] + BH / 2, "", 0, 0);
    arrow(X[2] + BW / 2, Y[0] + BH, X[2] + BW / 2, Y[1], "proposals", X[2] + BW / 2 + 10, (Y[0] + BH + Y[1]) / 2 + 4, "start");
    arrow(X[2], Y[1] + BH / 2, X[1] + BW, Y[1] + BH / 2, "kept", (X[1] + BW + X[2]) / 2, Y[1] + BH / 2 - 8);
    arrow(X[1], Y[1] + BH / 2, X[0] + BW, Y[1] + BH / 2, "not objected", (X[0] + BW + X[1]) / 2, Y[1] + BH / 2 - 8);
    arrow(X[0] + BW / 2, Y[1], X[0] + BW / 2, Y[0] + BH, "the next offer", X[0] + BW / 2 + 10, (Y[0] + BH + Y[1]) / 2 + 4, "start");
    wrap.appendChild(el("section", { class: "panel" }, el("figure", { class: "bp-fig" }, s,
      el("figcaption", { class: "muted small" }, "The same steps as a loop. Amber boxes are models; the others are plain code. A model only proposes or objects; code decides."))));
    wrap.appendChild(el("div", { class: "grid" },
      panel("A lesson can", null, el("ul", { class: "plain" }, el("li", null, "move one of our offers up or down in the order"), el("li", null, "apply only at the time of day it was learned for"), el("li", null, "be withdrawn when later answers point the other way"))),
      panel("A lesson cannot", null, el("ul", { class: "plain" }, el("li", null, "add an offer that is not on our list"), el("li", null, "write or change any text the person sees"), el("li", null, "open, raise or close attention, or send an alert"), el("li", null, "override the person's own rules, such as quiet hours")))));
    wrap.appendChild(panel("See it on real runs", null, el("p", { class: "small" }, "Open a patient, then Learned. “How it learns” lists each run with exactly what each model was sent and what it answered, and each lesson with the rows behind it. The Timeline shows the same exchange inside the event that caused it, next to what code kept and dropped.")));
  }

  function viewBlueprint() {
    const wrap = el("div", { class: "stack" });
    const tab = S.bpTab || "research";
    const tabsRow = el("div", { class: "seg", role: "group", "aria-label": "Blueprint sections" }, [["research", "The research"], ["gemini", "What Gemini does"], ["learning", "How it learns"]].map(([k, label]) =>
      el("button", { type: "button", class: "btn btn-small", "aria-pressed": tab === k ? "true" : "false", "data-key": "bp-" + k, on: { click: () => { S.bpTab = k; history.replaceState(null, "", "#/blueprint/" + k); window.scrollTo(0, 0); render(); } } }, label)));
    const title = tab === "research" ? "The research: can a phone notice when someone is getting worse again?" : tab === "gemini" ? "What Gemini does here" : "How the system learns";
    wrap.appendChild(el("div", { class: "head" }, el("h1", null, title)));
    wrap.appendChild(tabsRow);
    if (tab === "research") bpResearch(wrap);
    else if (tab === "gemini") bpGemini(wrap);
    else bpLearning(wrap);
    return wrap;
  }

  // ---- research: how this person's measures moved with the reference
  const R_PATTERN = { consistent_with_worse_state: "Moves as expected when the state is worse", partly_consistent: "Partly as expected",
    no_clear_relation: "No clear relation", opposite_to_expectation: "Opposite to what was expected", insufficient_data: "Not enough data" };
  const R_NEXT = { collect_more_sessions: "Collect more sessions", add_reference_rating: "Add a reference rating", review_tracking_quality: "Review tracking quality",
    discuss_with_patient: "Discuss with the patient", none: "None" };
  const R_STATUS = { insufficient: "too few days", no_variation: "did not vary", is_reference: "is the reference" };
  const SRC = { model: "model", code: "code", code_corrected: "model, corrected by code" };
  function f2(v) { return v === null || v === undefined ? "–" : (v > 0 ? "+" : v < 0 ? "−" : "") + Math.abs(Number(v)).toFixed(2); }
  const REASON = { not_json_object: "the reply was not in the required form", already_asked: "that question was already asked", unknown_evidence: "it pointed at evidence that does not exist",
    no_own_baseline: "there is no own normal to compare with yet", no_face_baseline: "there is no own normal for the face yet", change_does_not_start_there: "the change does not start where it said",
    stronger_than_interval_supports: "the label claimed more than the range supports", strongest_must_be_consistent_rows: "it named a measure that is not as expected", weak_evidence: "the evidence was too thin" };
  function plainReason(code) {
    const parts = String(code || "").split(":");
    const last = parts[parts.length - 1];
    const tail = REASON[last] || words(last).toLowerCase();
    if (parts.length >= 3) return words(parts[1]).toLowerCase() + " " + (parts[0] === "claim_dropped" ? "dropped" : "changed") + ": " + tail;
    return tail;
  }
  function modelName(m) { m = String(m || ""); return /gemini/i.test(m) ? "Gemini" : /stand-in/i.test(m) ? "local model, standing in" : m === "code" || !m ? "code" : "local model"; }
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
    const rows = all.map((x) => {
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
      el("div", { class: "scroll-x" }, table(heads, rows, "samples", { filter: 1 })));
  }
  function closePops() { const ks = Object.keys(S.open).filter((k) => k.indexOf("cav-") === 0 && S.open[k]); ks.forEach((k) => delete S.open[k]); if (ks.length) render(); }
  document.addEventListener("keydown", (ev) => { if (ev.key === "Escape") closePops(); });
  document.addEventListener("click", (ev) => { if (!(ev.target.closest && ev.target.closest("td.cav"))) closePops(); });
  // A section that stays folded until asked for; remembers its state across redraws.
  function fold(key, title, count, body) {
    const dt = el("details", { class: "more panel" }, el("summary", null, title, count !== null && count !== undefined ? el("span", { class: "count" }, count) : null), body);
    if (S.open[key]) dt.open = true;
    dt.addEventListener("toggle", () => { S.open[key] = dt.open; });
    return dt;
  }
  function vizTip(host) {
    const t = el("div", { class: "tip" });
    t.hidden = true;
    host.appendChild(t);
    return {
      show(px, py, nodes) {
        t.replaceChildren.apply(t, nodes); t.hidden = false;
        const w = host.clientWidth;
        t.style.left = Math.round(Math.min(Math.max(4, px + 14), Math.max(4, w - t.offsetWidth - 4))) + "px";
        t.style.top = Math.round(Math.max(0, py)) + "px";
      },
      hide() { t.hidden = true; },
    };
  }
  function fmtMeasure(key, v) {
    if (v === null || v === undefined) return "–";
    if (/_share$/.test(key) || /error_rate$/.test(key)) return Math.round(v * 100) + " %";
    if (/_ms$/.test(key)) return Math.round(v) + " ms";
    if (/steps$/.test(key)) return num(Math.round(v));
    if (/_deg$/.test(key)) return Number(v).toFixed(1) + "°";
    return Number(v).toFixed(2);
  }
  // Which measures stand for the pattern: the best of each kind first, then the next best.
  // What a measure doing "worse" looks like, in words a person would use.
  const WORSE = { "face.smile_time_share": "smiled less", "face.smile_rate_per_min": "smiled less often", "face.smile_intensity": "smiled more faintly",
    "face.eye_smile_share": "had fewer smiles that reached the eyes", "face.smile_response_share": "smiled less at pleasant moments", "face.smile_response_latency_s": "was slower to smile",
    "face.facial_activity": "showed less facial movement", "face.brow_down_share": "drew the brows down more", "face.inner_brow_up_share": "raised the inner brows more",
    "face.blink_duration_ms": "blinked more slowly", "face.look_down_share": "looked down more", "face.head_pitch_deg": "held the head lower", "face.head_movement": "moved the head less",
    "focus.median_reaction_ms": "reacted more slowly", "focus.reaction_spread_ms": "reacted less evenly", "focus.error_rate": "made more errors", "activity.completed_share": "finished fewer activities",
    "checkin.good_things": "named fewer good things", "checkin.plan_done_share": "carried out fewer plans", "daily.steps": "walked less", "daily.walking_speed_m_s": "walked more slowly", "daily.hrv_ms": "had lower heart-rate variability" };
  function joinAnd(list) { return list.length > 1 ? list.slice(0, -1).join(", ") + " and " + list[list.length - 1] : list[0] || ""; }
  function pickMeasures(a) {
    const sr = a.series || {}, rows = a.rows || [];
    const usable = rows.filter((r) => r.status === "tested" && r.expected !== "mixed" && ((sr.measures || {})[r.key] || []).length >= 5);
    // Per kind, the measure research supports best among those that came out as expected (not the
    // largest number: with a dozen ratings the top few are a coin toss). "Every measure" pins them first.
    const SUP = { stronger: 0, moderate: 1, weaker: 2, mixed: 3 };
    const cons = usable.filter((r) => r.agreement === "consistent").sort((x, y) => (SUP[x.support] - SUP[y.support]) || (y.rho - x.rho));
    const pick = [];
    const add = (r) => { if (r && pick.indexOf(r) < 0 && pick.length < 4) pick.push(r); };
    ["face", "activity", "daily"].forEach((g) => add(cons.find((r) => r.group === g)));
    cons.forEach(add);
    if (!pick.length) usable.slice().sort((x, y) => Math.abs(y.rho) - Math.abs(x.rho)).slice(0, 3).forEach(add);
    return pick;
  }
  // Two panels on one time axis. Above: the rating on its own fixed scale, the same on every
  // patient's page. Below: the measures in the person's own spread units, turned so up means
  // worse; grey lines, their average in white. Columns where the rating is at or over the usual
  // cut-off are shaded through both panels.
  function togetherChart(a) {
    const sr = a.series;
    if (!sr || !(sr.reference || []).length) return null;
    const ref = a.reference || {}, pick = pickMeasures(a);
    if (!pick.length) return null;
    const anyGood = pick.some((r) => r.agreement === "consistent");
    const t0 = Date.parse(sr.first_day + "T00:00:00Z");
    const N = Math.max(2, Math.round((Date.parse(sr.last_day + "T00:00:00Z") - t0) / 864e5) + 1);
    const std = (pts, flip) => {
      const v = pts.map((p) => p[1]), m = v.reduce((t, q) => t + q, 0) / v.length;
      const sd = Math.sqrt(v.reduce((t, q) => t + (q - m) * (q - m), 0) / Math.max(1, v.length - 1)) || 1;
      return pts.map((p) => [p[0], ((p[1] - m) / sd) * (flip ? -1 : 1)]);
    };
    const smooth = (pts) => pts.map((p) => { const near = pts.filter((q) => Math.abs(q[0] - p[0]) <= 3); return [p[0], near.reduce((t, q) => t + q[1], 0) / near.length]; });
    const runs = (pts) => { const out = []; let cur = []; pts.forEach((p, i) => { if (i && p[0] - pts[i - 1][0] > 7) { out.push(cur); cur = []; } cur.push(p); }); if (cur.length) out.push(cur); return out; };
    const rp = sr.reference.slice().sort((p, q) => p[0] - q[0]);
    const ms = pick.map((r) => ({ r, pts: smooth(std(sr.measures[r.key], r.expected === "lower")) }));
    const avg = [];
    for (let day = 0; day < N; day += 1) {
      const vs = ms.map((m) => { const p = m.pts.find((q) => q[0] === day); return p ? p[1] : null; }).filter((v) => v !== null);
      if (vs.length) avg.push([day, vs.reduce((t, q) => t + q, 0) / vs.length]);  // of the measures that have a value that day
    }
    const avgS = smooth(avg);
    const isPhq = ref.key === "phq9", CUT = 10;
    const rv = rp.map((p) => p[1]);
    const aLo = isPhq ? 0 : Math.min.apply(null, rv), aHi = isPhq ? Math.max(20, Math.ceil(Math.max.apply(null, rv) / 5) * 5) : Math.max.apply(null, rv);
    const W = 1000, PL = 92, PR = 14, AT = 26, AH = 118, BT = AT + AH + 40, BH = 168, H = BT + BH + 28;
    const zs = avgS.map((p) => p[1]); ms.forEach((m) => m.pts.forEach((p) => zs.push(p[1])));
    const zMax = Math.min(6, Math.max(2.4, Math.max.apply(null, zs) + 0.4)), zMin = Math.max(-6, Math.min(-2.4, Math.min.apply(null, zs) - 0.4));
    const x = (day) => PL + (Math.max(0, Math.min(N - 1, day)) / (N - 1)) * (W - PL - PR);
    const ya = (v) => AT + (1 - (v - aLo) / ((aHi - aLo) || 1)) * AH;
    const yb = (z) => BT + (1 - (Math.max(zMin, Math.min(zMax, z)) - zMin) / (zMax - zMin)) * BH;
    const sv = svg("svg", { viewBox: "0 0 " + W + " " + H, class: "tg", role: "img",
      "aria-label": "Above, the " + (ref.label || ref.key) + " over " + N + " days. Below, on the same time axis, " + pick.map((r) => r.label).join(", ") + " and their average, drawn so that up means worse." });
    // columns where the rating is at or over the cut-off (or, without a cut-off, in its worse half)
    const mid = (Math.min.apply(null, rv) + Math.max.apply(null, rv)) / 2;
    const high = (v) => (isPhq ? v >= CUT : (ref.worse_is === "lower" ? v <= mid : v >= mid) && Math.max.apply(null, rv) > Math.min.apply(null, rv));
    rp.forEach((p, i) => {
      if (!high(p[1])) return;
      const xa = i === 0 ? x(p[0] - 3) : (x(rp[i - 1][0]) + x(p[0])) / 2, xb = i === rp.length - 1 ? x(p[0] + 3) : (x(p[0]) + x(rp[i + 1][0])) / 2;
      sv.appendChild(svg("rect", { x: xa, y: AT, width: Math.max(1, xb - xa), height: BT + BH - AT, class: "tg-band" }));
    });
    // panel A: the rating
    sv.appendChild(svg("text", { x: PL, y: 14, class: "tg-t" }, ref.label || ref.key, svg("tspan", { class: "tg-s" }, isPhq ? "   score, shown 0 to " + aHi + " (the scale goes to 27) · the same on every patient’s page" : "   " + (ref.worse_is === "lower" ? "lower is worse" : "higher is worse"))));
    (isPhq ? [0, 10, 20] : [aLo, aHi]).forEach((g) => {
      if (g > aHi) return;
      sv.appendChild(svg("line", { x1: PL, y1: ya(g), x2: W - PR, y2: ya(g), class: isPhq && g === CUT ? "tg-cut" : "fp-grid" }));
      sv.appendChild(svg("text", { x: PL - 8, y: ya(g) + 4, class: "tg-ax", "text-anchor": "end" }, isPhq && g === CUT ? "cut-off 10" : String(Math.round(g * 10) / 10)));
    });
    sv.appendChild(svg("polyline", { points: rp.map((p) => x(p[0]).toFixed(1) + "," + ya(p[1]).toFixed(1)).join(" "), class: "tg-ref" }));
    let from = rp.length - 1;
    while (from > 0 && rp[from][1] > rp[from - 1][1]) from -= 1;
    const rising = isPhq && from < rp.length - 1 && rp[rp.length - 1][1] >= CUT;
    if (rising) sv.appendChild(svg("polyline", { points: rp.slice(from).map((p) => x(p[0]).toFixed(1) + "," + ya(p[1]).toFixed(1)).join(" "), class: "tg-ref now" }));
    rp.forEach((p, i) => {
      sv.appendChild(svg("circle", { cx: x(p[0]), cy: ya(p[1]), r: 5, class: rising && i === rp.length - 1 ? "tg-refpt now" : "tg-refpt" }));
      const prev = i > 0 ? rp[i - 1][1] : null, next = i < rp.length - 1 ? rp[i + 1][1] : null;
      const peak = (prev === null || p[1] >= prev) && (next === null || p[1] >= next);
      sv.appendChild(svg("text", { x: x(p[0]), y: peak ? ya(p[1]) - 10 : ya(p[1]) + 19, class: "tg-v", "text-anchor": "middle" }, String(Math.round(p[1] * 10) / 10)));
    });
    // panel B: the measures
    sv.appendChild(svg("text", { x: PL, y: BT - 12, class: "tg-t" }, "The measures", svg("tspan", { class: "tg-s" }, "   each in this person’s own spread, turned so that up means worse")));
    [[2, "+2 worse"], [0, "own usual"], [-2, "−2 better"]].forEach(([g, word]) => {
      sv.appendChild(svg("line", { x1: PL, y1: yb(g), x2: W - PR, y2: yb(g), class: g === 0 ? "fp-zero" : "fp-grid" }));
      sv.appendChild(svg("text", { x: PL - 8, y: yb(g) + 4, class: "tg-ax", "text-anchor": "end" }, word));
    });
    const line = (pts, cls) => runs(pts).forEach((run) => { if (run.length > 1) sv.appendChild(svg("polyline", { points: run.map((p) => x(p[0]).toFixed(1) + "," + yb(p[1]).toFixed(1)).join(" "), class: cls })); });
    ms.forEach((m) => line(m.pts, "tg-m"));
    line(avgS, anyGood ? "tg-avg" : "tg-avg dim");
    for (let dday = 0; dday < N - 9; dday += 14) sv.appendChild(svg("text", { x: x(dday), y: H - 8, class: "tg-ax", "text-anchor": dday === 0 ? "start" : "middle" }, dayShort(new Date(t0 + dday * 864e5).toISOString().slice(0, 10))));
    sv.appendChild(svg("text", { x: W - PR, y: H - 8, class: "tg-ax", "text-anchor": "end" }, "today"));
    const cross = svg("line", { x1: 0, y1: AT, x2: 0, y2: BT + BH, class: "tg-cross" });
    cross.setAttribute("visibility", "hidden");
    sv.appendChild(cross);
    const host = el("div", { class: "viz" }, sv);
    const tip = vizTip(host);
    const near = (pts, day, reach) => { let best = null; pts.forEach((p) => { const dd = Math.abs(p[0] - day); if (dd <= reach && (!best || dd < Math.abs(best[0] - day))) best = p; }); return best; };
    sv.addEventListener("mousemove", (ev) => {
      const box = sv.getBoundingClientRect(), vx = ((ev.clientX - box.left) / box.width) * W;
      const day = Math.round(((vx - PL) / (W - PL - PR)) * (N - 1));
      if (day < 0 || day > N - 1) { cross.setAttribute("visibility", "hidden"); tip.hide(); return; }
      cross.setAttribute("x1", x(day)); cross.setAttribute("x2", x(day)); cross.setAttribute("visibility", "visible");
      const lines = [el("div", { class: "tip-h" }, dayShort(new Date(t0 + day * 864e5).toISOString().slice(0, 10)))];
      const rpt = near(rp, day, 4);
      lines.push(el("div", { class: "tip-r" }, el("span", null, ref.label || ref.key), el("b", null, rpt ? String(rpt[1]) : "no rating")));
      ms.forEach((m) => { const p = near(sr.measures[m.r.key], day, 2); lines.push(el("div", { class: "tip-r" }, el("span", null, m.r.label), el("b", null, p ? fmtMeasure(m.r.key, p[1]) : "–"))); });
      const cxp = ev.clientX - box.left;
      tip.show(cxp > box.width / 2 ? cxp - 260 : cxp, (box.height * (BT + 8)) / H, lines);
    });
    sv.addEventListener("mouseleave", () => { cross.setAttribute("visibility", "hidden"); tip.hide(); });
    const said = pick.map((r) => (WORSE[r.key] || r.label.toLowerCase()));
    return el("div", null,
      el("ul", { class: "legend" },
        el("li", null, el("span", { class: "key k-ref" }), (ref.label || ref.key) + " (the number is the score)"),
        el("li", null, el("span", { class: anyGood ? "key k-avg" : "key k-m thick" }), "average of the measures that have a value that day"),
        el("li", null, el("span", { class: "key k-m" }), "each measure (named below)"),
        isPhq && rp.some((p) => p[1] >= CUT) ? el("li", null, el("span", { class: "bandkey amber" }), "weeks at or over the cut-off") : null,
        rising ? el("li", null, el("span", { class: "key k-now" }), "the latest rise") : null),
      host,
      el("p", { class: "muted small" }, "In the lower panel up means worse: " + joinAnd(said.map((t) => "“" + t + "”")) + " all point up. Each grey line is a 7-day average of one measure; a break is a week without it, and the average then rests on the measures that remain." +
        (anyGood ? "" : " None of these came out as expected, so the average is drawn grey too.")));
  }
  // One row per measure, grouped by kind: the estimate and its range on one scale.
  function forestChart(a) {
    const des = a.design || {};
    const tested = (a.rows || []).filter((r) => r.status === "tested");
    if (!tested.length) return null;
    const GROUPS = [["face", "Face"], ["activity", "Activities"], ["daily", "Daily data"]];
    const charted = pickMeasures(a).filter((r) => r.agreement === "consistent");
    const layout = [];
    GROUPS.forEach(([g, name]) => {
      const rs = tested.filter((r) => r.group === g).sort((p, q) => (charted.indexOf(q) >= 0) - (charted.indexOf(p) >= 0) || q.rho - p.rho);
      if (!rs.length) return;
      const openAll = !!S.open["fp-" + g], shown = rs.length > 5 && !openAll ? rs.slice(0, 4) : rs;
      layout.push({ head: name, n: rs.length, cons: rs.filter((r) => r.agreement === "consistent").length, g, more: rs.length - shown.length, canFold: rs.length > 5 });
      shown.forEach((r) => layout.push({ r }));
    });
    const X0 = -0.5;  // the same scale on every patient's page, so two pages can be compared
    const W = 1000, LX = 330, RX = 800, RHt = 26, HH = 34, TOP = 30;
    const H = TOP + layout.reduce((t, it) => t + (it.r ? RHt : HH), 0) + 8;
    const x = (v) => LX + ((Math.max(X0, Math.min(1, v)) - X0) / (1 - X0)) * (RX - LX);
    const sv = svg("svg", { viewBox: "0 0 " + W + " " + H, class: "fp", role: "img", "aria-label": "Each measure’s correlation with the reference and its range, grouped by kind and sorted from strongest." });
    const ticks = [-0.5, 0, 0.5, 1];
    ticks.forEach((g) => {
      sv.appendChild(svg("line", { x1: x(g), y1: TOP - 4, x2: x(g), y2: H - 4, class: g === 0 ? "fp-zero" : "fp-grid" }));
      sv.appendChild(svg("text", { x: x(g), y: TOP - 10, class: "tg-ax", "text-anchor": "middle" }, g === 0 ? "0" : f2(g).replace(".00", "").replace(".50", ".5")));
    });
    sv.appendChild(svg("text", { x: RX, y: 10, class: "tg-ax", "text-anchor": "end" }, "moves as expected when worse →"));
    const host = el("div", { class: "viz" }, sv);
    const tip = vizTip(host);
    let cy = TOP;
    layout.forEach((it) => {
      if (!it.r) {
        const g = svg("g", { class: it.canFold ? "fp-head can" : "fp-head" });
        g.appendChild(svg("rect", { x: 0, y: cy + 4, width: W, height: HH - 6, class: "fp-hit" }));
        g.appendChild(svg("text", { x: 4, y: cy + 24, class: "fp-g" }, it.head, svg("tspan", { class: "tg-s" }, "   " + it.cons + " of " + it.n + " as expected" +
          (it.g === "face" && it.n > 5 ? " · closely related, read them as one signal" : ""))));
        if (it.canFold) {
          g.appendChild(svg("text", { x: W - 4, y: cy + 24, class: "fp-more", "text-anchor": "end" }, it.more ? "show all " + it.n + " ▾" : "show fewer ▴"));
          g.addEventListener("click", () => { S.open["fp-" + it.g] = !S.open["fp-" + it.g]; render(); });
        }
        sv.appendChild(g);
        cy += HH;
        return;
      }
      const r = it.r, my = cy + RHt / 2, ok = r.agreement === "consistent";
      const g = svg("g", { class: "fp-row" });
      g.appendChild(svg("rect", { x: 0, y: cy, width: W, height: RHt, class: "fp-hit" }));
      g.appendChild(svg("text", { x: LX - 14, y: my + 4, class: "fp-l", "text-anchor": "end" }, r.label + (charted.indexOf(r) >= 0 ? "  ◆" : "")));
      g.appendChild(svg("line", { x1: x(r.ci_low), y1: my, x2: x(r.ci_high), y2: my, class: ok ? "fp-ci" : "fp-ci dim" }));
      g.appendChild(svg("circle", { cx: x(r.rho), cy: my, r: 5.5, class: "fp-pt " + (ok ? "k-cons" : r.agreement === "opposite" ? "k-opp" : "k-inc") }));
      g.appendChild(svg("text", { x: RX + 18, y: my + 4, class: ok ? "fp-v" : "fp-v dim" }, f2(r.rho)));
      g.appendChild(svg("text", { x: W - 4, y: my + 4, class: "tg-ax", "text-anchor": "end" }, f2(r.ci_low) + " to " + f2(r.ci_high) + " · n " + r.n));
      g.addEventListener("mousemove", (ev) => {
        const box = sv.getBoundingClientRect();
        tip.show(ev.clientX - box.left, ev.clientY - box.top + 14, [
          el("div", { class: "tip-h" }, r.label),
          el("div", { class: "tip-p" }, r.why),
          el("div", { class: "tip-r" }, el("span", null, "expected when worse"), el("b", null, r.expected)),
          el("div", { class: "tip-r" }, el("span", null, "correlation and range"), el("b", null, f2(r.rho) + " [" + f2(r.ci_low) + ", " + f2(r.ci_high) + "]")),
          el("div", { class: "tip-r" }, el("span", null, (des.unit === "rating" ? "ratings" : "days") + " · p corrected"), el("b", null, r.n + " · " + (r.p_adj < 0.001 ? "< 0.001" : Number(r.p_adj).toFixed(2)))),
          el("div", { class: "tip-r" }, el("span", null, "judgement"), el("b", null, ok ? "as expected" : words(r.agreement).toLowerCase())),
          (r.caveats || []).length ? el("div", { class: "tip-p" }, "Caveats: " + r.caveats.map((c) => words(c.code).toLowerCase()).join(", ")) : null].filter(Boolean));
      });
      g.addEventListener("mouseleave", () => tip.hide());
      sv.appendChild(g);
      cy += RHt;
    });
    return host;
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
        el("button", { type: "button", class: "pop-x", "aria-label": "Close", on: { click: () => { delete S.open[key]; render(); } } }, "×"),
        el("ul", { class: "plain" }, cs.map((c) => el("li", null, c.text, c.by === "code" ? el("span", { class: "muted" }, " (added by code)") : null))),
        el("div", { class: "muted small" }, cs.every((c) => c.by === "model") ? "All named by the model." : cs.every((c) => c.by === "code") ? "All added by code." : "Named by the model unless marked.")) : null);
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
    const cor = a.corrections || [], notes = a.data_notes || [];
    const refName = ref.label || ref.key;
    const refShort = String(refName).replace(/ total$/i, "");
    const unitWord = des.unit === "rating" ? "ratings" : "days";
    const consRows = (a.rows || []).filter((r) => r.agreement === "consistent");
    const kindsN = ["face", "activity", "daily"].filter((g) => consRows.some((r) => r.group === g)).length;
    const who = String(d.display_name || d.label).split(" ")[0];
    const picked = pickMeasures(a);
    const refVals = ((a.series || {}).reference || []).map((p) => p[1]);
    const lo = refVals.length ? Math.min.apply(null, refVals) : null, hi = refVals.length ? Math.max.apply(null, refVals) : null;
    const did = picked.filter((r) => r.agreement === "consistent").slice(0, 3).map((r) => WORSE[r.key] || r.label.toLowerCase());
    const good = o.pattern === "consistent_with_worse_state" || o.pattern === "partly_consistent";
    const flat = lo !== null && ref.key === "phq9" && hi - lo < 5;
    const headline = flat ? who + "’s " + refShort + " stayed between " + lo + " and " + hi + ". That is too little change to tell whether anything moves with it."
      : good && did.length && lo !== null ? "When " + who + "’s " + refShort + " was higher (it moved between " + lo + " and " + hi + "), " + who + " " + joinAnd(did) + "."
      : o.pattern === "opposite_to_expectation" ? who + "’s measures moved against what was expected."
      : o.pattern === "no_clear_relation" ? who + "’s measures did not clearly move with the " + refShort + "."
      : "Not enough data yet to say whether " + who + "’s measures move with the " + refShort + ".";
    wrap.appendChild(el("section", { class: "panel hero" },
      el("p", { class: "hero-k" }, "What the data shows"),
      el("p", { class: "hero-t" }, headline),
      el("div", { class: "hero-facts" },
        good && !flat ? el("span", { class: "chip" }, kindsN + (kindsN === 1 ? " kind" : " kinds") + " of measure agree: " + ["face", "activity", "daily"].filter((g) => consRows.some((r) => r.group === g)).map((g) => ({ face: "face", activity: "activities", daily: "daily movement" })[g]).join(", ")) : null,
        el("span", { class: "chip" }, (des.observations || des.days) + " " + unitWord + " over " + des.days + " days"),
        el("span", { class: "chip" }, words(o.confidence).toLowerCase() + " confidence" + (o.confidence !== "high" ? ": " + (des.observations || des.days) + " " + unitWord + ", one person" : "")),
        d.example ? el("span", { class: "chip tag" }, "example data, not a finding") : null)));
    const together = togetherChart(a);
    if (together) wrap.appendChild(el("section", { class: "panel" }, el("h2", null, (good && !flat ? "Moving together over " : refShort + " and the closest measures over ") + Math.round(des.days / 7) + " weeks"),
      together));
    else if (!a.series) wrap.appendChild(empty("Select “Recalculate” to draw the charts."));
    const fp = forestChart(a);
    if (fp) wrap.appendChild(el("section", { class: "panel" }, el("h2", null, "Every measure", el("span", { class: "count" }, des.rows_tested)),
      el("p", { class: "muted small" }, "How closely each measure followed the " + refName + " across " + (des.observations || "") + " " + unitWord + ". Further right: it moved the way research leads us to expect when symptoms are worse. The bar is the range the true value plausibly lies in; a bar that reaches zero settles nothing. ◆ marks the measures in the chart above; they come first in their group, the rest follow by size."),
      fp,
      el("ul", { class: "legend" }, el("li", null, el("span", { class: "dotk k-cons" }), "as expected: range clear of zero and corrected p ≤ 0.10"), el("li", null, el("span", { class: "dotk k-inc" }), "inconclusive"),
        (a.rows || []).some((r) => r.agreement === "opposite") ? el("li", null, el("span", { class: "dotk k-opp" }), "opposite") : null)));
    const tablesBox = el("div", { class: "stack" });
    const strongest = new Set(o.strongest || []);
    const GROUP = { face: "Face", activity: "Activities", daily: "Daily data" };
    ["face", "activity", "daily"].forEach((g) => {
      const rows = (a.rows || []).filter((r) => r.group === g);
      if (!rows.length) return;
      tablesBox.appendChild(panel(GROUP[g], rows.length, table(
        ["Measure", "Expected when worse", { t: des.unit === "rating" ? "Ratings" : "Days", r: 1 }, "Opposite ← rho → as expected", { t: "p adj.", r: 1 }, "Judgement", "Caveats"],
        rows.map((r) => {
          const tested = r.status === "tested";
          return el("tr", { class: strongest.has(r.key) ? "changed" : "" },
            el("td", null, r.label, el("span", { class: "sub" }, r.why)),
            el("td", null, r.expected, el("span", { class: "sub" }, r.support + " support")),
            el("td", { class: "r num" }, r.n),
            el("td", null, tested ? el("div", { class: "rhocell" }, rhoBar(r), el("span", { class: "num small" }, f2(r.rho) + " [" + f2(r.ci_low) + ", " + f2(r.ci_high) + "]")) : el("span", { class: "muted" }, R_STATUS[r.status] || words(r.status))),
            el("td", { class: "r num" }, tested && r.p_adj !== null ? (r.p_adj < 0.001 ? "< 0.001" : Number(r.p_adj).toFixed(3)) : "–"),
            el("td", null, tested ? [el("span", { class: "chip " + (r.agreement === "consistent" ? "good" : r.agreement === "opposite" ? "bad" : "") }, r.agreement === "consistent" ? "as expected" : words(r.agreement).toLowerCase()),
              r.agreement_source === "code_corrected" ? el("span", { class: "sub" }, "set by code") : null] : "–"),
            caveatCell(r));
        }), "assoc", { id: "assoc-" + g, filter: 5 })));
    });
    wrap.appendChild(fold("r-tables", "The same numbers as tables", des.rows_tested, tablesBox));
    wrap.appendChild(fold("r-samples", "Sessions collected from the phone", null, samplesPanel(d)));
    const labelOf = {}; (a.rows || []).forEach((r) => { labelOf[r.key] = r.label; });
    wrap.appendChild(fold("r-how", "How this was judged, and what limits it", null, el("div", { class: "stack" },
      el("ul", { class: "plain" },
        el("li", null, "One observation is one " + (des.unit === "rating" ? "rating: each measure is averaged over the week up to the rating day. Days between ratings are not counted as separate observations." : "day. Days are not independent of each other, so the ranges are descriptive.")),
        el("li", null, "Each measure gets a rank correlation with the " + refName + ", a 95 % range from resampling, and a p-value corrected for the number of measures tested. All of that is done by code."),
        el("li", null, a.appraised_by === "model" ? "The " + modelName((a.inputs || {}).model) + " read only that table of statistics and judged it. A model may propose; code holds every label to what the range supports. Here code lowered " + cor.filter((c) => c.field === "strength").length + " strength labels and changed " + cor.filter((c) => c.field !== "strength").length + " other judgements." : "No model took part; the judgement is code’s own."),
        el("li", null, "“As expected” needs a range clear of zero and a corrected p-value of at most 0.10. That is a lenient bar, chosen for a first look at feasibility, not for a claim."),
        el("li", null, "Ratings a week apart are not independent of each other, so even these ranges are probably too narrow."),
        el("li", null, "Most plausible other explanation named: " + (o.main_alternative_text || words(o.main_alternative))),
        notes.map((n) => el("li", null, n.text)),
        a.hypotheses_reviewed_by_clinician ? null : el("li", null, "The list of expected directions has not yet been reviewed by a clinician.")),
      cor.length ? table(["Where", "Field", "Model said", "Code set", "Why"],
        cor.map((c) => el("tr", null, el("td", null, c.where === "row" ? labelOf[c.key] || c.key : "overall"), el("td", null, words(c.field)),
          el("td", null, c.model === null || c.model === undefined ? "–" : words(String(c.model)).toLowerCase()), el("td", null, c.code === null || c.code === undefined ? "–" : words(String(c.code)).toLowerCase()),
          el("td", null, words(c.reason).toLowerCase()))), null, { filter: 1 }) : null)));
    return wrap;
  }
  function tabLog(d) {
    const wrap = el("div", { class: "stack" });
    const ref = d.refusal_log || [];
    // The same refusal many times is one line with a count.
    const groups = {};
    ref.forEach((r) => { const k = ((r.detail || {}).task || r.action || "") + "|" + (r.reason || r.code || ""); (groups[k] = groups[k] || { r, n: 0, last: r.at }).n += 1; if (r.at > groups[k].last) groups[k].last = r.at; });
    const gl = Object.keys(groups).map((k) => groups[k]).sort((x, y) => y.n - x.n);
    wrap.appendChild(panel("What code refused or changed in a model’s answer", gl.length || "", ref.length ? table(["Step", "What happened", { t: "Times", r: 1 }, "Last"],
      gl.map((g) => el("tr", null, el("td", null, TASK[(g.r.detail || {}).task] || words((g.r.detail || {}).task || g.r.action || "")),
        el("td", null, plainReason(g.r.reason || g.r.code)), el("td", { class: "r num" }, g.n), el("td", { class: "num" }, stamp(g.last)))), null, { filter: 0 }) : empty("No refusals.")));
    const nl = d.notify_log || [];
    const kindOf = {}; (d.attention_items || []).forEach((i) => { kindOf[i.id] = kind(i.kind); });
    wrap.appendChild(panel("Alerts to the clinic", nl.length || "", nl.length ? table(["When", "Level", "Result", "Because of"],
      nl.map((n) => el("tr", null, el("td", { class: "num" }, stamp(n.at)), el("td", null, levelChip((n.detail || {}).level) || "–"),
        el("td", null, n.outcome === "ok" ? "Sent" : "Not sent: " + words(n.reason || "").toLowerCase()), el("td", null, kindOf[(n.detail || {}).attention_id] || el("span", { class: "muted" }, "an item since closed"))))) : empty("No alerts.")));
    const notes = d.notes || [];
    wrap.appendChild(panel("Notes from the patient", notes.length || "", notes.length ? table(["When", "Mood", "Asked for help", "Text"],
      notes.map((n) => { const c = n.classification || n.labels || n; return el("tr", null, el("td", { class: "num" }, stamp(n.at || n.created_at)),
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
  window.addEventListener("hashchange", () => { window.scrollTo(0, 0); onRoute(); });
  S.timer = setInterval(() => { if (S.token && !document.hidden) refresh(); }, 60000);
  onRoute();
})();
