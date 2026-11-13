// Clinician page. Vanilla JS, no build step, no outside resources.
// Rules: every value from the API is put on the page with textContent or
// setAttribute, never parsed as HTML. The session token lives in memory and
// in sessionStorage only.
"use strict";

(function () {
  const SVG_NS = "http://www.w3.org/2000/svg";
  const TOKEN_KEY = "clinic_session_token";

  const state = {
    token: null,
    me: null,
    route: { name: "list" },
    patient: null, // last loaded patient detail
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
    for (const [k, v] of Object.entries(attrs)) {
      if (v === null || v === undefined || v === false) continue;
      if (k.startsWith("on")) throw new Error("use addEventListener");
      node.setAttribute(k, v === true ? "" : String(v));
    }
  }

  function append(node, children) {
    for (const c of children.flat()) {
      if (c === null || c === undefined || c === false) continue;
      node.appendChild(typeof c === "string" || typeof c === "number"
        ? document.createTextNode(String(c)) : c);
    }
  }

  function clear(node) { node.replaceChildren(); }

  function words(code) {
    return code === null || code === undefined ? "" : String(code).replace(/_/g, " ");
  }

  function fmtTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d.getTime())) return String(iso);
    return d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  }

  function fmtNum(v, digits) {
    if (v === null || v === undefined || v === "") return "none";
    if (typeof v === "number") return v.toFixed(digits === undefined ? 2 : digits);
    return String(v);
  }

  function valueText(v) {
    if (v === null || v === undefined) return "none";
    if (typeof v === "object") return JSON.stringify(v);
    return String(v);
  }

  function exampleTag(rec) {
    return rec && rec.example ? el("span", { class: "tag example", title: "Generated example data, not a real person" }, "example data") : null;
  }

  function draftTag() {
    return el("span", { class: "tag draft" }, "draft wording, not reviewed by a clinician");
  }

  function flash(msg) {
    const f = $("flash");
    f.textContent = msg || "";
    f.hidden = !msg;
  }

  // ---- token storage ------------------------------------------------------------------

  function saveToken(t) {
    state.token = t;
    try {
      if (t) sessionStorage.setItem(TOKEN_KEY, t); else sessionStorage.removeItem(TOKEN_KEY);
    } catch (e) { /* storage blocked: memory only */ }
  }

  function loadToken() {
    try { return sessionStorage.getItem(TOKEN_KEY); } catch (e) { return null; }
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
        logout("Your session ended. Please log in again.");
      }
      throw new ApiFailure(res.status, err.code || "error", err.message || ("HTTP " + res.status));
    }
    return data;
  }

  // ---- labels -------------------------------------------------------------------------

  const STATUS = {
    outside: { word: "Outside own normal", shape: "triangle" },
    no_data: { word: "No data", shape: "dashed-circle" },
    no_baseline: { word: "Learning own normal", shape: "square" },
    within: { word: "Within own normal", shape: "dot" },
  };
  const STATUS_ORDER = { outside: 0, no_data: 1, no_baseline: 2, within: 3 };
  const LEVEL_ORDER = { urgent: 0, attention: 1, watch: 2 };
  const LEVEL_WORD = { urgent: "Needs review today", attention: "Attention", watch: "Watch" };

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

  const METRIC_WORD = {
    steps: "Steps", walking_speed_m_s: "Walking speed", hrv_ms: "Heart-rate variability",
    sleep_h: "Sleep hours",
  };

  function statusIcon(status) {
    const shape = (STATUS[status] || {}).shape;
    const s = svg("svg", { viewBox: "0 0 16 16", "aria-hidden": "true", focusable: "false" });
    if (shape === "triangle") s.appendChild(svg("path", { class: "shape", d: "M2 3 L14 3 L8 14 Z" }));
    else if (shape === "dashed-circle") s.appendChild(svg("circle", { class: "shape hollow dashed", cx: 8, cy: 8, r: 6 }));
    else if (shape === "square") s.appendChild(svg("rect", { class: "shape hollow", x: 2.5, y: 2.5, width: 11, height: 11 }));
    else s.appendChild(svg("circle", { class: "shape", cx: 8, cy: 8, r: 4 }));
    return s;
  }

  function statusBadge(status) {
    const info = STATUS[status] || { word: words(status) };
    return el("span", { class: "status status-" + status }, statusIcon(status), info.word);
  }

  function levelTag(level) {
    if (!level) return null;
    return el("span", { class: "tag level-" + level }, LEVEL_WORD[level] || words(level));
  }

  // ---- views --------------------------------------------------------------------------

  const VIEWS = ["view-login", "view-list", "view-patient", "view-round"];

  function show(id) {
    for (const v of VIEWS) $(v).hidden = v !== id;
    $("top-nav").hidden = id === "view-login";
    updateDemoPanel(id);
  }

  function setProduct(name) {
    if (!name) return;
    $("product-name").textContent = name;
    document.title = name + " clinician page";
  }

  // ---- login --------------------------------------------------------------------------

  async function onLogin(ev) {
    ev.preventDefault();
    const user = $("login-user").value.trim();
    const pass = $("login-pass").value;
    const errBox = $("login-error");
    errBox.hidden = true;
    if (!user || !pass) {
      errBox.textContent = "Enter a username and a password.";
      errBox.hidden = false;
      return;
    }
    const btn = ev.target.querySelector("button[type=submit]");
    btn.disabled = true;
    try {
      const out = await api("POST", "/v1/clinic/login", { username: user, password: pass });
      saveToken(out.session_token);
      $("login-pass").value = "";
      await afterLogin();
    } catch (e) {
      errBox.textContent = e.status === 429 ? "Too many tries. Wait a minute and try again."
        : e.status === 401 ? "Wrong username or password." : "Login failed: " + e.message;
      errBox.hidden = false;
    } finally {
      btn.disabled = false;
    }
  }

  async function afterLogin() {
    state.me = await api("GET", "/v1/clinic/me");
    setProduct(state.me.product_name);
    $("clinic-name").textContent = state.me.clinic_name || "";
    if (!location.hash || location.hash === "#/login") location.hash = "#/patients";
    else route();
  }

  function logout(message) {
    saveToken(null);
    state.me = null;
    state.patient = null;
    $("clinic-name").textContent = "";
    show("view-login");
    flash(message || "");
    $("login-user").focus();
  }

  // ---- patient list -------------------------------------------------------------------

  function renderLegend() {
    const lg = $("legend");
    clear(lg);
    for (const s of ["outside", "no_data", "no_baseline", "within"]) lg.appendChild(statusBadge(s));
  }

  async function loadList() {
    show("view-list");
    const list = $("patient-list");
    clear(list);
    list.appendChild(el("li", { class: "muted" }, "Loading..."));
    let data;
    try { data = await api("GET", "/v1/clinic/patients"); } catch (e) {
      clear(list);
      list.appendChild(el("li", { class: "error" }, "Could not load patients: " + e.message));
      return;
    }
    const lines = data.patients.slice().sort((a, b) =>
      (LEVEL_ORDER[a.level] ?? 3) - (LEVEL_ORDER[b.level] ?? 3)
      || (STATUS_ORDER[a.status] ?? 4) - (STATUS_ORDER[b.status] ?? 4)
      || String(a.label).localeCompare(String(b.label)));
    clear(list);
    if (!lines.length) list.appendChild(el("li", { class: "muted" }, "No patients in this clinic yet."));
    for (const p of lines) list.appendChild(patientRow(p));
  }

  function patientRow(p) {
    const att = el("div", { class: "att" });
    if (!p.attention.length) att.appendChild(el("span", { class: "muted" }, "No held items"));
    for (const a of p.attention) {
      att.appendChild(el("span", null, levelTag(a.level), " ", KIND_WORD[a.kind] || words(a.kind),
        el("span", { class: "muted" }, " since " + a.since)));
    }
    const link = el("a", { class: "row", href: "#/patient/" + encodeURIComponent(p.patient_id) },
      el("div", null, statusBadge(p.status)),
      el("div", null,
        el("div", null, el("span", { class: "label" }, p.label), " ", exampleTag(p)),
        el("div", { class: "small" }, p.summary)),
      att,
      el("div", { class: "last" }, "Last data day", el("br"), p.last_data_day || "none yet"));
    return el("li", { class: "is-" + p.status }, link);
  }

  // ---- patient detail -----------------------------------------------------------------

  async function loadPatient(pid) {
    const root = $("view-patient");
    show("view-patient");
    clear(root);
    root.appendChild(el("p", { class: "muted" }, "Loading..."));
    let d;
    try { d = await api("GET", "/v1/clinic/patients/" + encodeURIComponent(pid)); } catch (e) {
      clear(root);
      root.appendChild(el("p", null, el("a", { href: "#/patients" }, "Back to patients")));
      root.appendChild(el("p", { class: "error" }, e.status === 404 ? "Patient not found." : "Could not load: " + e.message));
      return;
    }
    state.patient = d;
    updateDemoPanel("view-patient");
    clear(root);
    root.appendChild(el("p", null, el("a", { href: "#/patients" }, "Back to patients")));
    root.appendChild(patientHeader(d));
    root.appendChild(attentionSection(d));
    root.appendChild(progressSection(d));
    root.appendChild(roundsSection(d));
    root.appendChild(suggestionsSection(d));
    root.appendChild(lessonsSection(d));
    root.appendChild(notesSection(d));
    root.appendChild(refusalSection(d));
  }

  function fact(label, value) {
    return el("div", null, el("dt", null, label), el("dd", null, value));
  }

  function patientHeader(d) {
    return el("div", { class: "card" },
      el("div", { class: "head-row" },
        el("h1", null, d.label, " ", exampleTag(d)),
        el("div", null, statusBadge(d.status), " ", levelTag(d.level))),
      el("p", null, d.summary),
      el("dl", { class: "facts" },
        fact("Last data day", d.last_data_day || "none yet"),
        fact("Note text shared", d.share_notes ? "yes" : "no (classification only)"),
        fact("Outside processing allowed", d.allow_outside_processing ? "yes" : "no"),
        fact("Note word list", d.draft_wording.note_lexicon_reviewed_by_clinician ? "reviewed" : "draft, not reviewed"),
        fact("Help screen wording", d.draft_wording.help_block_reviewed_by_clinician ? "reviewed" : "draft, not reviewed")));
  }

  function attentionSection(d) {
    const sec = el("section", { "aria-labelledby": "h-att" }, el("h2", { id: "h-att" }, "Attention"));
    const items = d.attention_items.slice().sort((a, b) =>
      (a.state === "open" ? 0 : 1) - (b.state === "open" ? 0 : 1)
      || (LEVEL_ORDER[a.level] ?? 3) - (LEVEL_ORDER[b.level] ?? 3));
    if (!items.length) { sec.appendChild(el("p", { class: "muted" }, "No attention items.")); return sec; }
    const ul = el("ul", { class: "items" });
    for (const i of items) {
      const open = i.state === "open";
      const detail = Object.entries(i.detail || {}).map(([k, v]) => words(k) + ": " + valueText(v)).join(", ");
      const li = el("li", { class: open ? "open" : "closed" },
        el("div", { class: "item-head" },
          el("div", null, levelTag(i.level), " ", el("strong", null, KIND_WORD[i.kind] || words(i.kind)),
            " ", el("span", { class: "muted" }, open ? "held since " + i.since : "closed " + fmtTime(i.closed_at))),
          open ? ackButton(i) : el("span", { class: "muted small" }, "closed: " + words(i.close_reason))),
        el("div", { class: "small" }, "Reason: " + words(i.reason) + (detail ? " (" + detail + ")" : "")
          + (i.peak_level && i.peak_level !== i.level ? ". Highest level: " + words(i.peak_level) : "")),
        historyList(i.history));
      ul.appendChild(li);
    }
    sec.appendChild(ul);
    const ep = d.progress.episodes;
    if (ep.length) {
      sec.appendChild(el("h3", null, "Episodes"));
      sec.appendChild(table(["Kind", "Start", "End", "Highest level", "How it ended"],
        ep.map((e) => [KIND_WORD[e.kind] || words(e.kind), e.start, e.end || "still held",
          words(e.peak_level), words(e.end_reason) || ""])));
    }
    return sec;
  }

  function historyList(history) {
    if (!history || !history.length) return null;
    const det = el("details", null, el("summary", { class: "small" }, "History (" + history.length + ")"));
    const ul = el("ul", { class: "small" });
    for (const h of history) ul.appendChild(el("li", null, fmtTime(h.at) + ": " + words(h.event) + (h.level ? " (" + words(h.level) + ")" : "")));
    det.appendChild(ul);
    return det;
  }

  function ackButton(item) {
    const b = el("button", { type: "button", class: "secondary" }, "Acknowledge");
    b.setAttribute("aria-label", "Acknowledge: " + (KIND_WORD[item.kind] || words(item.kind)));
    b.addEventListener("click", async () => {
      b.disabled = true;
      try {
        await api("POST", "/v1/clinic/attention/" + encodeURIComponent(item.id) + "/ack");
        flash("Acknowledged. The same evidence will not reopen it; new evidence will.");
        await loadPatient(state.patient.patient_id);
      } catch (e) {
        flash("Could not acknowledge: " + e.message);
        b.disabled = false;
      }
    });
    return b;
  }

  // ---- progress charts ----------------------------------------------------------------

  const Z_MIN = -4, Z_MAX = 4;

  function progressSection(d) {
    const pr = d.progress;
    const band = pr.band || { low_z: -1.5, high_z: 1.5 };
    const sec = el("section", { "aria-labelledby": "h-prog" }, el("h2", { id: "h-prog" }, "Progress"));
    const anyExample = pr.series.some((s) => s.example);
    sec.appendChild(el("p", { class: "muted small" },
      "Daily deviation from own normal (robust z). The shaded band, " + band.low_z + " to " + band.high_z +
      ", is within own normal. Downward triangles mark days clearly below. Gaps are days without data. ",
      anyExample ? el("span", { class: "tag example" }, "example data") : null));
    const charts = el("div", { class: "charts" });
    charts.appendChild(lineChart("Movement (steps and walking speed)", pr.series.map((s) => ({ date: s.date, v: s.movement_z })), band));
    const metrics = [];
    for (const s of pr.series) for (const k of Object.keys(s.z || {})) if (!metrics.includes(k)) metrics.push(k);
    for (const m of metrics) {
      charts.appendChild(lineChart(METRIC_WORD[m] || words(m),
        pr.series.map((s) => ({ date: s.date, v: s.z && s.z[m] !== undefined ? s.z[m] : null })), band));
    }
    sec.appendChild(charts);
    sec.appendChild(el("h3", null, "Weekly summary"));
    sec.appendChild(weeklyChart(pr.weekly, band));
    sec.appendChild(table(["Week from", "Mean movement z", "Days with data", "Days missing"],
      pr.weekly.map((w) => [w.week_start, fmtNum(w.mean_movement_z), w.days_with_data, w.days_missing])));
    sec.appendChild(el("h3", null, "What was offered and what followed"));
    const acts = Object.entries(pr.actions).filter(([, a]) => a.offered > 0);
    if (!acts.length) sec.appendChild(el("p", { class: "muted" }, "Nothing offered yet."));
    else {
      sec.appendChild(table(["Action", "Offered", "Done", "Not today", "Something else", "No answer", "Open", "Better / same / worse after", "Mean change"],
        acts.map(([k, a]) => [words(k), a.offered, a.done, a.not_today, a.something_else, a.no_answer, a.open,
          a.outcomes.improved + " / " + a.outcomes.same + " / " + a.outcomes.worse, fmtNum(a.mean_outcome_change)])));
      const measure = acts[0][1].outcome_measure;
      if (measure) sec.appendChild(el("p", { class: "muted small" }, "Change measured as " + measure + "."));
    }
    return sec;
  }

  function lineChart(title, points, band) {
    const W = 640, H = 180, L = 40, R = 10, T = 10, B = 26;
    const n = points.length;
    const x = (i) => L + (n <= 1 ? 0 : (i * (W - L - R)) / (n - 1));
    const y = (v) => T + ((Z_MAX - Math.max(Z_MIN, Math.min(Z_MAX, v))) * (H - T - B)) / (Z_MAX - Z_MIN);
    const valid = points.filter((p) => p.v !== null && p.v !== undefined);
    const lows = valid.filter((p) => p.v <= band.low_z).length;
    const label = title + ": " + valid.length + " days with data, " + lows + " clearly below own normal.";
    const s = svg("svg", { class: "chart", viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": label });
    s.appendChild(svg("title", null, label));
    s.appendChild(svg("rect", { class: "band", x: L, y: y(band.high_z), width: W - L - R, height: y(band.low_z) - y(band.high_z) }));
    for (const t of [Z_MAX, band.high_z, 0, band.low_z, Z_MIN]) {
      s.appendChild(svg("line", { class: t === 0 ? "zero" : "grid", x1: L, x2: W - R, y1: y(t), y2: y(t) }));
      s.appendChild(svg("text", { x: L - 4, y: y(t) + 4, "text-anchor": "end" }, (t > 0 ? "+" : "") + t));
    }
    // Line segments, broken at missing days.
    let seg = [];
    const flush = () => {
      if (seg.length > 1) s.appendChild(svg("polyline", { class: "line", points: seg.join(" ") }));
      seg = [];
    };
    points.forEach((p, i) => {
      if (p.v === null || p.v === undefined) { flush(); return; }
      seg.push(x(i).toFixed(1) + "," + y(p.v).toFixed(1));
    });
    flush();
    points.forEach((p, i) => {
      if (p.v === null || p.v === undefined) return;
      const cx = x(i), cy = y(p.v);
      const tip = p.date + ": z " + p.v.toFixed(2) + (p.v <= band.low_z ? " (clearly below)" : "");
      const mark = p.v <= band.low_z
        ? svg("path", { class: "dot-low", d: "M" + (cx - 5) + " " + (cy - 4) + " L" + (cx + 5) + " " + (cy - 4) + " L" + cx + " " + (cy + 5) + " Z" })
        : svg("circle", { class: "dot", cx: cx, cy: cy, r: 2.5 });
      mark.appendChild(svg("title", null, tip));
      s.appendChild(mark);
    });
    if (n) {
      const idx = [...new Set([0, Math.floor((n - 1) / 2), n - 1])];
      for (const i of idx) {
        s.appendChild(svg("text", { x: x(i), y: H - 8, "text-anchor": i === 0 ? "start" : i === n - 1 ? "end" : "middle" }, points[i].date));
      }
    }
    if (!valid.length) s.appendChild(svg("text", { x: W / 2, y: H / 2, "text-anchor": "middle" }, "No values yet (still learning own normal)"));
    return el("figure", null, el("figcaption", null, title), s);
  }

  function weeklyChart(weeks, band) {
    const W = 640, H = 190, L = 40, R = 10, T = 10, B = 40;
    const n = weeks.length || 1;
    const slot = (W - L - R) / n;
    const y = (v) => T + ((Z_MAX - Math.max(Z_MIN, Math.min(Z_MAX, v))) * (H - T - B)) / (Z_MAX - Z_MIN);
    const label = "Weekly mean movement z for the last " + weeks.length + " weeks.";
    const s = svg("svg", { class: "chart", viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": label });
    s.appendChild(svg("title", null, label));
    s.appendChild(svg("rect", { class: "band", x: L, y: y(band.high_z), width: W - L - R, height: y(band.low_z) - y(band.high_z) }));
    for (const t of [Z_MAX, 0, band.low_z, Z_MIN]) {
      s.appendChild(svg("line", { class: t === 0 ? "zero" : "grid", x1: L, x2: W - R, y1: y(t), y2: y(t) }));
      s.appendChild(svg("text", { x: L - 4, y: y(t) + 4, "text-anchor": "end" }, (t > 0 ? "+" : "") + t));
    }
    weeks.forEach((w, i) => {
      const cx = L + slot * i + slot / 2;
      const bw = Math.min(48, slot * 0.6);
      if (w.mean_movement_z !== null && w.mean_movement_z !== undefined) {
        const v = w.mean_movement_z;
        const top = Math.min(y(0), y(v)), h = Math.max(1, Math.abs(y(v) - y(0)));
        const bar = svg("rect", { class: v <= band.low_z ? "bar-low" : "bar", x: cx - bw / 2, y: top, width: bw, height: h });
        bar.appendChild(svg("title", null, "Week from " + w.week_start + ": " + v.toFixed(2)));
        s.appendChild(bar);
        s.appendChild(svg("text", { x: cx, y: v < 0 ? top + h + 12 : top - 4, "text-anchor": "middle" }, v.toFixed(1)));
      } else {
        s.appendChild(svg("text", { x: cx, y: y(0) - 4, "text-anchor": "middle" }, "no value"));
      }
      s.appendChild(svg("text", { x: cx, y: H - 22, "text-anchor": "middle" }, w.week_start.slice(5)));
      s.appendChild(svg("text", { x: cx, y: H - 8, "text-anchor": "middle" }, w.days_with_data + "/" + (w.days_with_data + w.days_missing) + " days"));
    });
    return el("figure", null, el("figcaption", null, "Mean movement z per week, with days that had data"), s);
  }

  // ---- rounds, suggestions, lessons, notes, refusals ----------------------------------

  function table(head, rows) {
    const t = el("table", null,
      el("thead", null, el("tr", null, head.map((h) => el("th", { scope: "col" }, h)))));
    const tb = el("tbody");
    for (const r of rows) tb.appendChild(el("tr", null, r.map((c) => el("td", null, c instanceof Node ? c : valueTextOrBlank(c)))));
    t.appendChild(tb);
    return el("div", { class: "table-wrap" }, t);
  }

  function valueTextOrBlank(c) {
    if (c === null || c === undefined) return "";
    if (Array.isArray(c)) return c.filter((x) => x !== null && x !== undefined).map((x) => x instanceof Node ? x : String(x));
    return String(c);
  }

  function roundsSection(d) {
    const r = d.progress.rounds;
    const sec = el("section", { "aria-labelledby": "h-rounds" }, el("h2", { id: "h-rounds" }, "Rounds"));
    const pv = r.played_vs_offered;
    sec.appendChild(el("p", null, "Offered " + pv.offered + ", played when offered " + pv.played_when_offered +
      ", played without an offer " + pv.played_unprompted + "."));
    if (!r.energy_series.length) { sec.appendChild(el("p", { class: "muted" }, "No rounds yet.")); return sec; }
    const rows = r.energy_series.slice().reverse().map((x) => [
      el("a", { href: "#/round/" + encodeURIComponent(d.patient_id) + "/" + encodeURIComponent(x.id) }, fmtTime(x.started_at)),
      words(x.mode), words(x.config_id), x.energy_bucket ? words(x.energy_bucket) : "no own normal yet",
      fmtNum(x.energy), words(x.quality), words(x.ended_by), x.reading ? words(x.reading) : "", exampleTag(x)]);
    sec.appendChild(table(["Started", "Mode", "Config", "Energy", "Energy z", "Quality", "Ended by", "Reading", ""], rows));
    return sec;
  }

  function suggestionsSection(d) {
    const sec = el("section", { "aria-labelledby": "h-sug" }, el("h2", { id: "h-sug" }, "Suggestions and answers"));
    if (!d.suggestions.length) { sec.appendChild(el("p", { class: "muted" }, "No suggestions yet.")); return sec; }
    const rows = d.suggestions.slice().reverse().map((s) => [s.date, words(s.action), s.text,
      words(s.wording), words(s.status), s.answer ? words(s.answer) : "no answer", s.felt ? words(s.felt) : "",
      words(s.attention_kind)]);
    sec.appendChild(table(["Date", "Action", "Text shown", "Worded by", "Status", "Answer", "Felt", "Because of"], rows));
    return sec;
  }

  function lessonsSection(d) {
    const sec = el("section", { "aria-labelledby": "h-les" }, el("h2", { id: "h-les" }, "What the mind learned"));
    sec.appendChild(el("p", { class: "muted small" }, "Lessons never change status, thresholds or attention. Every lesson is recomputed by code from the evidence listed."));
    if (!d.lessons.length) sec.appendChild(el("p", { class: "muted" }, "No lessons yet."));
    const ul = el("ul", { class: "items" });
    for (const l of d.lessons) {
      const rejected = l.status === "rejected";
      const stateTag = rejected
        ? el("span", { class: "tag rejected" }, l.end_reason === "patient" ? "rejected by patient" : "rejected")
        : el("span", { class: "tag" }, words(l.status));
      ul.appendChild(el("li", { class: l.status === "active" ? "open" : "closed" },
        el("div", { class: "item-head" }, el("strong", null, l.text), stateTag),
        el("div", { class: "small" }, words(l.effect) + " " + words(l.action) + ", context " + words(l.context) +
          (l.config_id ? ", config " + words(l.config_id) : "") + ". Because: " + words(l.rationale_code) + "."),
        el("div", { class: "small muted" }, "Source: " + words(l.provenance.model) + ", review " + l.provenance.review_id +
          ", " + l.evidence_count + " pieces of evidence, created " + fmtTime(l.created_at) +
          (l.expires_at ? ", expires " + fmtTime(l.expires_at) : "") + (l.end_reason && !rejected ? ", ended: " + words(l.end_reason) : "")),
        el("details", null, el("summary", { class: "small" }, "Evidence ids"),
          el("p", { class: "mono" }, (l.provenance.evidence_ids || []).join(", ")))));
    }
    sec.appendChild(ul);
    if (d.questions.length) {
      sec.appendChild(el("h3", null, "Questions to the patient"));
      sec.appendChild(table(["Question", "Status", "Answer", "Asked"],
        d.questions.map((q) => [q.text, words(q.status), q.answer ? words(q.answer) : "", fmtTime(q.created_at)])));
    }
    return sec;
  }

  function notesSection(d) {
    const sec = el("section", { "aria-labelledby": "h-notes" }, el("h2", { id: "h-notes" }, "Notes"));
    sec.appendChild(el("p", { class: "muted small" }, d.share_notes
      ? "The patient shares note text with the clinic."
      : "Only the time and the labels are shown. The patient does not share the text."));
    if (!d.notes.length) { sec.appendChild(el("p", { class: "muted" }, "No notes.")); return sec; }
    const ul = el("ul", { class: "items" });
    for (const n of d.notes.slice().reverse()) {
      const c = n.classification;
      ul.appendChild(el("li", null,
        el("div", { class: "item-head" }, el("strong", null, fmtTime(n.at)),
          c.crisis ? el("span", null, el("span", { class: "tag level-urgent" }, "help screen shown"), " ", draftTag()) : null),
        el("div", { class: "small" }, "Mood: " + words(c.mood) + ". Topic: " + words(c.topic) +
          ". Asks for help: " + (c.asks_for_help ? "yes" : "no") + ". Model: " + words(c.model) + "."),
        n.text !== undefined ? el("blockquote", { class: "small" }, n.text) : null));
    }
    sec.appendChild(ul);
    return sec;
  }

  function refusalSection(d) {
    const sec = el("section", { "aria-labelledby": "h-ref" }, el("h2", { id: "h-ref" }, "Refusal log"));
    sec.appendChild(el("p", { class: "muted small" }, "What the gates and checks refused for this patient, and why. Codes only, never text."));
    if (!d.refusal_log.length) { sec.appendChild(el("p", { class: "muted" }, "Nothing refused.")); return sec; }
    sec.appendChild(table(["When", "Who", "What", "Why", "Detail"],
      d.refusal_log.map((e) => [fmtTime(e.at), words(e.actor), words(e.action), words(e.reason),
        Object.entries(e.detail || {}).map(([k, v]) => words(k) + ": " + valueText(v)).join(", ")])));
    return sec;
  }

  // ---- round detail -------------------------------------------------------------------

  async function loadRound(pid, rid) {
    const root = $("view-round");
    show("view-round");
    clear(root);
    root.appendChild(el("p", { class: "muted" }, "Loading..."));
    let r;
    try {
      r = await api("GET", "/v1/clinic/patients/" + encodeURIComponent(pid) + "/rounds/" + encodeURIComponent(rid));
    } catch (e) {
      clear(root);
      root.appendChild(el("p", { class: "error" }, e.status === 404 ? "Round not found." : "Could not load: " + e.message));
      return;
    }
    clear(root);
    root.appendChild(el("p", null, el("a", { href: "#/patient/" + encodeURIComponent(pid) }, "Back to the patient")));
    root.appendChild(el("div", { class: "card" },
      el("div", { class: "head-row" }, el("h1", null, "Round " + fmtTime(r.started_at), " ", exampleTag(r)),
        el("span", { class: "tag" }, "energy: " + (r.energy_bucket ? words(r.energy_bucket) : "no own normal yet"))),
      el("dl", { class: "facts" },
        fact("Mode", words(r.mode)), fact("Config", words(r.config && r.config.config_id)),
        fact("Duration", fmtNum(r.duration_s, 1) + " s"), fact("Ended by", words(r.ended_by)),
        fact("Quality", words(r.quality) + (r.quality_reasons && r.quality_reasons.length ? " (" + r.quality_reasons.map(words).join(", ") + ")" : "")),
        fact("Energy z", fmtNum(r.energy)),
        fact("Turning", r.turning ? words(r.turning.label) : "none"),
        fact("Tracking normal", r.tracking ? Math.round(r.tracking.normal_ratio * 100) + "%" : "none"))));

    root.appendChild(el("h2", null, "Path"));
    const usual = r.usual_round;
    const trails = el("div", { class: "trails" });
    const all = [r.path, usual && usual.path].filter(Boolean);
    const extent = trailExtent(all);
    trails.appendChild(trailFigure("This round", r.path, "trail-this", extent));
    if (usual && usual.path) {
      trails.appendChild(trailFigure("A usual round, " + fmtTime(usual.started_at) + (usual.example ? " (example data)" : ""), usual.path, "trail-usual", extent));
    } else {
      trails.appendChild(el("p", { class: "muted" }, "No usual round of the same mode to compare with yet."));
    }
    root.appendChild(trails);
    root.appendChild(el("p", { class: "muted small" }, "Seen from above, relative to where the round started (open circle). The filled square is where it ended. Grid lines are 1 m apart. Both trails use the same scale."));

    root.appendChild(el("h2", null, "Features"));
    const feats = Object.entries(r.features || {});
    root.appendChild(feats.length
      ? table(["Feature", "Value", "z against own normal"], feats.map(([k, v]) => [words(k), fmtNum(v, 3), r.z && r.z[k] !== undefined ? fmtNum(r.z[k]) : "no own normal yet"]))
      : el("p", { class: "muted" }, "No features."));

    root.appendChild(el("h2", null, "Movement reading"));
    root.appendChild(readingBlock(r.analysis || { status: "off" }));

    root.appendChild(el("h2", null, "Lights"));
    root.appendChild(table(["Light", "Appeared (s)", "Distance (m)", "Height (m)", "Reaction (s)", "Ended (s)", "Caught"],
      (r.lights || []).map((l) => [l.i, fmtNum(l.spawn_t, 1), fmtNum(l.dist_m, 1), fmtNum(l.height_m, 1),
        l.first_move_t === null || l.first_move_t === undefined ? "did not move" : fmtNum(l.first_move_t - l.spawn_t, 1),
        fmtNum(l.end_t, 1), l.caught ? "yes" : "no"])));
  }

  function readingBlock(a) {
    const box = el("div", { class: "card" });
    if (a.status !== "ready") {
      const why = { off: "The movement reading is off on this server.", not_allowed: "This patient's record does not allow outside processing.",
        pending: "The reading is still running.", failed: "The reading failed" + (a.reason ? " (" + words(a.reason) + ")" : "") + "." };
      box.appendChild(el("p", null, why[a.status] || ("Status: " + words(a.status))));
      return box;
    }
    const rd = a.reading || {};
    box.appendChild(el("p", { class: "small muted" }, "Read by a model (" + words(a.read_by) + "), checked by " + words(a.checked_by) + ", " + fmtTime(a.at) + "."));
    box.appendChild(el("dl", { class: "facts" },
      ["pattern", "fade_from_light", "reach", "turning", "compared_to_usual", "confidence"].map((k) =>
        fact(words(k), rd[k] === null || rd[k] === undefined ? "none" : words(rd[k])))));
    const ev = rd.evidence || [];
    if (ev.length) {
      box.appendChild(el("h3", null, "Claims kept"));
      box.appendChild(table(["Claim", "Lights"], ev.map((e) => [words(e.claim), (e.lights || []).join(", ")])));
    }
    const dropped = a.dropped || [];
    box.appendChild(el("h3", null, "Claims dropped by the code check"));
    box.appendChild(dropped.length
      ? table(["Field", "Claimed", "Why dropped"], dropped.map((x) => [words(x.field), valueText(x.value), words(x.reason)]))
      : el("p", { class: "muted" }, "None."));
    return box;
  }

  function trailExtent(paths) {
    let m = 1;
    for (const p of paths) for (const pt of (p.points || [])) m = Math.max(m, Math.abs(pt[0]), Math.abs(pt[1]));
    return Math.ceil(m);
  }

  function trailFigure(title, path, cls, extent) {
    const S = 300, pad = 12;
    const sc = (S / 2 - pad) / extent;
    const px = (v) => S / 2 + v * sc;
    const pz = (v) => S / 2 - v * sc;
    const pts = (path && path.points) || [];
    const label = title + ": " + pts.length + " points over about " + (extent * 2) + " by " + (extent * 2) + " metres.";
    const s = svg("svg", { class: "chart", viewBox: "0 0 " + S + " " + S, role: "img", "aria-label": label });
    s.appendChild(svg("title", null, label));
    for (let g = -extent; g <= extent; g++) {
      s.appendChild(svg("line", { class: g === 0 ? "axis" : "grid", x1: px(g), x2: px(g), y1: pad, y2: S - pad }));
      s.appendChild(svg("line", { class: g === 0 ? "axis" : "grid", y1: pz(g), y2: pz(g), x1: pad, x2: S - pad }));
    }
    if (pts.length) {
      s.appendChild(svg("polyline", { class: cls, points: pts.map((p) => px(p[0]).toFixed(1) + "," + pz(p[1]).toFixed(1)).join(" ") }));
      s.appendChild(svg("circle", { class: "start", cx: px(0), cy: pz(0), r: 5 }));
      const last = pts[pts.length - 1];
      s.appendChild(svg("rect", { class: "end", x: px(last[0]) - 4, y: pz(last[1]) - 4, width: 8, height: 8 }));
    } else {
      s.appendChild(svg("text", { x: S / 2, y: S / 2, "text-anchor": "middle" }, "No path (screen mode)"));
    }
    return el("figure", null, el("figcaption", null, title), s);
  }

  // ---- demo panel ---------------------------------------------------------------------

  function demoTarget() {
    const r = state.route;
    if ((r.name === "patient" || r.name === "round") && r.pid) {
      const label = state.patient && state.patient.patient_id === r.pid ? state.patient.label : r.pid;
      return { pid: r.pid, label: label };
    }
    return { pid: state.me && state.me.demo.patient_id, label: "the demo patient" };
  }

  function updateDemoPanel(viewId) {
    const on = !!(state.me && state.me.demo && state.me.demo.enabled) && viewId !== "view-login";
    $("demo-panel").hidden = !on;
    if (!on) return;
    const t = demoTarget();
    $("demo-target").textContent = "Acts on: " + t.label + ".";
    document.querySelector("[data-demo=analyze]").hidden = state.route.name !== "round";
  }

  async function onDemo(ev) {
    const b = ev.target.closest("button[data-demo]");
    if (!b) return;
    const what = b.getAttribute("data-demo");
    const t = demoTarget();
    const out = $("demo-result");
    let call;
    if (what === "scenario-normal") call = ["POST", "/v1/demo/scenario", { name: "normal", patient_id: t.pid }];
    else if (what === "scenario-dip") call = ["POST", "/v1/demo/scenario", { name: "dip", patient_id: t.pid }];
    else if (what === "review") call = ["POST", "/v1/review/run", { patient_id: t.pid }];
    else if (what === "analyze") call = ["POST", "/v1/demo/analyze", { patient_id: state.route.pid, round_id: state.route.rid }];
    else if (what === "tick") call = ["POST", "/v1/demo/tick", undefined];
    else if (what === "reset") {
      if (!window.confirm("Reset the demo patient to 28 normal days? This removes its notes, answers and lessons.")) return;
      call = ["POST", "/v1/demo/reset", undefined];
    } else return;
    b.disabled = true;
    out.textContent = "Working...";
    try {
      const res = await api(call[0], call[1], call[2]);
      out.textContent = demoSummary(what, res);
      await route();
    } catch (e) {
      out.textContent = "Refused: " + e.message;
    } finally {
      b.disabled = false;
    }
  }

  function demoSummary(what, res) {
    if (what.startsWith("scenario")) return "Scenario set. Status now: " + words(res.status) + ".";
    if (what === "review") return "Review done: " + (res.accepted || []).length + " lessons accepted, " + (res.refused || []).length + " refused.";
    if (what === "analyze") return "Movement reading: " + words(res.status) + ".";
    if (what === "reset") return "Demo patient reset.";
    return "Done.";
  }

  // ---- routing ------------------------------------------------------------------------

  function parseRoute() {
    const parts = location.hash.replace(/^#\/?/, "").split("/").map(decodeURIComponent);
    if (parts[0] === "patient" && parts[1]) return { name: "patient", pid: parts[1] };
    if (parts[0] === "round" && parts[1] && parts[2]) return { name: "round", pid: parts[1], rid: parts[2] };
    return { name: "list" };
  }

  async function route() {
    if (!state.token) { show("view-login"); return; }
    state.route = parseRoute();
    if (state.route.name === "patient") await loadPatient(state.route.pid);
    else if (state.route.name === "round") await loadRound(state.route.pid, state.route.rid);
    else await loadList();
    updateDemoPanel(VIEWS.find((v) => !$(v).hidden));
  }

  async function onHash() {
    flash("");
    await route();
    $("main").focus({ preventScroll: false });
  }

  // ---- start --------------------------------------------------------------------------

  async function start() {
    $("login-form").addEventListener("submit", onLogin);
    $("logout").addEventListener("click", () => logout("You are logged out."));
    $("refresh-list").addEventListener("click", loadList);
    $("demo-panel").addEventListener("click", onDemo);
    window.addEventListener("hashchange", onHash);
    renderLegend();
    try {
      const h = await api("GET", "/healthz");
      setProduct(h.product);
    } catch (e) { /* keep the default title */ }
    const t = loadToken();
    if (t) {
      state.token = t;
      try { await afterLogin(); return; } catch (e) { saveToken(null); }
    }
    show("view-login");
  }

  document.addEventListener("DOMContentLoaded", start);
})();
