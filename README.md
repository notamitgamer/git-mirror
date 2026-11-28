<p align="center">
  <img src="https://github.com/notamitgamer/git-mirror/blob/main/assets/logo.png?raw=true" alt="Git Mirror Logo" width="128">
</p>

<p align="center">
  <a href="https://github.com/notamitgamer/git-mirror/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/notamitgamer/git-mirror" alt="MIT License">
  </a>
</p>

# git-mirror

A fast, fully static mirror of a GitHub account's public repositories, styled after
[Forgejo](https://forgejo.org) / [Codeberg](https://codeberg.org). Browse code, commits, diffs, branches and
tags, with README rendering, syntax highlighting and search. There is no server and no database; every
page is pre-rendered HTML served from GitHub Pages.

Live at **https://git.amit.is-a.dev**

## How it works

`build.py` is the whole generator (plain `git` + Python, no compiled dependencies):

1. Lists the account's public repos through the GitHub API and skips the excluded ones.
2. Keeps a shallow bare clone of each (`--depth 200`, all branches and tags) and fetches updates incrementally.
3. Renders every page itself: repo home, folders, files, commits, commit diffs, branches, tags, plus a global
   search index and a sitemap. Each repository also gets a Releases page (newest 30, with notes and assets);
   downloads link straight to GitHub.
4. Re-renders only repos whose HEAD, refs or GitHub metadata changed; everything else is copied from the cache.
   A repo that fails to sync keeps serving its last good copy, and the failure shows up as a workflow warning
   instead of silently disappearing.

The workflow (`.github/workflows/main.yml`) runs on every push, on an hourly schedule, on manual dispatch and on a
`mirror-refresh` repository dispatch, then deploys `site/` to GitHub Pages.

GitHub's schedule is best-effort and can be hours late. The live site above is therefore also triggered every
30 minutes by an external scheduler ([cron-job.org](https://cron-job.org)), which sends a `POST` to
`https://api.github.com/repos/<owner>/<repo>/actions/workflows/main.yml/dispatches` with the body `{"ref":"main"}`
and an `Authorization: Bearer <token>` header (fine-grained token, this repository only, *Actions: Read and write*).

## Front end

* Catppuccin Mocha theme with the peach accent. System fonts only, no frameworks, about 20 KB of CSS and 12 KB of JS.
* **Instant navigation.** Internal links are prefetched aggressively (everything near the viewport, the rest of
  the page shortly after, and on hover or touch), and clicks swap the page content in memory, so navigation
  feels like a single-page app while staying plain static HTML. Back/forward, scroll restoration, open in new
  tab and no-JS browsing all work. Chromium also gets `speculationrules` prefetch and cross-fade transitions.
* **Installable (PWA).** An Install button appears where the browser supports it (on iPhone and iPad use
  *Share → Add to Home Screen*). Pages you have loaded stay readable offline.
* Mobile first: tables, code and diffs scroll inside their own boxes, so the page itself never scrolls sideways.
* Search (`/`) covers repo names, descriptions and file paths. `t` jumps to "Go to file" on a repo page.
  `#L10` and `#L10-L20` highlight lines.

## Layout of the site

```
/                      repository list
/<repo>/               code, About, languages, README
/<repo>/tree/<dir>/    folder
/<repo>/blob/<file>/   file (highlighted, Markdown preview, images)
/<repo>/commits/       history      /<repo>/commit/<sha10>/   diff
/<repo>/branches/      /<repo>/tags/      /<repo>/releases/
```

## Fork and deploy your own

No files to edit.

1. **Fork** this repository.
2. **Turn on Pages:** *Settings → Pages → Source: GitHub Actions*.
3. **Turn on workflows:** open the *Actions* tab and enable them (GitHub keeps them off on every fork).
4. **Start the first build:** *Actions → Build & Deploy Git Mirror → Enable workflow* if asked, then *Run workflow*.

The site appears at `https://<you>.github.io/git-mirror/` (or at the root for a `<you>.github.io` repository or a
custom domain) and is then rebuilt on every push and on GitHub's schedule (see above for exact timing). It mirrors the fork owner's public repositories.

Optional repository variables (*Settings → Secrets and variables → Actions → Variables*): `MIRROR_USER`,
`MIRROR_EXCLUDE` (comma separated), `MIRROR_BASE_URL` and `MIRROR_REBUILD_NOTE` (home page timing text).

## Run it locally

```bash
pip install -r requirements.txt
GH_TOKEN=<any token>   python build.py        # token is optional but avoids the 60 req/h API limit
python -m http.server -d site 8000
```

Configuration is by environment variable: `MIRROR_USER`, `MIRROR_EXCLUDE` (this repository is always skipped),
`MIRROR_DEPTH` (default `200`) and `MIRROR_BASE_URL` (defaults to the Pages URL).

## Limits

* Only the newest 50 commits per repo get a diff page; older history links to GitHub.
* Files larger than 300 KB are not rendered, and files over 150 KB are shown without syntax colours.
* Only the default branch has a browsable tree; other branches are listed and link to GitHub.
* "Last commit" columns are computed from the cloned history, so files untouched for more than 200 commits
  show no commit info.

`cdn-sync.yml` pushes the original repository to its CDN and is skipped on forks.

## License

MIT, see `LICENSE`.
