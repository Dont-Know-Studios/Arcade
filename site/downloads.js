// Desktop downloads and store links for a game's card (app.js) and for the
// player page of a download-only game (play.js). Builds come from games.json:
// platforms [{os, file, bytes, sha256, url}] and links {itch, steam}.
(function () {
  "use strict";

  // The visitor's system, to highlight what runs on it.
  var os = (function () {
    var ua = navigator.userAgent || "";
    var p = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    if (/iPad|iPhone|iPod/.test(ua) || (p === "MacIntel" && navigator.maxTouchPoints > 1)) return "ios";
    if (/Android/i.test(ua)) return "android";
    if (/Win/i.test(p) || /Windows/.test(ua)) return "windows";
    if (/Mac/i.test(p)) return "mac";
    if (/Linux|CrOS/i.test(p + " " + ua)) return "linux";
    return "other";
  })();
  var phone = os === "ios" || os === "android";
  var OS_NAMES = { windows: "Windows", mac: "macOS", linux: "Linux" };
  var STORES = { itch: "Get it on itch.io", steam: "Get it on Steam" };

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function size(bytes) {
    if (!bytes) return "";
    var u = ["B", "KB", "MB", "GB"], i = 0;
    while (bytes >= 1000 && i < u.length - 1) { bytes /= 1000; i++; }
    return (i === 0 ? bytes : bytes.toFixed(bytes < 10 ? 1 : 0)) + " " + u[i];
  }
  function safe(url) { return typeof url === "string" && /^https:\/\//.test(url); }
  function builds(g) {
    return (g.platforms || []).filter(function (p) { return OS_NAMES[p.os] && safe(p.url); });
  }

  // Badges: how the game is played. Absent profiles (an older games.json): none.
  function badges(g) {
    var out = [], seen = {};
    function add(text, mine) {
      if (seen[text]) return;
      seen[text] = 1;
      var b = el("span", "tag" + (mine ? " mine" : ""), text);
      if (mine) b.title = "Works on this device";
      out.push(b);
    }
    (g.profiles || []).forEach(function (p) {
      if (p === "browser") add("Keyboard and mouse", !phone);
      if (p === "browser-mobile") add("Works on phones", phone);
    });
    builds(g).forEach(function (p) { add(OS_NAMES[p.os], p.os === os); });
    return out;
  }

  // "Download for Windows (412 MB)": the main button when the game has no
  // browser version, or the visitor is on that system.
  function buttons(g, opts) {
    var out = [];
    builds(g).forEach(function (p) {
      var main = !g.url || p.os === os || (opts && opts.main);
      var a = el("a", "btn download" + (main ? "" : " ghost"));
      a.href = p.url;
      a.appendChild(document.createTextNode("⤓ Download for " + OS_NAMES[p.os]));
      if (p.bytes) a.appendChild(el("span", "size", size(p.bytes)));
      a.setAttribute("aria-label", "Download " + g.title + " for " + OS_NAMES[p.os] +
        (p.bytes ? " (" + size(p.bytes) + ")" : ""));
      out.push(a);
    });
    var links = g.links || {};
    Object.keys(STORES).forEach(function (k) {
      if (!safe(links[k])) return;
      var a = el("a", "btn ghost store", STORES[k]);
      a.href = links[k]; a.target = "_blank"; a.rel = "noopener";
      out.push(a);
    });
    return out;
  }

  // The unsigned-build note and the checksum, under the download buttons.
  function note(g) {
    var list = builds(g);
    if (!list.length) return null;
    var box = el("div", "dl-note");
    var win = list.some(function (p) { return p.os === "windows"; });
    var line = [];
    if (win) line.push("Windows may warn: More info → Run anyway.");
    if (list.every(function (p) { return p.os !== os; })) {
      line.push("Needs a " + list.map(function (p) { return OS_NAMES[p.os]; }).join(" or ") +
        (list.length === 1 && list[0].os === "windows" ? " PC." : " computer."));
    }
    if (line.length) box.appendChild(el("p", null, line.join(" ")));
    var sums = list.filter(function (p) { return p.sha256; });
    if (sums.length || win) {
      var d = el("details");
      d.appendChild(el("summary", null, "Why the warning, and checking the download"));
      if (win) d.appendChild(el("p", null,
        "The game isn't code-signed yet, so Windows SmartScreen doesn't recognise it. " +
        "Choose More info, then Run anyway. Unzip the download first and run the game's .exe."));
      sums.forEach(function (p) {
        var s = el("p");
        s.appendChild(document.createTextNode("SHA-256 of " + (p.file || "the download") + ":"));
        s.appendChild(el("code", null, p.sha256));
        d.appendChild(s);
      });
      if (sums.length) d.appendChild(el("p", "muted",
        "To check: Get-FileHash <file> in PowerShell, or sha256sum <file>."));
      box.appendChild(d);
    }
    return box;
  }

  window.ArcadeDownloads = { os: os, phone: phone, builds: builds, badges: badges, buttons: buttons, note: note, size: size };
})();
