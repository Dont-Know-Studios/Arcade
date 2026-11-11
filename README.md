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
uses `project.name`, `release.description` and `release.cover` from the
game's `project.yaml` when set, else the repo's name and GitHub description.

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
