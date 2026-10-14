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

def clone_cmd(repo):
    return f"git clone https://github.com/{USER}/{repo}.git"

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

def head_inject(doc):
    # Cache-bust CSS/JS: browsers kept serving the previous style.css after a deploy
    doc = re.sub(r'href="((?:\.\./)*style\.css)(?:\?[^"]*)?"', lambda m: f'href="{m.group(1)}?v={SHORT}"', doc)
    if 'name="viewport"' not in doc:
        doc = re.sub(r'<head>', '<head>\n<meta name="viewport" content="width=device-width, initial-scale=1">', doc, 1)
    extra = ('<meta name="color-scheme" content="dark"><meta name="theme-color" content="#181825">'
             '<script src="/nav.js?v='+SHORT+'" defer></script>' + SPEC)
    return doc.replace('</head>', extra + '\n</head>', 1)

def pill_nav(doc, current):
    def repl(m):
        links = re.findall(r'<a href="([^"]+)">(.*?)</a>', m.group(1), re.S)
        if not links:
            return m.group(0)
        out = []
        for href, label in links:
            cur = href == current or (current == "index.html" and href == "files.html")
            out.append(f'<a href="{href}"' + (' aria-current="page"' if cur else '') + f'>{label}</a>')
        return '<tr><td colspan="2"><nav class="tabs">' + ''.join(out) + '</nav></td></tr>'
    return re.sub(r'<tr>\s*<td>\s*</td>\s*<td>((?:(?!</td>).)*?log\.html(?:(?!</td>).)*?)</td>\s*</tr>', repl, doc, 1, re.S)

def process_repo_page(doc, repo, rel):
    doc = re.sub(r'<body>\s*<table[^>]*>', '<body id="top"><table id="header">', doc, 1)
    doc = pill_nav(doc, os.path.basename(rel))
    bar = (f'<div class="clone-bar"><span class="clone-label">clone</span>'
           f'<code>{H.escape(clone_cmd(repo))}</code>{copy_btn(clone_cmd(repo))}'
           f'<a class="gh" href="https://github.com/{USER}/{repo}" target="_blank" rel="noopener">GitHub {ICON_GH}</a></div>')
    if re.search(r'<hr\s*/?>', doc):
        doc = re.sub(r'<hr\s*/?>', bar, doc, 1)
    elif '</table>' in doc:
        doc = doc.replace('</table>', '</table>' + bar, 1)
    return doc

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
        cmd = clone_cmd(re.sub(r'<.*?>', '', name))
        items.append(
            f'<li class="repo" data-name="{H.escape(re.sub("<.*?>","",name).lower())}">'
            f'<div class="repo-top"><a class="repo-name" href="{href}">{name}</a><time>{last}</time></div>'
            f'<p class="repo-desc">{desc}</p>'
            f'<div class="clone-bar compact"><code>{H.escape(cmd)}</code>{copy_btn(cmd, "")}</div></li>')
    grid = f'<ul id="index" class="repo-grid">{"".join(items)}</ul><p id="no-results" hidden>No repositories match your search.</p>'
    hero = (f'<header id="hero"><a href="/" class="hero-logo"><img src="/logo.png" alt="" width="44" height="44"></a>'
            f'<div><h1>Repositories</h1><p class="desc">{len(items)} public repos by <a href="https://github.com/{USER}" target="_blank" rel="noopener">@{USER}</a> · mirrored hourly</p></div></header>'
            f'<div class="search"><input id="q" type="search" placeholder="Filter repositories…" autocomplete="off" aria-label="Filter repositories"></div>')
    doc = re.sub(r'<body>\s*<table[^>]*>.*?</table>\s*(<hr\s*/?>)?', '<body id="top">' + hero, doc, 1, re.S)
    doc = re.sub(r'<table id="index">.*?</table>', lambda _: grid, doc, 1, re.S)
    prefetch = ('<script type="speculationrules">{"prefetch":[{"urls":[' +
                ','.join(f'"{re.search(r"""href="([^"]+)""", i).group(1)}"' for i in re.findall(r'<a class="repo-name" href="[^"]+"', ''.join(items))) +
                '],"eagerness":"eager"}]}</script>')
    return doc.replace('</head>', prefetch + '\n</head>', 1)

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
        doc = head_inject(doc)
        if rel == "index.html":
            doc = build_index(doc)
        elif len(parts) >= 2 and rel != "404.html":
            doc = process_repo_page(doc, parts[0], rel if len(parts) == 2 else os.path.basename(rel))
        doc = doc.replace('</body>', footer() + '\n</body>', 1)
        with open(path, "w", encoding="utf-8") as f:
            f.write(doc)
        count += 1
print(f"postprocessed {count} pages")
