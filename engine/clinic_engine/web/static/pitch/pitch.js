// Lanvi stage pitch: moves through the scenes in index.html, keeps the clock, draws the sky.
// The words, the order and the planned seconds all live in index.html; nothing here needs editing for those.
(function () {
  "use strict";
  var LIMIT = 180; // seconds; the microphone is cut here
  var stage = document.getElementById("stage");
  var scenes = Array.prototype.slice.call(document.querySelectorAll(".scene"));
  var plan = scenes.map(function (s) { return Number(s.getAttribute("data-seconds")) || 0; });
  var stepsIn = scenes.map(function (s) {
    var max = 0;
    s.querySelectorAll("[data-step],[data-gone]").forEach(function (el) {
      max = Math.max(max, Number(el.getAttribute("data-step")) || 0, Number(el.getAttribute("data-gone")) || 0);
    });
    return max;
  });
  var planTotal = plan.reduce(function (a, b) { return a + b; }, 0);
  // How long the speaker's lines take: about 2.3 words a second, plus the silences marked in [brackets].
  var NUM = { one: 1, two: 2, three: 3, four: 4, five: 5 };
  var says = scenes.map(function (s) {
    var a = s.querySelector("aside"); if (!a) return 0;
    var text = a.textContent, silence = 0;
    (text.match(/\[[^\]]*\]/g) || []).forEach(function (cue) {
      var m = /(one|two|three|four|five|\d+)\s+seconds?/.exec(cue);
      silence += m ? (NUM[m[1]] || Number(m[1])) : 1;
    });
    var words = text.replace(/\[[^\]]*\]/g, " ").replace(/\([^)]*\)/g, " ").split(/\s+/).filter(function (w) { return /[A-Za-z0-9]/.test(w); }).length;
    return Math.round(words / 2.3 + silence);
  });
  var cur = 0, step = 0, startedAt = null, auto = null;
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------- fit the 1920x1080 stage into the window ----------
  function fit() {
    var k = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
    document.documentElement.style.setProperty("--k", String(k));
    sizeCanvases();
  }

  // ---------- showing a scene and its steps ----------
  function show() {
    scenes.forEach(function (s, i) {
      s.classList.toggle("active", i === cur);
      if (i !== cur) return;
      s.setAttribute("data-at", String(step));
      s.querySelectorAll("[data-step]").forEach(function (el) {
        var on = Number(el.getAttribute("data-step")) <= step;
        if (on && !el.classList.contains("on") && el.hasAttribute("data-type")) typeOut(el);
        el.classList.toggle("on", on);
      });
      s.querySelectorAll("[data-gone]").forEach(function (el) {
        el.classList.toggle("gone", Number(el.getAttribute("data-gone")) <= step);
      });
    });
    // Film clips and app recordings: play what is on screen, from its start, and stop the rest.
    document.querySelectorAll("video").forEach(function (v) {
      var sc = v.closest(".scene"), host = v.closest("[data-step],[data-gone]") || v;
      var s0 = Number(host.getAttribute("data-step")) || 0, g = host.hasAttribute("data-gone") ? Number(host.getAttribute("data-gone")) : Infinity;
      var seen = sc === scenes[cur] && step >= s0 && step < g;
      v.muted = true;
      if (seen && !v._seen) { try { v.currentTime = 0; } catch (e) {} if (!reduce) { var pr = v.play(); if (pr && pr.catch) pr.catch(function () {}); } }
      if (!seen && v._seen) v.pause();
      v._seen = seen;
    });
    document.body.classList.toggle("at-cover", cur === 0);
    var s = scenes[cur];
    target.aurora = Number(s.getAttribute("data-aurora")) || 0;
    target.snow = s.getAttribute("data-snow") === "1" ? 1 : 0;
    var aside = s.querySelector("aside");
    document.getElementById("notes-title").textContent = (cur ? cur + " · " : "") + (s.getAttribute("data-title") || "") +
      (plan[cur] ? " · " + plan[cur] + " s planned · your words take about " + says[cur] + " s" : "");
    document.getElementById("notes-body").textContent = aside ? aside.textContent.replace(/^\s+|\s+$/g, "").replace(/\n\s+/g, "\n") : "";
    drawBar();
  }
  function resetScene(i) {
    scenes[i].querySelectorAll(".on").forEach(function (el) { el.classList.remove("on"); });
    scenes[i].querySelectorAll(".gone").forEach(function (el) { el.classList.remove("gone"); });
    scenes[i].querySelectorAll("[data-type]").forEach(function (el) { el.textContent = ""; });
  }
  function next() {
    if (startedAt === null && cur === 0) startedAt = performance.now();
    if (step < stepsIn[cur]) { step += 1; }
    else if (cur < scenes.length - 1) { cur += 1; step = 0; resetScene(cur); }
    show();
  }
  function back() {
    if (step > 0) {
      step -= 1;
      scenes[cur].querySelectorAll("[data-type]").forEach(function (el) {
        if (Number(el.getAttribute("data-step")) > step) el.textContent = "";
      });
    } else if (cur > 0) { cur -= 1; step = stepsIn[cur]; }
    show();
  }
  function restart() {
    stopAuto(); cur = 0; step = 0; startedAt = null;
    scenes.forEach(function (_, i) { resetScene(i); });
    show(); tick();
  }

  // ---------- the typed note ----------
  function typeOut(el) {
    var text = el.getAttribute("data-type") || "", i = 0;
    el.textContent = "";
    if (reduce) { el.textContent = text; return; }
    (function one() {
      if (!el.classList.contains("on") && i > 0) return;
      el.textContent = text.slice(0, i);
      if (i < text.length) { i += 1; setTimeout(one, 150 + Math.random() * 120); }
    })();
  }

  // ---------- the stream of face numbers (an illustration of the shape of the data) ----------
  var grid = document.getElementById("numgrid"), cells = [];
  if (grid) {
    for (var c = 0; c < 24; c++) { var sp = document.createElement("span"); sp.textContent = "0.00"; grid.appendChild(sp); cells.push(sp); }
    var base = cells.map(function () { return Math.random() * 0.5; });
    setInterval(function () {
      if (!grid.closest(".scene").classList.contains("active")) return;
      var t = performance.now() / 1000;
      cells.forEach(function (sp, i) {
        var v = base[i] + 0.18 * Math.sin(t * (0.7 + i * 0.13) + i) + 0.04 * (Math.random() - 0.5);
        sp.textContent = Math.min(1, Math.max(0, v)).toFixed(2);
      });
    }, reduce ? 1000 : 66);
  }

  // ---------- clock and plan ----------
  var bar = document.getElementById("bar"), segs = [];
  plan.forEach(function (sec) {
    var i = document.createElement("i"), b = document.createElement("b");
    i.style.flex = String(sec || 0.0001) + " 1 0";
    if (!sec) i.hidden = true;
    i.appendChild(b); bar.appendChild(i); segs.push(i);
  });
  function fmt(s) { s = Math.max(0, Math.round(s)); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"); }
  function elapsed() { return startedAt === null ? 0 : (performance.now() - startedAt) / 1000; }
  function drawBar() {
    var e = elapsed(), before = 0;
    segs.forEach(function (seg, i) {
      var sec = plan[i], fill = sec ? Math.min(1, Math.max(0, (e - before) / sec)) : 0;
      seg.firstChild.style.width = (fill * 100) + "%";
      seg.classList.toggle("now", i === cur);
      seg.classList.toggle("over", i < cur ? false : e > before + sec && i === cur);
      before += sec;
    });
  }
  function tick() {
    var e = elapsed();
    document.getElementById("elapsed").textContent = fmt(e);
    var pace = document.getElementById("pace");
    if (startedAt === null || cur === 0) { pace.textContent = ""; }
    else {
      // Where the plan says this scene should end, against the clock.
      var end = 0; for (var i = 0; i <= cur; i++) end += plan[i];
      var left = end - e;
      pace.textContent = left >= 0 ? "scene " + fmt(left) : "over " + fmt(-left);
      pace.classList.toggle("late", left < 0);
    }
    drawBar();
  }
  setInterval(tick, 250);

  // ---------- play by itself: each scene takes its planned time, clicks spread evenly ----------
  function stopAuto() { if (auto) { clearTimeout(auto); auto = null; } }
  function autoStep() {
    var isLast = cur === scenes.length - 1 && step >= stepsIn[cur];
    if (isLast) { auto = null; return; }
    var wait = cur === 0 ? 1200 : (plan[cur] * 1000) / (stepsIn[cur] + 1);
    auto = setTimeout(function () { next(); autoStep(); }, wait);
  }

  // ---------- keys ----------
  var notes = document.getElementById("notes"), help = document.getElementById("help");
  var sum = document.getElementById("sum");
  sum.textContent = "Planned: " + fmt(planTotal) + " of " + fmt(LIMIT) + (planTotal > LIMIT ? " · OVER by " + (planTotal - LIMIT) + " s" : " · " + (LIMIT - planTotal) + " s of air");
  var long = [];
  scenes.forEach(function (s, i) { if (plan[i] && says[i] > plan[i] + 1) long.push((s.getAttribute("data-title") || i) + ": words " + says[i] + " s, planned " + plan[i] + " s"); });
  if (long.length) sum.textContent += " · TOO MANY WORDS in " + long.join("; ");
  sum.classList.toggle("over", planTotal > LIMIT || long.length > 0);
  if (planTotal > LIMIT) help.hidden = false;
  window.lanviPitch = { plan: plan, says: says };
  document.addEventListener("keydown", function (ev) {
    var k = ev.key;
    if (k === "ArrowRight" || k === " " || k === "PageDown" || k === "Enter") { ev.preventDefault(); stopAuto(); next(); }
    else if (k === "ArrowLeft" || k === "PageUp" || k === "Backspace") { ev.preventDefault(); stopAuto(); back(); }
    else if (k === "n" || k === "N") notes.hidden = !notes.hidden;
    else if (k === "t" || k === "T") document.body.classList.toggle("no-clock");
    else if (k === "f" || k === "F") { if (document.fullscreenElement) document.exitFullscreen(); else if (document.documentElement.requestFullscreen) document.documentElement.requestFullscreen().catch(function () {}); }
    else if (k === "a" || k === "A") { if (auto) stopAuto(); else autoStep(); }
    else if (k === "r" || k === "R") restart();
    else if (k === "?" || k === "h" || k === "H") help.hidden = !help.hidden;
  });
  document.addEventListener("click", function (ev) {
    if (ev.target.closest(".notes, .help")) return;
    stopAuto(); next();
  });

  // ---------- the sky: northern lights drawn small and stretched, so they are soft and cheap ----------
  var sky = document.getElementById("sky"), sctx = sky.getContext("2d");
  var snow = document.getElementById("snow"), nctx = snow.getContext("2d");
  var target = { aurora: 0, snow: 0 }, now = { aurora: 0, snow: 0 }, flakes = [];
  function sizeCanvases() {
    sky.width = 320; sky.height = 180;
    snow.width = window.innerWidth; snow.height = window.innerHeight;
  }
  for (var f = 0; f < 110; f++) flakes.push({ x: Math.random(), y: Math.random(), r: 0.8 + Math.random() * 2.4, v: 0.02 + Math.random() * 0.05, w: Math.random() * 6.28 });
  var RIBBONS = [
    { hue: [126, 240, 180], y: 0.30, amp: 0.10, speed: 0.11, len: 0.42 },
    { hue: [106, 166, 245], y: 0.22, amp: 0.08, speed: 0.07, len: 0.36 },
    { hue: [163, 148, 255], y: 0.38, amp: 0.12, speed: 0.05, len: 0.30 }
  ];
  var last = performance.now();
  function frame(t) {
    var dt = Math.min(0.1, (t - last) / 1000); last = t;
    now.aurora += (target.aurora - now.aurora) * Math.min(1, dt * 1.2);
    now.snow += (target.snow - now.snow) * Math.min(1, dt * 1.5);
    var W = sky.width, H = sky.height, time = reduce ? 20 : t / 1000;
    sctx.globalCompositeOperation = "source-over";
    sctx.fillStyle = "#060b16"; sctx.fillRect(0, 0, W, H);
    if (now.aurora > 0.01) {
      sctx.globalCompositeOperation = "lighter";
      RIBBONS.forEach(function (rb, ri) {
        for (var x = 0; x < W; x += 2) {
          var u = x / W;
          var y = rb.y + rb.amp * Math.sin(u * 5 + time * rb.speed * 6 + ri * 2) + 0.04 * Math.sin(u * 13 - time * rb.speed * 9);
          var streak = 0.62 + 0.26 * Math.sin(u * 7 + time * rb.speed * 5 + ri * 1.7) + 0.12 * Math.sin(u * 23 - time * rb.speed * 11);
          var a = now.aurora * 0.20 * streak;
          var g = sctx.createLinearGradient(0, (y - rb.len * 0.75) * H, 0, (y + rb.len * 0.25) * H);
          g.addColorStop(0, "rgba(" + rb.hue.join(",") + ",0)");
          g.addColorStop(0.75, "rgba(" + rb.hue.join(",") + "," + a.toFixed(3) + ")");
          g.addColorStop(1, "rgba(" + rb.hue.join(",") + ",0)");
          sctx.fillStyle = g; sctx.fillRect(x, 0, 2, H);
        }
      });
    }
    nctx.clearRect(0, 0, snow.width, snow.height);
    if (now.snow > 0.01) {
      nctx.fillStyle = "rgba(230,240,255," + (0.8 * now.snow).toFixed(3) + ")";
      flakes.forEach(function (fl) {
        if (!reduce) { fl.y += fl.v * dt; fl.x += 0.012 * Math.sin(time * 0.6 + fl.w) * dt; }
        if (fl.y > 1.02) { fl.y = -0.02; fl.x = Math.random(); }
        nctx.beginPath(); nctx.arc(fl.x * snow.width, fl.y * snow.height, fl.r, 0, 6.2832); nctx.fill();
      });
    }
    requestAnimationFrame(frame);
  }

  window.addEventListener("resize", fit);
  fit(); show(); tick();
  if (/[?&]auto\b/.test(location.search)) autoStep();
  // ?still shows every state finished at once (for screenshots and for checking an edit).
  if (/[?&]still\b/.test(location.search)) { document.body.classList.add("still"); reduce = true; }
  // For checking a scene without clicking through: ?at=4.2 opens scene 4 at its second click.
  var at = /[?&]at=(\d+)(?:\.(\d+))?/.exec(location.search);
  if (at) { cur = Math.min(scenes.length - 1, Number(at[1])); step = Math.min(stepsIn[cur], Number(at[2] || 0)); now.aurora = Number(scenes[cur].getAttribute("data-aurora")) || 0; show(); }
  requestAnimationFrame(frame);
})();
