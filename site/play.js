// Arcade player: play.html?g=<slug> runs games/<slug>/ in a full-window frame.
(function () {
  "use strict";
  var slug = new URLSearchParams(location.search).get("g") || "";
  var frame = document.getElementById("frame");
  var title = document.getElementById("title");
  var meta = document.getElementById("meta");

  function missing() {
    title.textContent = "Game not found";
    frame.hidden = true;
    document.getElementById("missing").hidden = false;
  }

  fetch("games.json", { cache: "no-cache" })
    .then(function (r) { return r.json(); })
    .then(function (data) {
      var g = (data.games || []).filter(function (x) { return x.slug === slug; })[0];
      if (!g) return missing();
      document.title = g.title + " — Dont-Know-Studios Arcade";
      title.textContent = g.title;
      meta.textContent = g.version || "";
      // A download-only (desktop) game has no browser build to put in the frame.
      if (!g.url) return downloadOnly(g);
      var Off = window.ArcadeOffline;
      var check = Off && Off.supported ? Off.status(g) : Promise.resolve("unsupported");
      check.then(function (state) {
        if (!navigator.onLine && (state === "none" || state === "unsupported")) {
          frame.hidden = true;
          var note = document.getElementById("missing");
          note.replaceChildren(
            "You're offline, and " + g.title + " isn't saved on this device. Connect to the internet to play it" +
            (state === "none" ? " (it saves itself for offline as you play). " : ". "));
          var back = document.createElement("a"); back.href = "./"; back.textContent = "Back to all games";
          note.appendChild(back); note.appendChild(document.createTextNode("."));
          note.hidden = false;
          return;
        }
        frame.src = g.url;
        document.getElementById("newtab").href = g.url;
        frame.addEventListener("load", function () {
          try { frame.contentWindow.focus(); } catch (e) {}
          // Played once, playable offline: save the rest of the game in the background.
          if (state !== "saved" && navigator.onLine && Off && Off.supported) {
            setTimeout(function () { autosave(Off, g); }, 3000);
          }
        }, { once: true });
      });
    })
    .catch(missing);

  function downloadOnly(g) {
    var Dl = window.ArcadeDownloads;
    frame.hidden = true;
    frame.removeAttribute("src");
    document.getElementById("newtab").hidden = true;
    document.getElementById("fs").hidden = true;
    var box = document.getElementById("download");
    box.replaceChildren();
    if (g.cover) {
      var img = document.createElement("img");
      img.className = "dl-cover"; img.alt = ""; img.src = g.cover;
      box.appendChild(img);
    }
    var h = document.createElement("h2"); h.textContent = g.title; box.appendChild(h);
    var p = document.createElement("p");
    p.textContent = "This game is a download: it runs on your computer, not in the browser.";
    box.appendChild(p);
    if (g.description) { var d = document.createElement("p"); d.className = "muted"; d.textContent = g.description; box.appendChild(d); }
    var row = document.createElement("div"); row.className = "row";
    var any = false;
    if (Dl) Dl.buttons(g, { main: true }).forEach(function (b) { row.appendChild(b); any = true; });
    var back = document.createElement("a"); back.className = "btn ghost"; back.href = "./"; back.textContent = "Back to all games";
    row.appendChild(back);
    box.appendChild(row);
    if (!any) {
      var none = document.createElement("p"); none.className = "muted";
      none.textContent = "No download is available for it right now.";
      box.insertBefore(none, row);
    }
    var n = Dl && Dl.note(g);
    if (n) box.appendChild(n);
    box.hidden = false;
  }

  function autosave(Off, g) {
    var base = g.version || "";
    function line(t) { meta.textContent = base ? base + " · " + t : t; }
    Off.save(g, function (f) { line("saving for offline " + Math.round(f * 100) + "%"); })
      .then(function () { line("saved for offline"); },
            function () { meta.textContent = base; });
  }

  // Fullscreen. Real fullscreen of the game's frame where the browser allows it
  // (desktop browsers, Android). Where it does not (iPhone Safari allows it only
  // for video; in-app browsers and embedded previews often block it) or it is
  // refused, "full window": the bar goes and the game fills the page, with an ✕
  // to come back (Esc too, while the arcade page has the keys: inside a game, Esc
  // is the game's own, often pause). Either way the game gets keyboard focus afterwards,
  // so its keys work without another click.
  var fs = document.getElementById("fs");
  var exitBtn = document.getElementById("exit-full");

  function focusGame() {
    try { frame.focus(); frame.contentWindow.focus(); } catch (e) {}
  }
  function nativeEl() {
    return document.fullscreenElement || document.webkitFullscreenElement || null;
  }
  function canNative() {
    var req = frame.requestFullscreen || frame.webkitRequestFullscreen;
    var on = document.fullscreenEnabled || document.webkitFullscreenEnabled;
    return !!(req && on);
  }
  function isFull() {
    return !!nativeEl() || document.body.classList.contains("full-window");
  }
  function sync() {
    fs.textContent = isFull() ? "Exit fullscreen" : "Fullscreen";
  }
  function enterWindow() {
    document.body.classList.add("full-window");
    exitBtn.hidden = false;
    sync();
    focusGame();
  }
  function exitWindow() {
    document.body.classList.remove("full-window");
    exitBtn.hidden = true;
    sync();
    focusGame();
  }
  function enter() {
    if (!canNative()) return enterWindow();
    var req = frame.requestFullscreen || frame.webkitRequestFullscreen;
    var p;
    try { p = req.call(frame); } catch (e) { return enterWindow(); }
    if (p && p.then) {
      p.then(focusGame, enterWindow);   // refused → full window instead
    } else {
      setTimeout(function () { if (nativeEl()) focusGame(); else enterWindow(); }, 300);
    }
  }
  function leave() {
    if (nativeEl()) {
      var ex = document.exitFullscreen || document.webkitExitFullscreen;
      if (ex) ex.call(document);
    } else {
      exitWindow();
    }
  }

  fs.addEventListener("click", function () { isFull() ? leave() : enter(); });
  exitBtn.addEventListener("click", exitWindow);
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && document.body.classList.contains("full-window")) exitWindow();
  });
  ["fullscreenchange", "webkitfullscreenchange"].forEach(function (ev) {
    document.addEventListener(ev, function () { sync(); focusGame(); });
  });
  sync();
})();
