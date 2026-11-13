// Arcade service worker: lets the arcade, and every game saved on this device,
// work offline. See README.md, "Offline play".
//
// Caches:
//   arcade-shell                the arcade's own pages, scripts, icons and games.json
//   arcade-game:<slug>:<rev>    one game build's files (saved by offline.js, or kept
//                               as they are played). A copy is complete once it holds
//                               the marker games/<slug>/.arcade-saved.
//
// The arcade's pages come from the network when it answers quickly (so a new
// version of the site shows straight away) and from the cache otherwise.
// A game's files come from its saved copy when that copy is complete and of the
// build games.json lists; otherwise from the network, falling back to whatever
// copy this device has.
"use strict";

var SHELL = "arcade-shell";
var SHELL_FILES = [
  "./", "index.html", "play.html", "style.css", "app.js", "play.js", "offline.js",
  "manifest.webmanifest", "icons/icon-192.png", "icons/icon-512.png",
  "icons/maskable-512.png", "icons/apple-touch-icon.png", "games.json"
];
var GAME_PREFIX = "arcade-game:";
var MARKER = ".arcade-saved";
var NETWORK_WAIT = 4000;   // ms before a slow network gives way to the cached page

var base = new URL("./", self.registration.scope);
var revs = null;            // slug → rev of the build games.json lists

self.addEventListener("install", function (e) {
  e.waitUntil(caches.open(SHELL).then(function (c) {
    // One by one, so a single missing file (games.json on a site with no games
    // yet) does not stop the rest being cached.
    return Promise.all(SHELL_FILES.map(function (f) {
      return fetch(new Request(new URL(f, base), { cache: "reload" }))
        .then(function (r) { if (r.ok) return c.put(new URL(f, base), r); })
        .catch(function () {});
    }));
  }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener("activate", function (e) {
  e.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", function (e) {
  var req = e.request;
  if (req.method !== "GET") return;
  var url = new URL(req.url);
  if (url.origin !== base.origin || url.pathname.indexOf(base.pathname) !== 0) return;
  var path = url.pathname.slice(base.pathname.length);   // e.g. "games/foo/index.html"

  var m = /^games\/([^/]+)\/(.*)$/.exec(path);
  if (m) {
    e.respondWith(gameFile(req, m[1], url));
  } else if (path === "games.json") {
    e.respondWith(shell(req, url, true));
  } else {
    e.respondWith(shell(req, url, false));
  }
});

// --- The arcade's own files -------------------------------------------------

function shellKey(url) {
  var p = url.pathname.slice(base.pathname.length);
  return new URL(p === "" ? "./" : p, base).href;   // the query (?g=…) is not part of the key
}

function shell(req, url, isList) {
  var key = shellKey(url);
  var net = fetch(req).then(function (r) {
    if (r.ok) {
      var copy = r.clone();
      caches.open(SHELL).then(function (c) { return c.put(key, copy); });
      if (isList) r.clone().json().then(learnRevs, function () {});
    }
    return r;
  });
  var cached = function () {
    return caches.match(key, { cacheName: SHELL }).then(function (hit) {
      if (hit) return hit;
      // Navigating to a page that was never cached: the arcade home, if we have it.
      if (req.mode === "navigate") return caches.match(new URL("./", base).href, { cacheName: SHELL });
    });
  };
  return new Promise(function (resolve, reject) {
    var done = false;
    var timer = setTimeout(function () {
      cached().then(function (hit) { if (hit && !done) { done = true; resolve(hit); } });
    }, NETWORK_WAIT);
    net.then(function (r) {
      if (done) return;
      if (r.ok || r.status === 404) { done = true; clearTimeout(timer); return resolve(r); }
      return cached().then(function (hit) { done = true; clearTimeout(timer); resolve(hit || r); });
    }, function (err) {
      if (done) return;
      cached().then(function (hit) {
        done = true; clearTimeout(timer);
        hit ? resolve(hit) : reject(err);
      });
    });
  });
}

function learnRevs(data) {
  var map = {};
  (data && data.games || []).forEach(function (g) { if (g.rev) map[g.slug] = g.rev; });
  revs = map;
}

function currentRevs() {
  if (revs) return Promise.resolve(revs);
  return caches.match(new URL("games.json", base).href, { cacheName: SHELL })
    .then(function (r) { return r ? r.json() : null; })
    .then(function (d) { learnRevs(d); return revs; }, function () { return {}; });
}

// --- Game files -------------------------------------------------------------

function gameKey(slug, url) {
  var p = url.pathname.slice(base.pathname.length);
  if (/\/$/.test(p)) p += "index.html";
  return new URL(p, base).href;   // queries (cache busters) ignored
}

function gameCaches(slug) {
  var prefix = GAME_PREFIX + slug + ":";
  return caches.keys().then(function (keys) {
    return keys.filter(function (k) { return k.indexOf(prefix) === 0; });
  });
}

function isComplete(name, slug) {
  return caches.open(name).then(function (c) {
    return c.match(new URL("games/" + slug + "/" + MARKER, base).href);
  }).then(function (hit) { return !!hit; });
}

function gameFile(req, slug, url) {
  var key = gameKey(slug, url);
  return Promise.all([currentRevs(), gameCaches(slug)]).then(function (got) {
    var rev = got[0][slug];
    var names = got[1];
    var curName = rev ? GAME_PREFIX + slug + ":" + rev : null;
    var hasCur = curName && names.indexOf(curName) !== -1;

    var fromCur = hasCur ? isComplete(curName, slug) : Promise.resolve(false);
    return fromCur.then(function (complete) {
      if (complete) {
        return caches.open(curName)
          .then(function (c) { return c.match(key); })
          .then(function (hit) { return hit ? ranged(req, hit) : network(); });
      }
      return network();
    });

    function network() {
      return fetch(req).then(function (r) {
        // Keep what is played, so a game played once is (mostly) there offline.
        if (curName && r.status === 200 && !req.headers.has("range")) {
          var copy = r.clone();
          caches.open(curName).then(function (c) { return c.put(key, copy); }).catch(function () {});
        }
        return r;
      }, function (err) {
        return fallback(names, slug, key).then(function (hit) {
          if (hit) return ranged(req, hit);
          throw err;
        });
      });
    }
  });
}

// Offline: a complete copy of any build of the game first (an older version
// beats a half-saved newer one), then any copy that has the file.
function fallback(names, slug, key) {
  return Promise.all(names.map(function (n) { return isComplete(n, slug); })).then(function (flags) {
    var order = names.filter(function (n, i) { return flags[i]; })
      .concat(names.filter(function (n, i) { return !flags[i]; }));
    return order.reduce(function (p, n) {
      return p.then(function (hit) {
        return hit || caches.open(n).then(function (c) { return c.match(key); });
      });
    }, Promise.resolve(null));
  });
}

// Audio and video ask for byte ranges; a cache holds whole files.
function ranged(req, res) {
  var range = req.headers.get("range");
  var m = range && /^bytes=(\d*)-(\d*)$/.exec(range.trim());
  if (!m) return res;
  return res.blob().then(function (blob) {
    var size = blob.size;
    var start = m[1] === "" ? Math.max(0, size - Number(m[2])) : Number(m[1]);
    var end = m[1] !== "" && m[2] !== "" ? Math.min(Number(m[2]), size - 1) : size - 1;
    if (start >= size || start > end) {
      return new Response(null, { status: 416, headers: { "Content-Range": "bytes */" + size } });
    }
    var headers = new Headers(res.headers);
    headers.set("Content-Range", "bytes " + start + "-" + end + "/" + size);
    headers.set("Content-Length", String(end - start + 1));
    return new Response(blob.slice(start, end + 1), { status: 206, statusText: "Partial Content", headers: headers });
  });
}
