# Dont-Know-Studios Arcade

The studio's game launcher: every released Dont-Know-Studios game, played in
the browser (desktop or phone) or downloaded for Windows. Served by GitHub
Pages from this repo.

## How a game gets here

1. The game repo has the `studio-game` topic (`/new-game` sets it up).
2. You publish a **GitHub Release** in the game repo (a full release, not a
   draft or pre-release).
3. The game's release workflows (from the studio template) build it and attach
   the assets below to the release.
4. This repo's **Publish arcade** workflow collects the newest release of every
   studio game and redeploys the site — once a day at midnight UTC (only
   deploying when something changed), or straight away with **Actions →
   Publish arcade → Run workflow**. Changes to this repo (pushes to `main`)
   also go live with the next run, not on push.

Releasing a new version replaces the old one on the arcade once a build is
attached: until then (or if the game's build fails) the arcade keeps showing the
release before it. Pre-releases and drafts are ignored.

### Release assets the arcade reads

| Asset | What the arcade does with it |
|---|---|
| `web-build.zip` | the browser build (`index.html` at its top): unpacked into the site, **▶ Play** |
| `windows-build.zip` | the Windows build: copied into a public release on this repo, **Download for Windows** |
| `windows-build.zip.sha256` | its checksum, shown on the card (else GitHub's digest, else worked out when copied) |
| `arcade.json` | the card: `{title, description, pitch, profiles, links: {itch, steam}}` |
| `arcade-cover.png` / `.jpg` / `.webp` | the card's cover |

A release needs `web-build.zip` or `windows-build.zip` (or both) to be listed.
Older games pack `arcade.json` and `arcade-cover.*` inside `web-build.zip`; the
standalone release assets win when both exist. Any change to any of these assets
(a re-upload too) triggers a deploy.

### What the card shows

| Card | From, first one set |
|---|---|
| Title | `title` in `arcade.json` (`project.name` in the game's `project.yaml`); the repo name |
| Text | `description` in `arcade.json` (`release.description`); the repo's GitHub description; the `pitch` (from the game's brief) |
| Cover | `arcade-cover.*` (`release.cover`, or the start screen from the release's desktop and phone check) |
| Badges | `profiles` in `arcade.json`: `browser` → *Keyboard and mouse*, `browser-mobile` → *Works on phones*, `desktop` → *Windows*. No `profiles`: `browser-mobile` for a web build, plus `desktop` for a Windows build |
| Buttons | **▶ Play** (web build), **Download for Windows (size)** (Windows build), **Get it on itch.io** / **Get it on Steam** (`links.itch` / `links.steam`, `https://` only) |

The badge matching the visitor's device is highlighted, and the download button
is the main one on Windows. **Save for offline** is for browser games only. A
download-only game's play link (`play.html?g=<repo name>`) shows its download
page instead of a game.

A renamed repo or a changed GitHub description shows on the next run (the
nightly one, or Run workflow). The rest comes with the next release. Renaming a repo also changes
its play link.

### Downloads

Windows builds never go on the Pages site. **Publish arcade** copies each one
(`tools/mirror.sh`) into a release on this repo, tagged `<game>-<version>`, as
`<Repo>-<version>-windows.zip` with a `.sha256` beside it, and the card links
there. It copies a build once (a release with the same source, size and upload
time is left alone), checks it against the game's checksum, and keeps each
game's current and previous copy, deleting older ones. These releases are made
by the workflow's own `GITHUB_TOKEN` (`contents: write`) and are marked
`arcade-mirror: <game>`; it touches no other release.

**The builds aren't code-signed**, so Windows SmartScreen warns on first run.
The card says so ("Windows may warn: More info → Run anyway") and lists the
SHA-256 for anyone who wants to check the file.

**Everything here is public**, including builds of games whose repos are
private: releasing a game puts its browser build on the site and its **Windows
build in a public release of this repo**, downloadable by anyone.

### itch.io (later)

Not set up. When it is, `push_itch` in `tools/mirror.sh` would run butler for
each copied build, with one itch.io API key in this repo's secrets
(`ITCH_API_KEY`) and the game's itch page from `links.itch` in `arcade.json`;
`publish.yml` marks where the key goes.

## Safety: the arcade never loses a game by accident

- Every GitHub API call and download is retried. If one still fails, the run
  stops with an error and the live site stays as it was; the next run (the
  following midnight, or Run workflow) tries again.
- A run that would list **fewer games than the live site** doesn't deploy. To
  retire or rename a game on purpose: **Actions → Publish arcade → Run workflow**
  with **force** ticked.

## Offline play

The arcade installs as an app (**Install app** in Chrome and Edge, or Share →
**Add to Home Screen** on iPhone and iPad) and plays saved games without internet.

- **Save for offline** on a game's card downloads the whole game to the device.
  A game also saves itself in the background the first time it is played.
- Offline, saved games play as normal; the others show **Needs internet**.
- When a saved game gets a new release, the device downloads it the next time the
  arcade is opened online. Until that finishes, the older saved version still plays.
- **Remove** on the card frees the space.

How it works: `site/sw.js` (a service worker) answers requests from the device's
cache when the network can't, and `site/offline.js` does the saving. For each
game, `collect.sh` writes `games/<slug>/arcade-files.json` (every file in the
build, with sizes and a revision hash) and adds `rev` and `size` to `games.json`.
A saved game is held per revision, so a new release never mixes with old files.

Limits: storage is the browser's. iOS may clear saved games from an arcade that
hasn't been opened for a few weeks, and a big game needs that much free space.
Offline play needs HTTPS (GitHub Pages) or `localhost`.

## Setup (once)

1. **Settings → Pages → Build and deployment → Source: GitHub Actions.**
2. The studio GitHub App (STUDIO.md in the studio template, "The studio GitHub
   App") must be installed on this repo — it is, if it was installed on **All
   repositories**. Its **Contents: Read** permission is what lets it download
   builds from private game repos.
3. **Settings → Secrets and variables → Actions**, the same values as on the
   studio template repo:
   - Variables → `TEMPLATE_APP_ID` = the App ID
   - Secrets → `TEMPLATE_APP_PRIVATE_KEY` = the App's `.pem` text
4. **Actions → Publish arcade → Run workflow.** The site is at
   `https://dont-know-studios.github.io/arcade/`.

## Files

| Path | What |
|---|---|
| `site/` | the static pages: `index.html` (game list), `play.html` (player), `downloads.js` (download buttons), `sw.js` + `offline.js` + `manifest.webmanifest` + `icons/` (install and offline play) |
| `tools/collect.sh` | builds `_site/`: the pages + every game's build + `games.json` |
| `tools/mirror.sh` | copies Windows builds into public releases on this repo |
| `tools/test-collect.sh`, `tools/test-mirror.sh` | check `collect.sh` and `mirror.sh` against made-up games and a stand-in `gh` (also run on every pull request) |
| `.github/workflows/publish.yml` | collect, copy Windows builds, deploy to Pages |
| `.github/workflows/test.yml` | runs the two test scripts on pull requests |

Test locally without GitHub: `bash tools/test-collect.sh` checks `collect.sh`
against made-up games (`--keep _site` also builds a site from them), and
`bash tools/collect.sh --local <fixtures>` builds from your own (see the
script's header). Then `python3 -m http.server -d _site`.
