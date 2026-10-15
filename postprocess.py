#!/usr/bin/env python3
"""Post-process stagit output: header/nav polish, clone commands, footer, prefetch."""
import os, re, sys, html as H

SITE = sys.argv[1]
USER = os.environ["MIRROR_USER"]
REPO_SLUG = os.environ["MIRROR_REPO"]
BUILD_TIME = os.environ["MIRROR_BUILD_TIME"]
SHORT = os.environ["MIRROR_SHORT"]
FULL = os.environ["MIRROR_FULL"]
BASE = os.environ["MIRROR_BASE_URL"]

ICON_COPY = ('<svg class="ic-copy" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" '
             'stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="14" height="14" x="8" y="8" rx="2"/>'
             '<path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg>')
ICON_OK = ('<svg class="ic-ok" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" '
           'stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>')
ICON_GH = ('<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" '
           'stroke-linecap="round" stroke-linejoin="round"><path d="M15 3h6v6M10 14 21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/></svg>')

ICON_SHARE = ('<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" '
              'stroke-linecap="round" stroke-linejoin="round"><circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/>'
              '<circle cx="18" cy="19" r="3"/><path d="m8.6 13.5 6.8 4M15.4 6.5l-6.8 4"/></svg>')
SHARE_BTN = f'<button type="button" class="share" aria-label="Share this page">{ICON_SHARE}</button>'

def gh_cmd(repo):
    return f"git clone https://github.com/{USER}/{repo}.git"

def clone_rows(repo):
    cmd = gh_cmd(repo)
    shown = H.escape(cmd).replace("/", "/<wbr>")  # let long URLs wrap at slashes, not mid-word
    return (f'<div class="clone-row"><code>{shown}</code>{copy_btn(cmd, "")}</div>')

def copy_btn(text, label="Copy"):
    return (f'<button type="button" class="copy" data-copy="{H.escape(text, quote=True)}" '
            f'aria-label="Copy clone command">{ICON_COPY}{ICON_OK}<span>{label}</span></button>')

def footer():
    year = BUILD_TIME[:4]
    return f'''<footer id="site-footer">
<div class="f-grid">
<div class="f-brand">
<a class="f-logo" href="/"><img src="/logo.png" alt="" width="28" height="28"><strong>{H.escape(BASE.replace("https://",""))}</strong></a>
<p>A static, hourly-rebuilt mirror of the public repositories of <a href="https://github.com/{USER}" target="_blank" rel="noopener">@{USER}</a>. Every page is pre-rendered; nothing runs on a server.</p>
</div>
<div class="f-col"><h4>Build</h4><ul>
<li><span class="k">Built</span> <time>{BUILD_TIME}</time></li>
<li><span class="k">Commit</span> <a href="https://github.com/{REPO_SLUG}/commit/{FULL}" target="_blank" rel="noopener"><code>{SHORT}</code></a></li>
<li><a href="/last_commit" target="_blank">Raw build info</a></li>
</ul></div>
<div class="f-col"><h4>Explore</h4><ul>
<li><a href="/">All repositories</a></li>
<li><a href="https://github.com/{USER}" target="_blank" rel="noopener">GitHub profile</a></li>
<li><a href="/sitemap.xml">Sitemap</a></li>
</ul></div>
<div class="f-col"><h4>Source</h4><ul>
<li><a href="https://github.com/{REPO_SLUG}" target="_blank" rel="noopener">{REPO_SLUG}</a></li>
<li><a href="https://codemadness.org/stagit.html" target="_blank" rel="noopener">Powered by stagit</a></li>
</ul></div>
</div>
<div class="f-bottom"><span>© {year} <a href="https://github.com/{USER}" target="_blank" rel="noopener">{USER}</a> · MIT License</span><a href="#top" class="to-top">Back to top ↑</a></div>
</footer>'''

SPEC = ('<script type="speculationrules">{"prerender":[{"where":{"href_matches":"/*"},"eagerness":"moderate"}],'
        '"prefetch":[{"where":{"href_matches":"/*"},"eagerness":"conservative"}]}</script>')

BUILD_ISO = BUILD_TIME.replace(" UTC", "Z").replace(" ", "T")

def sync_time(prefix="Synced"):
    return (f'<time class="sync" data-rel data-prefix="{prefix}" datetime="{BUILD_ISO}" '
            f'title="{BUILD_TIME}">{prefix} {BUILD_TIME}</time>')

def social_meta(doc, rel):
    t = re.search(r'<title>(.*?)</title>', doc, re.S)
    title = H.unescape(t.group(1)).strip() if t else "Git"
    m = re.search(r'<span class="desc">(.*?)</span>', doc, re.S)
    desc = re.sub(r'<.*?>', '', H.unescape(m.group(1))).strip() if m else ""
    if not desc or desc == "Repositories":
        desc = f"Browse and clone the public repositories of {USER}."
    path = rel.replace(os.sep, "/")
    if path.endswith("index.html"):
        path = path[:-len("index.html")]
    url = f"{BASE}/{path}"
    e = lambda s: H.escape(s, quote=True)
    return (f'<link rel="canonical" href="{e(url)}"><meta name="description" content="{e(desc)}">'
            f'<meta property="og:type" content="website"><meta property="og:site_name" content="Git">'
            f'<meta property="og:title" content="{e(title)}"><meta property="og:description" content="{e(desc)}">'
            f'<meta property="og:url" content="{e(url)}"><meta property="og:image" content="{BASE}/icon-512.png">'
            f'<meta property="og:image:width" content="512"><meta property="og:image:height" content="512">'
            f'<meta name="twitter:card" content="summary"><meta name="twitter:title" content="{e(title)}">'
            f'<meta name="twitter:description" content="{e(desc)}"><meta name="twitter:image" content="{BASE}/icon-512.png">')

def head_inject(doc, rel="index.html"):
    # Cache-bust CSS/JS: browsers kept serving the previous style.css after a deploy
    doc = re.sub(r'href="((?:\.\./)*style\.css)(?:\?[^"]*)?"', lambda m: f'href="{m.group(1)}?v={SHORT}"', doc)
    if 'charset' not in doc[:600].lower():
        doc = re.sub(r'<head>', '<head>\n<meta charset="utf-8">', doc, 1)
    if 'name="viewport"' not in doc:
        doc = re.sub(r'<head>', '<head>\n<meta name="viewport" content="width=device-width, initial-scale=1">', doc, 1)
    extra = ('<meta name="color-scheme" content="dark"><meta name="theme-color" content="#181825">'
             '<link rel="manifest" href="/manifest.webmanifest"><link rel="apple-touch-icon" href="/apple-touch-icon.png">'
             '<meta name="application-name" content="Git"><meta name="apple-mobile-web-app-title" content="Git">'
             '<meta name="mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-capable" content="yes">'
             '<script src="/nav.js?v='+SHORT+'" defer></script>' + SPEC)
    doc = doc.replace('<title>Repositories</title>', '<title>Git · Repositories</title>', 1)
    return doc.replace('</head>', social_meta(doc, rel) + extra + '\n</head>', 1)

FILE_SEARCH = (
    '<div class="toolbar" id="repo-tools"><input id="fq" type="search" placeholder="Search files…" '
    'autocomplete="off" aria-label="Search files"><select id="fsort" aria-label="Sort results">'
    '<option value="rel">Best match</option><option value="az">Name A–Z</option><option value="za">Name Z–A</option>'
    '<option value="ext">File type</option></select></div>'
    '<div id="file-results" class="results" hidden><div class="results-head"><span id="file-count"></span></div><ul></ul></div>')

def build_repo_header(inner, current):
    img = re.search(r'<img[^>]*src="([^"]*)"', inner)
    h1 = re.search(r'<h1>(.*?)</h1>', inner, re.S)
    desc = re.search(r'<span class="desc">(.*?)</span>', inner, re.S)
    links = re.findall(r'<a href="([^"]+)">(.*?)</a>', inner, re.S)
    tabs = []
    for href, label in links:
        cur = href == current or (current == "index.html" and href == "files.html")
        tabs.append(f'<a href="{href}"' + (' aria-current="page"' if cur else '') + f'>{label}</a>')
    logo = (f'<a class="rh-logo" href="/"><img src="{img.group(1)}" alt="" width="36" height="36"></a>' if img else '')
    d = desc.group(1).strip() if desc else ''
    return ('<header class="repo-head"><div class="rh-top">' + logo +
            f'<h1>{h1.group(1) if h1 else ""}</h1></div>' +
            (f'<p class="rh-desc">{d}</p>' if d else '') +
            '<nav class="tabs">' + ''.join(tabs) + SHARE_BTN + '</nav></header>')

def process_repo_page(doc, repo, rel, top_level=False):
    body_open = f'<body id="top" data-repo="{H.escape(repo)}">'
    bar = f'<div class="clone-bar">{clone_rows(repo)}</div>'
    bar += (f'<div class="sync-note"><span>{sync_time("Synced")} · rebuilt hourly</span>'
            f'<a href="https://github.com/{USER}/{repo}" target="_blank" rel="noopener">Open on GitHub {ICON_GH}</a></div>')
    # File search only on the repo's Files page, not on file/commit/log pages
    if top_level and os.path.basename(rel) == "files.html":
        bar += FILE_SEARCH
    m = re.search(r'<body>\s*<table[^>]*>(.*?)</table>\s*(?:<hr\s*/?>)?', doc, re.S)
    if not m:
        return doc.replace('<body>', body_open, 1)
    header = build_repo_header(m.group(1), os.path.basename(rel))
    return doc[:m.start()] + body_open + header + bar + doc[m.end():]

def build_index(doc):
    m = re.search(r'<table id="index">(.*?)</table>', doc, re.S)
    if not m:
        return doc
    body = m.group(1)
    tb = re.search(r'<tbody>(.*?)</tbody>', body, re.S)
    rows = re.findall(r'<tr>(.*?)</tr>', (tb.group(1) if tb else body), re.S)
    items = []
    for r in rows:
        tds = re.findall(r'<td[^>]*>(.*?)</td>', r, re.S)
        if len(tds) < 3:
            continue
        lm = re.search(r'<a href="([^"]+)">(.*?)</a>', tds[0], re.S)
        if not lm:
            continue
        href, name = lm.group(1), lm.group(2)
        desc, last = tds[1].strip(), tds[-1].strip()
        if desc in ("", "No description provided."):
            desc = '<span class="muted">No description</span>'
        rname = re.sub(r'<.*?>', '', name)
        items.append(
            f'<li class="repo" data-name="{H.escape(re.sub("<.*?>","",name).lower())}" data-date="{H.escape(last)}">'
            f'<div class="repo-top"><a class="repo-name" href="{href}">{name}</a><time>{last}</time></div>'
            f'<p class="repo-desc">{desc}</p>'
            f'<div class="clone-bar compact">{clone_rows(rname)}</div></li>')
    grid = f'<ul id="index" class="repo-grid">{"".join(items)}</ul><p id="no-results" hidden>No repositories match your search.</p>'
    hero = ('<header id="hero"><div class="hero-row"><a href="/" class="hero-logo"><img src="/logo.png" alt="" width="36" height="36"></a>'
            '<h1>Repositories</h1>' + SHARE_BTN.replace('class="share"', 'class="share hero-share"') + '</div>'
            f'<p class="desc">{len(items)} public repos by <a href="https://github.com/{USER}" target="_blank" rel="noopener">@{USER}</a>'
            f' · {sync_time("synced")}</p></header>'
            '<div class="toolbar"><input id="q" type="search" placeholder="Search repos &amp; files…" autocomplete="off" aria-label="Search repositories and files">'
            '<select id="sort" aria-label="Sort repositories"><option value="updated">Newest</option>'
            '<option value="oldest">Oldest</option><option value="az">A–Z</option><option value="za">Z–A</option></select></div>'
            '<div id="file-results" class="results" hidden><div class="results-head"><span id="file-count"></span>'
            '<select id="fsort" aria-label="Sort file results"><option value="rel">Best match</option><option value="az">Name A–Z</option>'
            '<option value="za">Name Z–A</option><option value="ext">File type</option></select></div><ul></ul></div>')
    doc = re.sub(r'<body>\s*<table[^>]*>.*?</table>\s*(<hr\s*/?>)?', '<body id="top">' + hero, doc, 1, re.S)
    doc = re.sub(r'<table id="index">.*?</table>', lambda _: grid, doc, 1, re.S)
    prefetch = ('<script type="speculationrules">{"prefetch":[{"urls":[' +
                ','.join(f'"{re.search(r"""href="([^"]+)""", i).group(1)}"' for i in re.findall(r'<a class="repo-name" href="[^"]+"', ''.join(items))) +
                '],"eagerness":"eager"}]}</script>')
    return doc.replace('</head>', prefetch + '\n</head>', 1)

import json
_idx = {}
for _e in sorted(os.listdir(SITE)):
    _f = os.path.join(SITE, _e, "search.json")
    if os.path.isfile(_f):
        try:
            _idx[_e] = json.load(open(_f, encoding="utf-8"))
        except Exception:
            pass
with open(os.path.join(SITE, "search-index.json"), "w", encoding="utf-8") as _f:
    json.dump(_idx, _f, separators=(",", ":"))

count = 0
for dirpath, _d, files in os.walk(SITE):
    for fn in files:
        if not fn.endswith(".html"):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, SITE)
        parts = rel.split(os.sep)
        with open(path, encoding="utf-8", errors="ignore") as f:
            doc = f.read()
        if "id=\"site-footer\"" in doc or "</body>" not in doc:
            continue
        doc = head_inject(doc, rel)
        if rel == "index.html":
            doc = build_index(doc)
        elif len(parts) >= 2 and rel != "404.html":
            doc = process_repo_page(doc, parts[0], rel if len(parts) == 2 else os.path.basename(rel), top_level=(len(parts) == 2))
        doc = doc.replace('</body>', footer() + '\n</body>', 1)
        with open(path, "w", encoding="utf-8") as f:
            f.write(doc)
        count += 1
print(f"postprocessed {count} pages")
