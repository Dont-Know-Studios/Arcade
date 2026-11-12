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
| `site/` | the static pages: `index.html` (game list), `play.html` (player) |
| `tools/collect.sh` | builds `_site/`: the pages + every game's build + `games.json` |
| `.github/workflows/publish.yml` | collect and deploy to Pages |

Test locally without GitHub: `bash tools/collect.sh --local <fixtures>` (see
the script's header), then `python3 -m http.server -d _site`.
