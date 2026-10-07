/* msb-manager docs: theme, search, copy buttons, mobile nav, toc highlight.
 * No framework and no build step; window.MSB_SEARCH comes from
 * search-index.js, which docs/build.py writes. */
(function () {
  "use strict";

  var root = document.documentElement;
  var KEY = "msb-docs-theme";

  /* ------------------------------------------------------------ theme */
  // Three states, cycled: auto (follow the system, live) -> light -> dark.
  var media = window.matchMedia ? matchMedia("(prefers-color-scheme: dark)") : null;
  var toggle = document.getElementById("theme-toggle");

  function stored() {
    try { return localStorage.getItem(KEY); } catch (e) { return null; }
  }
  function store(value) {
    try {
      if (value) localStorage.setItem(KEY, value); else localStorage.removeItem(KEY);
    } catch (e) { /* private mode: the choice lasts for this page only */ }
  }
  function apply() {
    var pref = stored() || "auto";
    var theme = pref === "auto" ? (media && media.matches ? "dark" : "light") : pref;
    root.dataset.theme = theme;
    root.dataset.themePref = pref;
    if (toggle) {
      toggle.textContent = "[" + pref + "]";
      toggle.setAttribute("aria-label", "Colour theme: " + (pref === "auto" ? "automatic (" + theme + ")" : pref) + ". Click to change.");
      toggle.title = pref === "auto" ? "following your system (" + theme + ")" : pref + " theme";
    }
  }
  if (toggle) {
    toggle.addEventListener("click", function () {
      var next = { auto: "light", light: "dark", dark: "auto" }[stored() || "auto"];
      store(next === "auto" ? null : next);
      apply();
    });
  }
  if (media) {
    var onChange = function () { if (!stored()) apply(); };
    if (media.addEventListener) media.addEventListener("change", onChange);
    else if (media.addListener) media.addListener(onChange);
  }
  apply();

  /* ------------------------------------------------------- mobile nav */
  var menu = document.querySelector(".menu-btn");
  if (menu) {
    menu.addEventListener("click", function () {
      var open = document.body.classList.toggle("nav-open");
      menu.setAttribute("aria-expanded", open ? "true" : "false");
    });
    document.addEventListener("click", function (e) {
      if (document.body.classList.contains("nav-open") &&
          !e.target.closest(".sidebar") && !e.target.closest(".menu-btn")) {
        document.body.classList.remove("nav-open");
        menu.setAttribute("aria-expanded", "false");
      }
    });
  }

  /* ----------------------------------------------------- copy buttons */
  document.querySelectorAll(".term").forEach(function (term) {
    var button = term.querySelector(".copy");
    if (!button) return;
    button.addEventListener("click", function () {
      var code = term.querySelector("code");
      // A console block copies only its commands, never the prompt or output.
      var cmds = code.querySelectorAll(".t-cmd");
      var text = cmds.length
        ? Array.prototype.map.call(cmds, function (c) { return c.textContent; }).join("\n")
        : code.textContent;
      var done = function () {
        button.textContent = "copied";
        button.classList.add("done");
        setTimeout(function () { button.textContent = "copy"; button.classList.remove("done"); }, 1400);
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, function () {});
      } else {
        var area = document.createElement("textarea");
        area.value = text;
        area.style.position = "fixed";
        area.style.opacity = "0";
        document.body.appendChild(area);
        area.select();
        try { document.execCommand("copy"); done(); } catch (e) {}
        document.body.removeChild(area);
      }
    });
  });

  /* ----------------------------------------------------------- search */
  var input = document.getElementById("search");
  var results = document.getElementById("search-results");
  var selected = -1;

  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

  function mark(text, terms) {
    var safe = escapeHtml(text);
    if (!terms.length) return safe;
    var re = new RegExp("(" + terms.map(function (t) { return escapeRe(escapeHtml(t)); }).join("|") + ")", "gi");
    return safe.replace(re, "<mark>$1</mark>");
  }

  function snippet(text, terms) {
    var lower = text.toLowerCase();
    var at = -1;
    for (var i = 0; i < terms.length && at < 0; i++) at = lower.indexOf(terms[i]);
    if (at < 0) return text.slice(0, 140) + (text.length > 140 ? "…" : "");
    var start = Math.max(0, at - 50);
    var end = Math.min(text.length, at + 110);
    return (start > 0 ? "…" : "") + text.slice(start, end) + (end < text.length ? "…" : "");
  }

  function count(hay, term) {
    var n = 0, at = hay.indexOf(term);
    while (at >= 0 && n < 20) { n++; at = hay.indexOf(term, at + term.length); }
    return n;
  }

  // Every term must appear somewhere in the entry; headings outweigh body text.
  function search(query) {
    var index = window.MSB_SEARCH || [];
    var terms = query.toLowerCase().split(/\s+/).filter(function (t) { return t.length > 0; });
    if (!terms.length) return { terms: terms, hits: [] };
    var hits = [];
    for (var i = 0; i < index.length; i++) {
      var e = index[i];
      var head = (e.h || "").toLowerCase(), page = e.p.toLowerCase(), body = e.t.toLowerCase();
      var score = 0, ok = true;
      for (var k = 0; k < terms.length; k++) {
        var t = terms[k];
        var s = count(head, t) * 12 + count(page, t) * 6 + count(body, t);
        if (!s) { ok = false; break; }
        score += s;
      }
      if (ok) {
        if (head.indexOf(query.toLowerCase()) >= 0) score += 25;
        hits.push({ e: e, score: score });
      }
    }
    hits.sort(function (a, b) { return b.score - a.score; });
    return { terms: terms, hits: hits.slice(0, 12) };
  }

  function render() {
    var query = input.value.trim();
    selected = -1;
    if (!query) { close(); return; }
    var found = search(query);
    if (!found.hits.length) {
      results.innerHTML = '<div class="r-empty">grep: no match for "' + escapeHtml(query) + '"</div>';
    } else {
      results.innerHTML = found.hits.map(function (h, k) {
        var e = h.e;
        return '<a href="' + escapeHtml(e.u) + '" role="option" id="r-' + k + '" aria-selected="false">' +
          '<span class="r-head">' + mark(e.h || e.p, found.terms) + '</span>' +
          (e.h ? ' <span class="r-page">· ' + escapeHtml(e.p) + '</span>' : '') +
          '<span class="r-snip">' + mark(snippet(e.t, found.terms), found.terms) + '</span></a>';
      }).join("");
    }
    results.hidden = false;
    input.setAttribute("aria-expanded", "true");
  }

  function close() {
    results.hidden = true;
    results.innerHTML = "";
    input.setAttribute("aria-expanded", "false");
    input.removeAttribute("aria-activedescendant");
  }

  function move(delta) {
    var items = results.querySelectorAll("a");
    if (!items.length) return;
    if (selected >= 0) items[selected].setAttribute("aria-selected", "false");
    selected = (selected + delta + items.length) % items.length;
    items[selected].setAttribute("aria-selected", "true");
    items[selected].scrollIntoView({ block: "nearest" });
    input.setAttribute("aria-activedescendant", items[selected].id);
  }

  if (input && results) {
    input.addEventListener("input", render);
    input.addEventListener("focus", function () { if (input.value.trim()) render(); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
      else if (e.key === "Enter") {
        var items = results.querySelectorAll("a");
        var target = items[selected >= 0 ? selected : 0];
        if (target) { e.preventDefault(); window.location.href = target.getAttribute("href"); close(); }
      } else if (e.key === "Escape") { input.value = ""; close(); input.blur(); }
    });
    document.addEventListener("click", function (e) {
      if (!e.target.closest(".search")) close();
    });
    // "/" focuses the search from anywhere, as in most terminal tools.
    document.addEventListener("keydown", function (e) {
      var tag = (document.activeElement && document.activeElement.tagName) || "";
      if (e.key === "/" && !/INPUT|TEXTAREA|SELECT/.test(tag) && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault();
        input.focus();
        input.select();
      }
    });
  }

  /* ------------------------------------------------- toc highlighting */
  var tocLinks = document.querySelectorAll(".toc a");
  if (tocLinks.length && "IntersectionObserver" in window) {
    var byId = {};
    tocLinks.forEach(function (a) { byId[a.getAttribute("href").slice(1)] = a; });
    var visible = {};
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { visible[en.target.id] = en.isIntersecting; });
      var current = null;
      document.querySelectorAll(".doc h2[id], .doc h3[id]").forEach(function (h) {
        if (!current && visible[h.id]) current = h.id;
      });
      if (current) {
        tocLinks.forEach(function (a) { a.classList.remove("current"); });
        if (byId[current]) byId[current].classList.add("current");
      }
    }, { rootMargin: "-60px 0px -65% 0px" });
    document.querySelectorAll(".doc h2[id], .doc h3[id]").forEach(function (h) { observer.observe(h); });
  }
})();
