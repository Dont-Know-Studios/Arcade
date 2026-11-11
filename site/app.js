// Arcade home: renders games.json (written by tools/collect.sh) as cards.
(function () {
  "use strict";
  var list = document.getElementById("games");
  var status = document.getElementById("status");
  var q = document.getElementById("q");
  var games = [];

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
    li.appendChild(body);
    return li;
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
  fetch("games.json", { cache: "no-cache" })
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(function (data) {
      games = data.games || [];
      if (data.updated) document.getElementById("updated").textContent = "Updated " + new Date(data.updated).toLocaleString();
      render();
    })
    .catch(function () { status.textContent = "Couldn't load the game list. Try reloading the page."; });
})();
