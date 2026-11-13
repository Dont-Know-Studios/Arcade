# Dont-Know-Studios Arcade

The studio's game launcher: every released Dont-Know-Studios game, playable in
the browser, on desktop or phone. Served by GitHub Pages from this repo.

## How a game gets here

1. The game repo has the `studio-game` topic (`/new-game` sets it up).
2. You publish a **GitHub Release** in the game repo (a full release, not a
   draft or pre-release).
3. The game's **Web release** workflow (from the studio template) builds its
   browser version and attaches `web-build.zip` to the release.
4. This repo's **Publish arcade** workflow collects the newest release of every
   studio game and redeploys the site — every 5 minutes (only deploying when something changed), or straight away with
   **Actions → Publish arcade → Run workflow**.

Releasing a new version replaces the old one on the arcade. The game's card
fills itself in:

| Card | From, first one set |
|---|---|
| Title | `project.name` in the game's `project.yaml`; the repo name |
| Text | `release.description`; the repo's GitHub description; the pitch in the game's brief |
| Cover | `release.cover`; the start screen, from the release's desktop and phone check |

A renamed repo or a changed GitHub description shows on the next run (about
5 minutes). The rest is packed into the release build, so it changes with the
next release. Renaming a repo also changes its play link
(`play.html?g=<repo name>`).

**Everything here is public**, including builds of games whose repos are
private: releasing a game puts it on the arcade.

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
| `site/` | the static pages: `index.html` (game list), `play.html` (player), `sw.js` + `offline.js` + `manifest.webmanifest` + `icons/` (install and offline play) |
| `tools/collect.sh` | builds `_site/`: the pages + every game's build + `games.json` |
| `.github/workflows/publish.yml` | collect and deploy to Pages |

Test locally without GitHub: `bash tools/collect.sh --local <fixtures>` (see
the script's header), then `python3 -m http.server -d _site`.
