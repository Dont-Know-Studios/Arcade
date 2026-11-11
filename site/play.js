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
      frame.src = g.url;
      document.getElementById("newtab").href = g.url;
      frame.addEventListener("load", function () { try { frame.contentWindow.focus(); } catch (e) {} });
    })
    .catch(missing);

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
