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

  var fs = document.getElementById("fs");
  if (!document.fullscreenEnabled && !frame.webkitRequestFullscreen) fs.hidden = true;
  fs.addEventListener("click", function () {
    var req = frame.requestFullscreen || frame.webkitRequestFullscreen;
    if (req) req.call(frame);
  });
})();
