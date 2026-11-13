// Arcade home: renders games.json (written by tools/collect.sh) as cards.
(function () {
  "use strict";
  var list = document.getElementById("games");
  var status = document.getElementById("status");
  var q = document.getElementById("q");
  var games = [];
  var Off = window.ArcadeOffline;
  var progress = {};   // slug → fraction saved, while saving
  var live = {};       // slug → redraw of the card on screen (cards are rebuilt on search)

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function hue(s) {
    var h = 0;
    for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360;
    return h;
  }
  function when(iso) {
    if (!iso) return "";
    var d = new Date(iso);
    return isNaN(d) ? "" : d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
  }
  function isNew(iso) {
    var d = new Date(iso);
    return !isNaN(d) && Date.now() - d.getTime() < 14 * 864e5;
  }

  function card(g) {
    var li = el("li", "card");
    var cover = el("div", "cover");
    if (g.cover) {
      cover.style.backgroundImage = "url('" + encodeURI(g.cover).replace(/'/g, "%27") + "')";
    } else {
      var h = hue(g.slug);
      cover.style.background = "linear-gradient(135deg, hsl(" + h + " 70% 45%), hsl(" + ((h + 50) % 360) + " 70% 30%))";
      cover.textContent = (g.title || g.slug).trim().charAt(0).toUpperCase();
    }
    if (isNew(g.released)) cover.appendChild(el("span", "badge", "New"));
    li.appendChild(cover);

    var body = el("div", "body");
    body.appendChild(el("h2", null, g.title));
    if (g.description) body.appendChild(el("p", null, g.description));
    var bits = [g.version, when(g.released)].filter(Boolean).join(" · ");
    if (bits) body.appendChild(el("div", "meta", bits));

    var row = el("div", "row");
    var play = el("a", "btn play", "▶ Play");
    play.href = "play.html?g=" + encodeURIComponent(g.slug);
    play.setAttribute("aria-label", "Play " + g.title);
    row.appendChild(play);
    if (g.notes) {
      var notes = el("a", "btn ghost", "Notes");
      notes.href = g.notes; notes.target = "_blank"; notes.rel = "noopener";
      row.appendChild(notes);
    }
    body.appendChild(row);
    if (Off && Off.supported && g.rev) {
      var save = el("div", "offline");
      body.appendChild(save);
      offlineControls(g, li, save, play);
    }
    li.appendChild(body);
    return li;
  }

  // The card's "Save for offline" line, and whether Play works without internet.
  function offlineControls(g, li, box, play) {
    function show(state, err) {
      var online = navigator.onLine;
      box.replaceChildren();
      li.classList.toggle("unavailable", !online && (state === "none" || state === "saving"));
      if (!online && state === "none") {
        play.textContent = "Needs internet";
        play.removeAttribute("href");
        play.setAttribute("aria-disabled", "true");
      } else {
        play.textContent = "▶ Play";
        play.href = "play.html?g=" + encodeURIComponent(g.slug);
        play.removeAttribute("aria-disabled");
      }
      if (state === "saving") {
        var pct = Math.round((progress[g.slug] || 0) * 100);
        box.appendChild(el("span", "muted", "Saving for offline… " + pct + "%"));
        var bar = el("progress"); bar.max = 100; bar.value = pct;
        box.appendChild(bar);
        return;
      }
      if (state === "saved" || state === "old") {
        box.appendChild(el("span", "saved", state === "saved" ? "✓ Saved for offline" : "✓ Saved (an older version)"));
        var rm = el("button", "link", "Remove");
        rm.type = "button";
        rm.setAttribute("aria-label", "Remove " + g.title + " from this device");
        rm.addEventListener("click", function () { Off.remove(g.slug).then(refresh); });
        box.appendChild(rm);
        return;
      }
      if (!online) { box.appendChild(el("span", "muted", "Not saved on this device")); return; }
      var btn = el("button", "link", "⤓ Save for offline");
      btn.type = "button";
      btn.setAttribute("aria-label", "Save " + g.title + " for offline play");
      btn.addEventListener("click", function () { start(Off.save(g, tick)); });
      box.appendChild(btn);
      if (g.size) box.appendChild(el("span", "muted", Off.size(g.size)));
      if (err) box.appendChild(el("span", "error", err));
    }
    function tick(f) { progress[g.slug] = f; if (live[g.slug]) live[g.slug]("saving"); }
    function start(p) {
      progress[g.slug] = progress[g.slug] || 0;
      show("saving");
      p.then(function () { live[g.slug].refresh(); },
             function (e) { live[g.slug].refresh(e && e.message || "Saving failed."); });
    }
    function refresh(err) {
      if (Off.saving(g.slug)) return show("saving");
      delete progress[g.slug];
      Off.status(g).then(function (s) { show(s, typeof err === "string" ? err : ""); });
    }
    show.refresh = refresh;
    live[g.slug] = show;
    var running = Off.saving(g.slug);
    if (running) start(running); else refresh();
  }

  function render() {
    var term = (q.value || "").toLowerCase().trim();
    var shown = games.filter(function (g) {
      return !term || (g.title + " " + (g.description || "")).toLowerCase().indexOf(term) !== -1;
    });
    list.replaceChildren.apply(list, shown.map(card));
    if (!games.length) status.textContent = "No games released yet. Publish a release in a game repo and it shows up here.";
    else if (!shown.length) status.textContent = "No games match “" + q.value + "”.";
    else status.textContent = shown.length + (shown.length === 1 ? " game" : " games");
  }

  q.addEventListener("input", render);

  // Offline banner, and cards re-checked when the connection comes and goes.
  var banner = document.getElementById("offline-banner");
  function connection() {
    banner.hidden = navigator.onLine;
    if (games.length) render();
  }
  window.addEventListener("online", function () { connection(); update(); });
  window.addEventListener("offline", connection);
  connection();

  // A saved game whose build changed is downloaded again in the background;
  // its card shows the progress.
  function update() {
    if (!Off || !games.length) return;
    Off.refresh(games, function (slug, f) {
      progress[slug] = f;
      if (live[slug]) live[slug]("saving");
    }).then(function (slugs) { if (slugs.length) render(); });
  }

  // Install: browsers that offer a prompt get a button; iPhones and iPads get a hint.
  var install = document.getElementById("install");
  var deferred = null;
  window.addEventListener("beforeinstallprompt", function (e) {
    e.preventDefault(); deferred = e; install.hidden = false;
  });
  install.addEventListener("click", function () {
    if (!deferred) return;
    deferred.prompt();
    deferred.userChoice.finally(function () { deferred = null; install.hidden = true; });
  });
  window.addEventListener("appinstalled", function () { install.hidden = true; });
  var standalone = window.matchMedia("(display-mode: standalone)").matches || navigator.standalone;
  var ios = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  if (ios && !standalone) document.getElementById("ios-hint").hidden = false;

  fetch("games.json", { cache: "no-cache" })
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(function (data) {
      games = data.games || [];
      if (data.updated) document.getElementById("updated").textContent = "Updated " + new Date(data.updated).toLocaleString();
      render();
      update();
    })
    .catch(function () {
      status.textContent = navigator.onLine
        ? "Couldn't load the game list. Try reloading the page."
        : "You're offline, and the game list isn't saved on this device yet. Open the arcade once with internet.";
    });
})();
