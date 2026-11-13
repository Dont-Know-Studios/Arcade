// Offline play, page side: registers the service worker (sw.js) and saves,
// checks, updates and removes the copies of games kept on this device.
// Used by app.js (the game cards) and play.js (saving a game as it is played).
(function () {
  "use strict";
  var GAME_PREFIX = "arcade-game:";
  var MARKER = ".arcade-saved";
  var PARALLEL = 4;
  var supported = "serviceWorker" in navigator && "caches" in window && window.isSecureContext;
  var busy = {};   // slug → promise of a save in progress

  if (supported) {
    navigator.serviceWorker.register("sw.js", { scope: "./" }).catch(function () {});
  }

  function base() { return new URL("./", location.href); }
  function cacheName(g) { return GAME_PREFIX + g.slug + ":" + g.rev; }
  function markerUrl(slug) { return new URL("games/" + slug + "/" + MARKER, base()).href; }
  function fileUrl(slug, path) {
    return new URL("games/" + slug + "/" + path.split("/").map(encodeURIComponent).join("/"), base()).href;
  }
  function slugCaches(slug) {
    var prefix = GAME_PREFIX + slug + ":";
    return caches.keys().then(function (keys) {
      return keys.filter(function (k) { return k.indexOf(prefix) === 0; });
    });
  }
  function complete(name, slug) {
    return caches.open(name).then(function (c) { return c.match(markerUrl(slug)); })
      .then(function (hit) { return !!hit; });
  }

  // "saved": a complete copy of the build games.json lists.
  // "old": only a complete copy of an earlier build (it plays offline; it updates when online).
  // "none": nothing complete. "unsupported": this browser can't keep games.
  function status(g) {
    if (!supported || !g.rev) return Promise.resolve("unsupported");
    return slugCaches(g.slug).then(function (names) {
      return Promise.all(names.map(function (n) { return complete(n, g.slug); })).then(function (flags) {
        var cur = cacheName(g);
        if (names.some(function (n, i) { return flags[i] && n === cur; })) return "saved";
        if (flags.some(Boolean)) return "old";
        return "none";
      });
    });
  }

  // Download every file of the game's build (skipping those already kept from
  // playing it), mark the copy complete, then drop other builds of the game.
  // onProgress(fraction 0…1).
  function save(g, onProgress) {
    if (!supported || !g.rev) return Promise.reject(new Error("Offline play isn't available in this browser."));
    if (busy[g.slug]) return busy[g.slug];
    var name = cacheName(g);
    var p = fetch(fileUrl(g.slug, "arcade-files.json"), { cache: "no-cache" })
      .then(function (r) { if (!r.ok) throw new Error("No file list for " + g.title); return r.json(); })
      .then(function (list) {
        if (list.rev !== g.rev) throw new Error("The arcade was just updated. Reload and try again.");
        if (navigator.storage && navigator.storage.persist) navigator.storage.persist().catch(function () {});
        return caches.open(name).then(function (cache) {
          var files = list.files || [];
          var total = list.size || 1, got = 0, i = 0;
          function tick(n) { got += n; if (onProgress) onProgress(Math.min(1, got / total)); }
          function next() {
            if (i >= files.length) return Promise.resolve();
            var f = files[i++];
            var url = fileUrl(g.slug, f[0]);
            return cache.match(url).then(function (hit) {
              if (hit) return tick(f[1]);
              return fetch(url, { cache: "no-cache" }).then(function (r) {
                if (r.status !== 200) throw new Error("Couldn't download " + f[0] + " (" + r.status + ")");
                return cache.put(url, r).then(function () { tick(f[1]); });
              });
            }).then(next);
          }
          var workers = [];
          for (var w = 0; w < PARALLEL; w++) workers.push(next());
          return Promise.all(workers).then(function () {
            return cache.put(markerUrl(g.slug), new Response(g.rev));
          });
        });
      })
      .then(function () {
        return slugCaches(g.slug).then(function (names) {
          return Promise.all(names.filter(function (n) { return n !== name; })
            .map(function (n) { return caches.delete(n); }));
        });
      })
      .catch(function (err) {
        if (err && err.name === "QuotaExceededError") {
          throw new Error("Not enough storage space on this device for " + g.title + ".");
        }
        throw err;
      })
      .finally(function () { delete busy[g.slug]; });
    busy[g.slug] = p;
    return p;
  }

  function remove(slug) {
    if (!supported) return Promise.resolve();
    return slugCaches(slug).then(function (names) {
      return Promise.all(names.map(function (n) { return caches.delete(n); }));
    });
  }

  // Housekeeping with a fresh games.json: update saved games whose build changed,
  // and drop copies of games no longer on the arcade and stray half copies.
  // Returns the slugs being updated; onProgress(slug, fraction) follows them.
  function refresh(games, onProgress) {
    if (!supported || !navigator.onLine) return Promise.resolve([]);
    var bySlug = {};
    games.forEach(function (g) { bySlug[g.slug] = g; });
    return caches.keys().then(function (keys) {
      var names = keys.filter(function (k) { return k.indexOf(GAME_PREFIX) === 0; });
      return Promise.all(names.map(function (n) {
        var parts = n.slice(GAME_PREFIX.length).split(":");
        return complete(n, parts[0]).then(function (c) { return { name: n, slug: parts[0], rev: parts[1], complete: c }; });
      }));
    }).then(function (copies) {
      var updating = [];
      copies.forEach(function (c) {
        var g = bySlug[c.slug];
        if (!g) return caches.delete(c.name);
        if (c.complete && c.rev !== g.rev && updating.indexOf(g.slug) === -1) updating.push(g.slug);
        // A half copy of an old build serves nothing useful.
        if (!c.complete && c.rev !== g.rev) caches.delete(c.name);
      });
      updating.forEach(function (slug) {
        save(bySlug[slug], onProgress && function (f) { onProgress(slug, f); }).catch(function () {});
      });
      return updating;
    });
  }

  function size(bytes) {
    if (!bytes) return "";
    var u = ["B", "KB", "MB", "GB"], i = 0;
    while (bytes >= 1000 && i < u.length - 1) { bytes /= 1000; i++; }
    return (i === 0 ? bytes : bytes.toFixed(bytes < 10 ? 1 : 0)) + " " + u[i];
  }

  window.ArcadeOffline = {
    supported: supported,
    status: status,
    save: save,
    saving: function (slug) { return busy[slug] || null; },
    remove: remove,
    refresh: refresh,
    size: size
  };
})();
