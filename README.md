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
   search index and a sitemap.
4. Re-renders only repos whose HEAD, refs or GitHub metadata changed; everything else is copied from the cache.
   A repo that fails to sync keeps serving its last good copy, and the failure shows up as a workflow warning
   instead of silently disappearing.

The workflow (`.github/workflows/main.yml`) runs on every push, hourly, on manual dispatch and on a
`mirror-refresh` repository dispatch, then deploys `site/` to GitHub Pages.

## Front end

* Light and dark themes follow the system. System fonts only, no frameworks, about 20 KB of CSS and 12 KB of JS.
* **Instant navigation.** Internal links are prefetched aggressively (everything near the viewport, the rest of
  the page shortly after, and on hover or touch), and clicks swap the page content in memory, so navigation
  feels like a single-page app while staying plain static HTML. Back/forward, scroll restoration, open in new
  tab and no-JS browsing all work. Chromium also gets `speculationrules` prefetch and cross-fade transitions.
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
/<repo>/branches/      /<repo>/tags/
```

## Fork and deploy your own

1. **Fork** this repository.
2. **Enable Actions.** Forks start with workflows disabled: open the *Actions* tab and enable them.
3. **Enable Pages.** *Settings → Pages → Build and deployment → Source: GitHub Actions*. For a custom domain, set it
   there too; the build picks it up automatically (or set `MIRROR_BASE_URL`).
4. **Run it once.** *Actions → Build & Deploy Git Mirror → Run workflow*. After that it rebuilds on every push and
   hourly. The account mirrored is the owner of the fork (override with `MIRROR_USER`).

To hide repositories, set `MIRROR_EXCLUDE` (comma separated) in the workflow's `env`, for example
`MIRROR_EXCLUDE: "secret-project,old-fork"`. Forks of other people's repositories are mirrored like any other.

## Run it locally

```bash
pip install -r requirements.txt
GH_TOKEN=<any token>   python build.py        # token is optional but avoids the 60 req/h API limit
python -m http.server -d site 8000
```

Configuration is by environment variable: `MIRROR_USER`, `MIRROR_EXCLUDE` (default `git-mirror,register,osma`),
`MIRROR_DEPTH` (default `200`) and `MIRROR_BASE_URL` (defaults to the Pages custom domain).

## Limits

* Only the newest 50 commits per repo get a diff page; older history links to GitHub.
* Files larger than 300 KB are not rendered, and files over 150 KB are shown without syntax colours.
* Only the default branch has a browsable tree; other branches are listed and link to GitHub.
* "Last commit" columns are computed from the cloned history, so files untouched for more than 200 commits
  show no commit info.

`cdn-sync.yml` is unchanged and still pushes this repository to the CDN.

## License

MIT, see `LICENSE`.
