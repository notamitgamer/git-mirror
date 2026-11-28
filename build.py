#!/usr/bin/env python3
"""git-mirror: a static, Forgejo/Codeberg-style mirror of a GitHub user's public repos.

Plain `git` + Python (markdown-it-py, Pygments). No compiled dependencies.
Every page is pre-rendered HTML; nothing is rendered at request time.

Environment (all optional):
  MIRROR_USER      GitHub account to mirror      (default: repo owner or notamitgamer)
  MIRROR_EXCLUDE   comma list of repos to skip   (this repo is always skipped)
  MIRROR_DEPTH     history depth to clone        (default: 200)
  MIRROR_BASE_URL  public site URL               (default: Pages URL / CNAME file / github.io)
  GH_TOKEN         token for API rate limits     (default: unauthenticated)
"""
import base64
import hashlib
import html
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(ROOT, "assets")
SITE = os.path.join(ROOT, "site")
CACHE = os.path.join(ROOT, ".cache")

USER = os.environ.get("MIRROR_USER") or os.environ.get("GITHUB_REPOSITORY_OWNER") or "notamitgamer"
SELF_REPO = os.environ.get("GITHUB_REPOSITORY") or f"{USER}/git-mirror"
EXCLUDE = {x.strip() for x in os.environ.get("MIRROR_EXCLUDE", "").split(",") if x.strip()} | {SELF_REPO.split("/")[-1]}
DEPTH = int(os.environ.get("MIRROR_DEPTH", "200"))
COMMIT_PAGES = 50          # commit pages (with diffs) rendered per repo
MAX_BLOB = 300_000         # bigger text files are not rendered
MAX_HIGHLIGHT = 150_000    # bigger text files are rendered without syntax colours
MAX_DIFF_FILE = 1500       # diff lines per file before collapsing
MAX_DIFF_TOTAL = 5000      # diff lines per commit before truncating
MAX_FILES = 4000           # blob pages per branch
MAX_BRANCHES = int(os.environ.get("MIRROR_BRANCHES") or 10)   # browsable non-default branches per repo
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""

# What the home page says about timing. Only claim an interval when something really triggers it.
REBUILD_NOTE = os.environ.get("MIRROR_REBUILD_NOTE") or "rebuilt automatically"

CFG = {}  # filled in main(), re-applied in workers


# ───────────────────────────── helpers ─────────────────────────────

def esc(s):
    return html.escape(str(s), quote=True)


def q(path):
    return urllib.parse.quote(path, safe="/")


def log(*a):
    print(*a, flush=True)


def api(path):
    req = urllib.request.Request("https://api.github.com" + path, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "git-mirror-builder",
        **({"Authorization": f"Bearer {TOKEN}"} if TOKEN else {}),
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def retry(fn, tries=3, delay=3):
    for i in range(tries):
        try:
            return fn()
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(delay * (i + 1))


GITENV = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C.UTF-8"}


def git(bare, *args, check=True, timeout=300):
    p = subprocess.run(["git", "-c", "core.quotepath=false", "-C", bare, *args],
                       capture_output=True, env=GITENV, timeout=timeout)
    if check and p.returncode:
        raise RuntimeError(f"git {' '.join(args[:3])} failed: {p.stderr.decode('utf-8', 'replace')[:300]}")
    return p.stdout.decode("utf-8", "replace")


class CatFile:
    """One long-lived `git cat-file --batch` so reading thousands of blobs is cheap."""

    def __init__(self, bare):
        self.p = subprocess.Popen(["git", "-C", bare, "cat-file", "--batch"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, env=GITENV)

    def read(self, sha):
        self.p.stdin.write(sha.encode() + b"\n")
        self.p.stdin.flush()
        head = self.p.stdout.readline().split()
        if len(head) < 3:
            return b""
        size = int(head[2])
        data = self.p.stdout.read(size)
        self.p.stdout.read(1)
        return data

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()


_TAG = re.compile(r"<[a-zA-Z][^<>]*>")
_ROOTED = re.compile(r'(\s(?:href|src)=")/(?!/)')


def prefix_links(page, prefix):
    """Move root-relative links under the Pages sub-path. Only touches real tags: shown code is escaped."""
    if not prefix:
        return page
    page = _TAG.sub(lambda m: _ROOTED.sub(lambda a: a.group(1) + prefix + "/", m.group(0)), page)
    return page.replace('"href_matches": "/*"', f'"href_matches": "{prefix}/*"')


def write(path, content):
    if path.endswith(".html"):
        content = prefix_links(content, CFG.get("prefix", ""))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)


def page_file(urlpath):
    return os.path.join(SITE, urlpath.strip("/"), "index.html")


def iso(ts):
    return datetime.fromtimestamp(int(ts), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def abs_date(ts):
    return datetime.fromtimestamp(int(ts), timezone.utc).strftime("%b %-d, %Y")


def timetag(ts):
    return f'<time class="rt" datetime="{iso(ts)}">{abs_date(ts)}</time>'


def human_size(n):
    n = int(n)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n} {unit}" if unit == "B" else f"{n:.1f} {unit}".replace(".0 ", " ")
        n /= 1024


def plural(n, word, suffix="s"):
    return f"{n} {word}" if n == 1 else f"{n} {word}{suffix}"


def hue(name):
    return int(hashlib.md5(name.encode("utf-8", "replace")).hexdigest()[:4], 16) % 360


def avatar(name):
    ch = (name.strip()[:1] or "?").upper()
    return f'<span class="av" style="--h:{hue(name)}" aria-hidden="true">{esc(ch)}</span>'


# ───────────────────────────── icons ─────────────────────────────

_I = {
    "repo": ("0 0 24 24", '<path d="M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H20v20H6.5a2.5 2.5 0 0 1 0-5H20"/>'),
    "folder": ("0 0 24 24", '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>'),
    "file": ("0 0 24 24", '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>'),
    "branch": ("0 0 24 24", '<line x1="6" x2="6" y1="3" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/>'),
    "tag": ("0 0 24 24", '<path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/><circle cx="7.5" cy="7.5" r=".5" fill="currentColor"/>'),
    "commit": ("0 0 24 24", '<circle cx="12" cy="12" r="3"/><line x1="3" x2="9" y1="12" y2="12"/><line x1="15" x2="21" y1="12" y2="12"/>'),
    "star": ("0 0 24 24", '<path d="M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z"/>'),
    "fork": ("0 0 24 24", '<circle cx="12" cy="18" r="3"/><circle cx="6" cy="6" r="3"/><circle cx="18" cy="6" r="3"/><path d="M18 9v2c0 .6-.4 1-1 1H7c-.6 0-1-.4-1-1V9"/><path d="M12 12v3"/>'),
    "ext": ("0 0 24 24", '<path d="M15 3h6v6M10 14 21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>'),
    "copy": ("0 0 24 24", '<rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>'),
    "check": ("0 0 24 24", '<path d="M20 6 9 17l-5-5"/>'),
    "down": ("0 0 24 24", '<path d="m6 9 6 6 6-6"/>'),
    "search": ("0 0 24 24", '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>'),
    "share": ("0 0 24 24", '<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" x2="15.42" y1="13.51" y2="17.49"/><line x1="15.41" x2="8.59" y1="6.51" y2="10.49"/>'),
    "download": ("0 0 24 24", '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/><path d="M12 15V3"/>'),
    "code": ("0 0 24 24", '<path d="m16 18 6-6-6-6M8 6l-6 6 6 6"/>'),
    "pin": ("0 0 24 24", '<path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0Z"/><circle cx="12" cy="10" r="3"/>'),
    "link": ("0 0 24 24", '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>'),
    "law": ("0 0 24 24", '<path d="M12 3v18M5 7h14M5 7l-3 7a3.5 3.5 0 0 0 6 0Zm14 0-3 7a3.5 3.5 0 0 0 6 0ZM8 21h8"/>'),
    "clock": ("0 0 24 24", '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>'),
    "github": ("0 0 16 16", '<path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/>'),
}


def icon(name, cls=""):
    vb, body = _I[name]
    c = "i f" if name == "github" else "i"
    if cls:
        c += " " + cls
    return f'<svg class="{c}" viewBox="{vb}" width="16" height="16" aria-hidden="true">{body}</svg>'


# ───────────────────────────── languages ─────────────────────────────

LANGS = {
    ".c": ("C", "#555555"), ".h": ("C", "#555555"), ".cpp": ("C++", "#f34b7d"), ".cc": ("C++", "#f34b7d"),
    ".hpp": ("C++", "#f34b7d"), ".cs": ("C#", "#178600"), ".java": ("Java", "#b07219"),
    ".py": ("Python", "#3572A5"), ".js": ("JavaScript", "#f1e05a"), ".mjs": ("JavaScript", "#f1e05a"),
    ".jsx": ("JavaScript", "#f1e05a"), ".ts": ("TypeScript", "#3178c6"), ".tsx": ("TypeScript", "#3178c6"),
    ".html": ("HTML", "#e34c26"), ".htm": ("HTML", "#e34c26"), ".css": ("CSS", "#563d7c"),
    ".scss": ("SCSS", "#c6538c"), ".less": ("Less", "#1d365d"), ".rs": ("Rust", "#dea584"),
    ".go": ("Go", "#00ADD8"), ".kt": ("Kotlin", "#A97BFF"), ".kts": ("Kotlin", "#A97BFF"),
    ".sh": ("Shell", "#89e051"), ".bash": ("Shell", "#89e051"), ".php": ("PHP", "#4F5D95"),
    ".rb": ("Ruby", "#701516"), ".swift": ("Swift", "#F05138"), ".lua": ("Lua", "#000080"),
    ".mdx": ("MDX", "#fcb32c"), ".vue": ("Vue", "#41b883"), ".svelte": ("Svelte", "#ff3e00"),
    ".sql": ("SQL", "#e38c00"), ".dart": ("Dart", "#00B4AB"), ".ps1": ("PowerShell", "#012456"),
    ".bat": ("Batchfile", "#C1F12E"), ".asm": ("Assembly", "#6E4C13"), ".r": ("R", "#198CE7"),
}


def language_bar(files):
    sizes = {}
    for path, size in files:
        ext = posixpath.splitext(path)[1].lower()
        if ext in LANGS:
            name, col = LANGS[ext]
            s = sizes.setdefault(name, [0, col])
            s[0] += size
    total = sum(v[0] for v in sizes.values())
    if not total:
        return ""
    items = sorted(sizes.items(), key=lambda kv: -kv[1][0])
    bar = "".join(f'<span style="width:{max(v[0] * 100 / total, 1):.2f}%;background:{v[1]}" title="{esc(k)}"></span>'
                  for k, v in items)
    legend = "".join(f'<li><i style="background:{v[1]}"></i><b>{esc(k)}</b> <span>{v[0] * 100 / total:.1f}%</span></li>'
                     for k, v in items[:8])
    return f'<div class="lbar">{bar}</div><ul class="llist">{legend}</ul>'


# ───────────────────────────── markdown ─────────────────────────────

_md = None


def markdown_engine():
    global _md
    if _md is None:
        from markdown_it import MarkdownIt
        try:
            _md = MarkdownIt("gfm-like", {"html": True})
        except Exception:
            _md = MarkdownIt("commonmark", {"html": True}).enable("table").enable("strikethrough")
    return _md


_ABS = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//|#)", re.I)


_SAFE_TAGS = set("a abbr b blockquote br caption cite code dd del details dfn div dl dt em figcaption figure h1 h2 h3 h4 h5 h6 hr i img ins "
                 "kbd li mark ol p picture pre q rp rt ruby s samp small source span strike strong sub summary sup table tbody td tfoot th "
                 "thead tr tt ul var center input".split())
_DROP = {"script", "style", "iframe", "object", "template", "noscript", "textarea", "select", "title", "svg", "math"}
_VOID = {"br", "hr", "img", "source", "input"}
_SAFE_ATTRS = {"href", "src", "srcset", "media", "alt", "title", "align", "valign", "width", "height", "colspan", "rowspan",
               "open", "start", "class", "type", "checked", "disabled", "loading"}


def _safe_url(v):
    scheme = re.match(r"([a-z][a-z0-9+.-]*):", re.sub(r"[\x00-\x20]", "", v).lower())
    return not scheme or scheme.group(1) in ("http", "https", "mailto")


class _Sanitizer(HTMLParser):
    """Rebuilds HTML from an allowlist, so anything not listed (and every stray "<") cannot survive."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out, self.open, self.dropping = [], [], []

    def handle_starttag(self, tag, attrs):
        if tag in _DROP:
            self.dropping.append(tag)
        if self.dropping or tag not in _SAFE_TAGS:
            return
        attrs = dict(attrs)
        if tag == "input" and attrs.get("type") != "checkbox":
            return
        keep = []
        for k, v in attrs.items():
            v = v or ""
            if k not in _SAFE_ATTRS or (k in ("href", "src", "srcset") and not _safe_url(v)):
                continue
            if k == "class" and not re.fullmatch(r"language-[\w+#.-]+", v):
                continue
            keep.append(f' {k}="{esc(v)}"')
        if tag == "input":
            keep.append(' disabled=""' if "disabled" not in attrs else "")
        self.out.append(f"<{tag}{''.join(keep)}>")
        if tag not in _VOID:
            self.open.append(tag)

    def handle_endtag(self, tag):
        if self.dropping:
            if tag == self.dropping[-1]:
                self.dropping.pop()
            return
        if tag in self.open:      # close anything left open inside it, never a tag of the surrounding page
            while self.open:
                t = self.open.pop()
                self.out.append(f"</{t}>")
                if t == tag:
                    break

    def handle_data(self, data):
        if not self.dropping:
            self.out.append(html.escape(data, quote=False))


def sanitize(fragment):
    p = _Sanitizer()
    p.feed(fragment)
    p.close()
    return "".join(p.out) + "".join(f"</{t}>" for t in reversed(p.open))


def render_markdown(text, repo, branch, base_dir, tree_files, tree_dirs, root=None):
    root = root or f"/{q(repo)}"
    out = markdown_engine().render(text)
    out = sanitize(out)

    def fix(m):
        attr, val = m.group(1), m.group(2)
        v = html.unescape(val)
        if _ABS.match(v):
            return m.group(0)
        pth, _, frag = v.partition("#")
        pth = pth.split("?")[0]
        full = posixpath.normpath(posixpath.join(base_dir, urllib.parse.unquote(pth))) if not pth.startswith("/") \
            else posixpath.normpath(urllib.parse.unquote(pth).lstrip("/"))
        if full in (".", ""):
            full = ""
        if attr.lower() == "src":
            return f'src="https://raw.githubusercontent.com/{USER}/{repo}/{q(branch)}/{q(full)}"'
        if full in tree_files:
            return f'href="{root}/blob/{q(full)}/{"#" + frag if frag else ""}"'
        if full in tree_dirs:
            return f'href="{root}/tree/{q(full)}/"'
        if full == "":
            return f'href="{root}/"'
        return f'href="https://github.com/{USER}/{q(repo)}/blob/{q(branch)}/{q(full)}"'

    out = re.sub(r'\b(href|src)="([^"]*)"', fix, out)
    out = re.sub(r"<img\b(?![^>]*\bloading=)", '<img loading="lazy"', out)
    out = re.sub(r"<table\b", '<div class="tbl"><table', out)
    out = out.replace("</table>", "</table></div>")
    seen = {}

    def head(m):
        lvl, inner = m.group(1), m.group(2)
        slug = re.sub(r"[^\w\- ]", "", re.sub(r"<[^>]+>", "", html.unescape(inner)).strip().lower(), flags=re.U)
        slug = re.sub(r"\s", "-", slug) or "section"
        n = seen.get(slug, 0)
        seen[slug] = n + 1
        if n:
            slug += f"-{n}"
        return f'<h{lvl} id="{esc(slug)}">{inner}<a class="anc" href="#{esc(slug)}" aria-hidden="true">#</a></h{lvl}>'

    out = re.sub(r"<h([1-6])>(.*?)</h\1>", head, out, flags=re.S)
    return out


# ───────────────────────────── syntax highlighting ─────────────────────────────

_lexers = {}


def get_lexer(filename):
    from pygments.lexers import get_lexer_for_filename
    from pygments.lexers.special import TextLexer
    from pygments.util import ClassNotFound
    key = posixpath.splitext(filename)[1].lower() or filename
    if key not in _lexers:
        try:
            _lexers[key] = get_lexer_for_filename(filename, stripnl=False, ensurenl=False)
        except ClassNotFound:
            _lexers[key] = TextLexer(stripnl=False, ensurenl=False)
    return _lexers[key]


def tok_class(tt):
    from pygments.token import STANDARD_TYPES
    while tt is not None and tt not in STANDARD_TYPES:
        tt = tt.parent
    return STANDARD_TYPES.get(tt, "") if tt is not None else ""


def highlight_lines(text, filename, colour=True):
    if not colour:
        lines = text.replace("\r\n", "\n").split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        return [esc(l) for l in lines]
    out, cur = [], []
    try:
        for tt, val in get_lexer(filename).get_tokens(text):
            cls = tok_class(tt)
            parts = val.split("\n")
            for i, part in enumerate(parts):
                if i:
                    out.append("".join(cur))
                    cur = []
                if part:
                    e = html.escape(part, quote=False)
                    cur.append(f'<span class="t-{cls}">{e}</span>' if cls else e)
    except Exception:
        return highlight_lines(text, filename, colour=False)
    out.append("".join(cur))
    if out and out[-1] == "" and text.endswith("\n"):
        out.pop()
    return out


# ───────────────────────────── layout ─────────────────────────────

SPEC_RULES = json.dumps({"prefetch": [{"where": {"href_matches": "/*"}, "eagerness": "eager"}]})


def layout(title, main, *, path="/", desc="", cls="", noindex=False):
    base, v = CFG["base"], CFG["v"]
    full_title = esc(title)
    desc = esc(desc or f"Static mirror of {USER}'s public repositories")
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>{full_title}</title>
<meta name="description" content="{desc}">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#181825">
{'<meta name="robots" content="noindex">' if noindex else ''}
<link rel="canonical" href="{esc(base + q(path))}">
<link rel="icon" href="/favicon.png" type="image/png">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/manifest.webmanifest">
<meta property="og:type" content="website">
<meta property="og:site_name" content="{esc(USER)} · git">
<meta property="og:title" content="{full_title}">
<meta property="og:description" content="{desc}">
<meta property="og:url" content="{esc(base + q(path))}">
<meta property="og:image" content="{esc(base)}/icon-512.png">
<meta name="twitter:card" content="summary">
<link rel="stylesheet" href="/style.css?v={v}">
<script src="/app.js?v={v}" defer></script>
<script type="speculationrules">{SPEC_RULES}</script>
</head>
<body data-base="{CFG.get("prefix", "")}">
<header class="nav"><div class="wrap nav-in">
<a class="brand" href="/"><img src="/icon.svg" width="26" height="26" alt=""><span>{esc(USER)}<em>/git</em></span></a>
<form class="search" role="search" onsubmit="return false"><span class="si">{icon('search')}</span><input id="q" type="search" placeholder="Search repos and files…" autocomplete="off" autocapitalize="off" spellcheck="false" aria-label="Search repositories and files"><kbd>/</kbd><div id="results" hidden></div></form>
<a class="nbtn" href="https://github.com/{esc(USER)}" rel="noopener" title="GitHub profile" aria-label="GitHub profile">{icon('github')}<span>GitHub</span></a>
<button class="nbtn" id="install" type="button" title="Install app" aria-label="Install app" hidden>{icon('download')}<span>Install</span></button>
<button class="nbtn" id="share" type="button" title="Share" aria-label="Share">{icon('share')}</button>
</div></header>
<main id="main" class="{esc(cls)}">
{main}
</main>
<footer class="foot"><div class="wrap">
<span>Static mirror of <a href="https://github.com/{esc(USER)}" rel="noopener">@{esc(USER)}</a>&rsquo;s public repositories</span>
<span><a href="https://github.com/{esc(SELF_REPO)}" rel="noopener">Source</a> · <a href="/last_commit" data-nopjax>Build info</a></span>
</div></footer>
<button id="top" type="button" aria-label="Back to top" hidden>&#8593;</button>
</body>
</html>
"""


def crumbs(repo, parts, last_is_file=False, root=None):
    root = root or f"/{q(repo)}"
    """repo / dir / file breadcrumb."""
    out = [f'<a href="{root}/">{esc(repo)}</a>']
    acc = []
    for i, p in enumerate(parts):
        acc.append(p)
        if i == len(parts) - 1:
            out.append(f"<b>{esc(p)}</b>")
        else:
            out.append(f'<a href="{root}/tree/{q("/".join(acc))}/">{esc(p)}</a>')
    return '<nav class="crumbs" aria-label="Path">' + '<i>/</i>'.join(out) + "</nav>"


def repo_head(meta, active, counts):
    repo = meta["name"]
    gh = f"https://github.com/{USER}/{repo}"
    badges = ""
    if meta.get("fork"):
        badges += '<span class="badge">Fork</span>'
    if meta.get("archived"):
        badges += '<span class="badge warn">Archived</span>'
    badges += '<span class="badge">Public</span>'
    tabs = [
        ("code", f"/{q(repo)}/", "code", "Code", None),
        ("commits", f"/{q(repo)}/commits/", "commit", "Commits", counts.get("commits")),
        ("branches", f"/{q(repo)}/branches/", "branch", "Branches", counts.get("branches")),
        ("tags", f"/{q(repo)}/tags/", "tag", "Tags", counts.get("tags")),
        ("issues", f"/{q(repo)}/issues/", "clock", "Issues", counts.get("issues")),
        ("pulls", f"/{q(repo)}/pulls/", "fork", "Pull requests", counts.get("pulls")),
        ("releases", f"/{q(repo)}/releases/", "download", "Releases", counts.get("releases")),
    ]
    tabs_html = "".join(
        f'<a class="tab{" on" if k == active else ""}" href="{h}">{icon(ic)}<span>{lab}</span>'
        f'{f"<em>{c}</em>" if c is not None else ""}</a>' for k, h, ic, lab, c in tabs)
    tabs_html += f'<a class="tab ext" href="{gh}" rel="noopener">{icon("github")}<span>GitHub</span>{icon("ext", "xs")}</a>'
    desc = f'<p class="rdesc">{esc(meta["description"])}</p>' if meta.get("description") else ""
    return f"""<section class="rhead"><div class="wrap">
<div class="rtitle"><h1>{icon('repo')}<a href="/">{esc(USER)}</a><i>/</i><a class="rn" href="/{q(repo)}/">{esc(repo)}</a></h1>{badges}
<div class="rcounts"><a class="cbtn" href="{gh}/stargazers" rel="noopener">{icon('star')}<span>Stars</span><b>{meta.get('stargazers_count', 0)}</b></a><a class="cbtn" href="{gh}/forks" rel="noopener">{icon('fork')}<span>Forks</span><b>{meta.get('forks_count', 0)}</b></a></div></div>
{desc}
<nav class="tabs" aria-label="Repository">{tabs_html}</nav>
</div></section>"""


# ───────────────────────────── diff parsing ─────────────────────────────

_HUNK = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$")


def parse_diff(text):
    files, cur, hunk, o, n = [], None, None, 0, 0
    for line in text.split("\n"):
        if line.startswith("diff --git "):
            m = re.match(r"diff --git a/(.*?) b/(.*)$", line)
            cur = {"a": m.group(1) if m else "", "b": m.group(2) if m else "", "status": "modified",
                   "binary": False, "add": 0, "del": 0, "hunks": [], "lines": 0}
            files.append(cur)
            hunk = None
            continue
        if cur is None:
            continue
        m = _HUNK.match(line) if line.startswith("@@") else None
        if m:
            o, n = int(m.group(1)), int(m.group(2))
            hunk = {"head": line, "lines": []}
            cur["hunks"].append(hunk)
            continue
        if hunk is None:
            if line.startswith("new file mode"):
                cur["status"] = "added"
            elif line.startswith("deleted file mode"):
                cur["status"] = "deleted"
            elif line.startswith("rename from "):
                cur["status"] = "renamed"
                cur["a"] = line[12:]
            elif line.startswith("rename to "):
                cur["b"] = line[10:]
            elif line.startswith("Binary files") or line.startswith("GIT binary patch"):
                cur["binary"] = True
            continue
        if line.startswith("+"):
            hunk["lines"].append(("+", "", n, line[1:]))
            n += 1
            cur["add"] += 1
            cur["lines"] += 1
        elif line.startswith("-"):
            hunk["lines"].append(("-", o, "", line[1:]))
            o += 1
            cur["del"] += 1
            cur["lines"] += 1
        elif line.startswith(" "):
            hunk["lines"].append((" ", o, n, line[1:]))
            o += 1
            n += 1
            cur["lines"] += 1
        elif line.startswith("\\"):
            hunk["lines"].append(("\\", "", "", line))
    return files


def render_diff(files):
    out, total = [], 0
    for idx, f in enumerate(files):
        name = f["b"] if f["status"] != "deleted" else f["a"]
        title = f'{esc(f["a"])} → {esc(f["b"])}' if f["status"] == "renamed" else esc(name)
        stat = f'<span class="plus">+{f["add"]}</span> <span class="minus">−{f["del"]}</span>'
        tag = {"added": '<span class="badge ok">added</span>', "deleted": '<span class="badge bad">deleted</span>',
               "renamed": '<span class="badge">renamed</span>'}.get(f["status"], "")
        body = ""
        if f["binary"]:
            body = '<div class="dnote">Binary file not shown.</div>'
        elif f["lines"] > MAX_DIFF_FILE or total + f["lines"] > MAX_DIFF_TOTAL:
            body = '<div class="dnote">Diff too large to display here — view it on GitHub.</div>'
        elif not f["hunks"]:
            body = '<div class="dnote">No content changes.</div>'
        else:
            total += f["lines"]
            rows = []
            for h in f["hunks"]:
                rows.append(f'<tr class="hk"><td class="n"></td><td class="n"></td><td class="c">{esc(h["head"])}</td></tr>')
                for t, o, n, txt in h["lines"]:
                    cls = {"+": "add", "-": "del"}.get(t, "ctx")
                    mark = t if t in "+-" else " "
                    rows.append(f'<tr class="{cls}"><td class="n">{o}</td><td class="n">{n}</td><td class="c">{mark}{esc(txt)}</td></tr>')
            body = f'<div class="dscroll"><table class="dt">{"".join(rows)}</table></div>'
        out.append(f'<section class="dfile" id="f{idx}"><header><b>{title}</b>{tag}<span class="st">{stat}</span></header>{body}</section>')
    return "".join(out)


# ───────────────────────────── per-repo rendering ─────────────────────────────

README_NAMES = ("readme.md", "readme.markdown", "readme.mdx", "readme.txt", "readme.rst", "readme")
IMG_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".ico", ".bmp", ".avif"}


def sync_repo(name, bare):
    url = f"https://github.com/{USER}/{name}.git"
    if os.path.isdir(bare):
        try:
            git(bare, "fetch", "--prune", "--force", "--depth", str(DEPTH), url,
                "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*", timeout=600)
            return
        except Exception as e:
            log(f"  ! fetch failed for {name}, re-cloning: {e}")
            shutil.rmtree(bare, ignore_errors=True)
    os.makedirs(os.path.dirname(bare), exist_ok=True)
    p = subprocess.run(["git", "clone", "--bare", "--quiet", "--depth", str(DEPTH), "--no-single-branch", url, bare],
                       capture_output=True, env=GITENV, timeout=900)
    if p.returncode:
        raise RuntimeError("clone failed: " + p.stderr.decode("utf-8", "replace")[:300])


def read_commits(bare, head):
    """Attribution pass: every commit in the clone with the files it touched."""
    raw = git(bare, "log", "-n", str(DEPTH), "-z", "--name-only", "--no-renames",
              "--format=%x01%H%x02%at%x02%s", head)
    shallow = set()
    sp = os.path.join(bare, "shallow")
    if os.path.exists(sp):
        shallow = set(open(sp).read().split())
    commits = []
    for chunk in raw.split("\x01"):
        if not chunk.strip("\0\n"):
            continue
        parts = chunk.split("\0")
        sha, ts, subj = (parts[0].split("\x02") + ["", ""])[:3]
        paths = [p.lstrip("\n") for p in parts[1:] if p.strip("\n")]
        commits.append({"sha": sha, "ts": int(ts or 0), "subject": subj, "paths": paths, "boundary": sha in shallow})
    return commits, bool(shallow)


def read_details(bare, head):
    """Detail pass: authors, bodies and patches for the newest COMMIT_PAGES commits."""
    raw = git(bare, "log", "-n", str(COMMIT_PAGES), "-p", "-M", "--unified=3",
              "--format=%x01%H%x02%P%x02%an%x02%ae%x02%at%x02%s%x02%b%x03", head)
    out = []
    for chunk in raw.split("\x01"):
        if "\x03" not in chunk:
            continue
        hdr, patch = chunk.split("\x03", 1)
        f = (hdr.split("\x02") + [""] * 7)[:7]
        out.append({"sha": f[0], "parents": f[1].split(), "author": f[2], "email": f[3],
                    "ts": int(f[4] or 0), "subject": f[5], "body": f[6].strip(), "patch": patch})
    # `git log -p` prints nothing for merges: show them as the diff against the first parent
    for d in out:
        if len(d["parents"]) > 1:
            d["patch"] = git(bare, "diff", "-M", "--unified=3", d["parents"][0], d["sha"], check=False)
    return out


def fetch_releases(name):
    """Newest 30 published releases. Files are not copied: download links go straight to GitHub."""
    path = os.path.join(CACHE, "releases", name + ".json")
    try:
        data = retry(lambda: api(f"/repos/{USER}/{urllib.parse.quote(name)}/releases?per_page=30"))
        rels = [{"tag": r["tag_name"], "name": r.get("name") or r["tag_name"], "body": r.get("body") or "",
                 "pre": bool(r.get("prerelease")), "date": r.get("published_at") or "", "url": r.get("html_url") or "",
                 "zip": r.get("zipball_url") and f"https://github.com/{USER}/{q(name)}/archive/refs/tags/{q(r['tag_name'])}",
                 "assets": [{"name": a["name"], "size": a.get("size", 0), "count": a.get("download_count", 0),
                             "url": a["browser_download_url"]} for a in r.get("assets", [])]}
                for r in data if not r.get("draft")]
        write(path, json.dumps(rels))
        return rels
    except Exception as e:
        log(f"  ! releases for {name} not fetched ({e}); using cached copy")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        return []


def releases_html(rels, name, branch, tree_files, tree_dirs):
    latest = next((r for r in rels if not r["pre"]), None)
    out = []
    for r in rels:
        badge = '<span class="badge warn">Pre-release</span>' if r["pre"] else ('<span class="badge ok">Latest</span>' if r is latest else "")
        when = ""
        if r["date"]:
            when = timetag(int(datetime.fromisoformat(r["date"].replace("Z", "+00:00")).timestamp()))
        rows = [f'<div class="rr"><a class="rn2" href="{esc(a["url"])}" rel="noopener">{icon("download")}<span>{esc(a["name"])}</span></a>'
                f'<span class="fm">{human_size(a["size"])}</span><span class="ft">{plural(a["count"], "download")}</span></div>' for a in r["assets"]]
        if r["zip"]:
            for ext, label in ((".zip", "Source code (zip)"), (".tar.gz", "Source code (tar.gz)")):
                rows.append(f'<div class="rr"><a class="rn2" href="{esc(r["zip"] + ext)}" rel="noopener">{icon("code")}<span>{label}</span></a><span class="fm"></span></div>')
        notes = f'<div class="md">{render_markdown(r["body"], name, branch, "", tree_files, tree_dirs)}</div>' if r["body"].strip() else ""
        out.append(f'<section class="release card" id="rel-{esc(r["tag"])}"><header>{icon("tag")}<b>{esc(r["name"])}</b>{badge}<span class="mu">{esc(r["tag"])} {when}</span>'
                   f'<a class="btn sm" href="{esc(r["url"])}" rel="noopener">GitHub{icon("ext", "xs")}</a></header>{notes}<div class="assets">{"".join(rows)}</div></section>')
    return "".join(out) or '<div class="ftable"><div class="empty">No releases yet.</div></div>'


def cached_json(path, fetch, empty):
    """Fetch API data, falling back to the last good copy."""
    try:
        data = retry(fetch)
        write(path, json.dumps(data))
        return data
    except Exception as e:
        log(f"  ! {os.path.basename(path)} not fetched ({e}); using cached copy")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        return empty


def fetch_extras(name):
    base = f"/repos/{USER}/{urllib.parse.quote(name)}"

    def contributors():
        return [{"login": c["login"], "avatar": c["avatar_url"], "url": c["html_url"], "n": c["contributions"]}
                for c in (api(base + "/contributors?per_page=30") or [])]

    def deployments():
        seen, out = set(), []
        for d in api(base + "/deployments?per_page=30"):
            env = d.get("environment") or "production"
            if env in seen or len(seen) >= 5:
                continue
            seen.add(env)
            st = api(f"{base}/deployments/{d['id']}/statuses?per_page=10")
            url = next((x["environment_url"] for x in st if x.get("environment_url")), "")
            if url.startswith(("https://", "http://")):
                out.append({"env": env, "url": url, "date": d.get("created_at") or ""})
        return out

    return {"contributors": cached_json(os.path.join(CACHE, "contributors", name + ".json"), contributors, []),
            "deployments": cached_json(os.path.join(CACHE, "deployments", name + ".json"), deployments, [])}


def extras_html(meta):
    out = ""
    deps = meta.get("deployments") or []
    if deps:
        rows = "".join(f'<p class="kv">{icon("link")}<a href="{esc(d["url"])}" rel="noopener" title="{esc(d["url"])}">{esc(d["env"])}</a></p>' for d in deps)
        out += f'<section class="card"><h3>Deployments</h3>{rows}</section>'
    people = meta.get("contributors") or []
    if people:
        faces = "".join(f'<a href="{esc(c["url"])}" rel="noopener" title="{esc(c["login"])}: {plural(c["n"], "commit")}">'
                        f'<img src="{esc(c["avatar"])}&s=64" alt="{esc(c["login"])}" width="32" height="32" loading="lazy"></a>' for c in people)
        out += f'<section class="card"><h3>Contributors</h3><div class="faces">{faces}</div></section>'
    return out


def graphql(query, variables):
    req = urllib.request.Request("https://api.github.com/graphql", data=json.dumps({"query": query, "variables": variables}).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "User-Agent": "git-mirror-builder"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if out.get("errors"):
        raise RuntimeError(out["errors"][0].get("message"))
    return out["data"]


def fetch_home_extras():
    d = lambda n: os.path.join(CACHE, "home", n + ".json")

    def calendar():
        return graphql("query($u:String!){user(login:$u){contributionsCollection{contributionCalendar{totalContributions "
                       "weeks{contributionDays{date contributionCount contributionLevel weekday}}}}}}",
                       {"u": USER})["user"]["contributionsCollection"]["contributionCalendar"]

    def readme():
        r = api(f"/repos/{USER}/{USER}/readme")
        return base64.b64decode(r["content"]).decode("utf-8", "replace")

    return {"calendar": cached_json(d("calendar"), calendar, None) if TOKEN else None,
            "readme": cached_json(d("readme"), readme, ""),
            "social": cached_json(d("social"), lambda: api(f"/users/{USER}/social_accounts"), []),
            "orgs": cached_json(d("orgs"), lambda: api(f"/users/{USER}/orgs"), [])}


def recent_commits(names, profile, limit=15):
    mine = {USER.lower(), (profile.get("name") or USER).lower()}
    found = {}
    for name in names:
        bare = os.path.join(CACHE, "repos", name + ".git")
        if not os.path.isdir(bare):
            continue
        raw = git(bare, "log", "--branches", "--no-merges", "-n", "100", "--format=%H%x1f%an%x1f%ae%x1f%at%x1f%s", check=False)
        for ln in raw.split("\n"):
            f = ln.split("\x1f")
            if len(f) == 5 and (f[1].lower() in mine or USER.lower() in f[2].lower()):
                found.setdefault(f[0], {"repo": name, "sha": f[0], "ts": int(f[3]), "subject": f[4]})
    return sorted(found.values(), key=lambda c: -c["ts"])[:limit]


def calendar_html(cal):
    if not cal:
        return ""
    levels = {"NONE": 0, "FIRST_QUARTILE": 1, "SECOND_QUARTILE": 2, "THIRD_QUARTILE": 3, "FOURTH_QUARTILE": 4}
    cells = []
    for col, week in enumerate(cal["weeks"], 1):
        for day in week["contributionDays"]:
            tip = f'{plural(day["contributionCount"], "contribution")} on {day["date"]}'
            cells.append(f'<i class="l{levels.get(day["contributionLevel"], 0)}" style="grid-area:{day["weekday"] + 1}/{col}" title="{esc(tip)}"></i>')
    return (f'<section class="card"><h3>{cal["totalContributions"]} contributions in the last year</h3>'
            f'<div class="calwrap"><div class="cal">{"".join(cells)}</div></div></section>')


def activity_html(commits):
    if not commits:
        return ""
    rows = []
    for c in commits:
        local = f'/{c["repo"]}/commit/{c["sha"][:10]}/'
        href = f'/{q(c["repo"])}/commit/{c["sha"][:10]}/' if os.path.exists(page_file(local)) else f'https://github.com/{USER}/{q(c["repo"])}/commit/{c["sha"]}'
        rows.append(f'<div class="rr"><a class="rn2" href="/{q(c["repo"])}/">{icon("repo")}<span>{esc(c["repo"])}</span></a>'
                    f'<a class="fm" href="{href}">{esc(c["subject"])}</a><span class="ft">{timetag(c["ts"])}</span></div>')
    return f'<section class="card"><h3>Recent commits</h3>{"".join(rows)}</section>'


MAX_ITEMS_PAGES = 3        # x100 newest-updated issues, pull requests and comments per repo


def api_pages(path):
    out = []
    for page in range(1, MAX_ITEMS_PAGES + 1):
        batch = api(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
        out += batch
        if len(batch) < 100:
            break
    return out


def who(u):
    u = u or {}
    return {"login": u.get("login") or "ghost", "avatar": u.get("avatar_url") or ""}


def fetch_discussions(meta):
    """Issues and pull requests with their comments, as they stand at build time."""
    name = meta["name"]
    base = f"/repos/{USER}/{urllib.parse.quote(name)}"
    path = lambda kind: os.path.join(CACHE, kind, name + ".json")

    def item(i):
        return {"n": i["number"], "title": i["title"], "state": i["state"], "user": who(i.get("user")), "body": i.get("body") or "",
                "date": i.get("created_at") or "", "labels": [[l["name"], l.get("color") or ""] for l in i.get("labels", [])],
                "merged": bool(i.get("merged_at")), "draft": bool(i.get("draft")), "updated": i.get("updated_at") or "",
                "count": i.get("comments")}

    def note(c, kind, text=None):
        return {"n": int((c.get("issue_url") or c.get("pull_request_url") or "/0").rsplit("/", 1)[1]), "user": who(c.get("user")),
                "body": c.get("body") or "", "date": c.get("created_at") or c.get("submitted_at") or "", "kind": text or kind}

    issues = []
    if meta.get("has_issues", True):
        issues = cached_json(path("issues"), lambda: [item(i) for i in api_pages(base + "/issues?state=all&sort=updated") if "pull_request" not in i], [])
    pulls = cached_json(path("pulls"), lambda: [item(i) for i in api_pages(base + "/pulls?state=all&sort=updated&direction=desc")], [])
    comments = []
    if issues or pulls:
        comments += cached_json(path("comments"), lambda: [note(c, "commented") for c in api_pages(base + "/issues/comments?sort=updated&direction=desc")], [])
    if pulls:
        comments += cached_json(path("review_comments"), lambda: [note(c, "", f"commented on {c.get('path', 'a file')}") for c in api_pages(base + "/pulls/comments?sort=updated&direction=desc")], [])
        # reviews need one request per pull request: only ask again when that pull request changed
        try:
            with open(path("reviews"), encoding="utf-8") as fh:
                old = json.load(fh)
        except Exception:
            old = {}
        new = {}
        for p in pulls[:30]:
            key = str(p["n"])
            hit = old.get(key)
            if not hit or hit["updated"] != p["updated"]:
                try:
                    rv = api(f"{base}/pulls/{p['n']}/reviews?per_page=100")
                    hit = {"updated": p["updated"], "list": [
                        {"n": p["n"], "user": who(r.get("user")), "body": r.get("body") or "", "date": r.get("submitted_at") or "",
                         "kind": {"APPROVED": "approved these changes", "CHANGES_REQUESTED": "requested changes"}.get(r["state"], "reviewed")}
                        for r in rv if r["state"] != "PENDING" and (r.get("body") or r["state"] != "COMMENTED")]}
                except Exception as e:
                    log(f"  ! reviews for {name}#{p['n']} not fetched ({e})")
            if hit:
                new[key] = hit
                comments += hit["list"]
        write(path("reviews"), json.dumps(new))
    return {"issues": issues, "pulls": pulls, "comments": comments}


def when(date):
    return timetag(int(datetime.fromisoformat(date.replace("Z", "+00:00")).timestamp())) if date else ""


def state_badge(i):
    if i["merged"]:
        return '<span class="badge ok">Merged</span>'
    if i["state"] == "open":
        return '<span class="badge warn">Draft</span>' if i["draft"] else '<span class="badge ok">Open</span>'
    return '<span class="badge bad">Closed</span>'


def label_html(labels):
    return "".join(f'<span class="label" style="border-color:#{c if re.fullmatch("[0-9a-fA-F]{6}", c) else "9399b2"}">{esc(n)}</span> ' for n, c in labels)


def render_discussions(meta, rh, branch, tree_files, tree_dirs):
    name = meta["name"]
    d = meta.get("discussions") or {}
    threads = {}
    for c in d.get("comments", []):
        threads.setdefault(c["n"], []).append(c)

    def box(c, verb):
        img = f'<img src="{esc(c["user"]["avatar"])}&s=48" alt="" width="24" height="24" loading="lazy">' if c["user"]["avatar"] else ""
        body = render_markdown(c["body"], name, branch, "", tree_files, tree_dirs) if c["body"].strip() else '<p class="mu">No description provided.</p>'
        return f'<section class="comment card"><header>{img}<b>{esc(c["user"]["login"])}</b><span class="mu">{esc(verb)} {when(c["date"])}</span></header><article class="md">{body}</article></section>'

    for kind, title, gh_kind in (("issues", "Issues", "issues"), ("pulls", "Pull requests", "pull")):
        items = sorted(d.get(kind, []), key=lambda i: -i["n"])
        sections = ""
        for label, group in (("Open", [i for i in items if i["state"] == "open"]), ("Closed", [i for i in items if i["state"] != "open"])):
            rows = "".join(f'<div class="rr"><a class="rn2" href="/{q(name)}/{kind}/{i["n"]}/"><span>{esc(i["title"])}</span></a>{state_badge(i)}{label_html(i["labels"])}'
                           f'<span class="fm">#{i["n"]} by {esc(i["user"]["login"])}</span><span class="ft">{when(i["date"])}</span></div>' for i in group)
            sections += f'<h2 class="sec">{label} <em>{len(group)}</em></h2><div class="ftable items">{rows or "<div class=empty>Nothing here.</div>"}</div>'
        gh_list = f"https://github.com/{USER}/{name}/{kind}"
        main = f'{rh(kind)}<div class="wrap"><div class="col">{sections}<p class="more-link"><a href="{gh_list}" rel="noopener">{title} on GitHub{icon("ext", "xs")}</a></p></div></div>'
        write(page_file(f"/{name}/{kind}/"), layout(f"{title} · {USER}/{name}", main, path=f"/{name}/{kind}/"))
        for i in items:
            url = f"https://github.com/{USER}/{name}/{gh_kind}/{i['n']}"
            thread = sorted(threads.get(i["n"], []), key=lambda c: c["date"])
            missing = ""
            if i["count"] and i["count"] > sum(c["kind"] == "commented" for c in thread):
                missing = '<p class="notice">Some older comments are only on GitHub.</p>'
            files = f'<a class="btn sm" href="{url}/files" rel="noopener">Files changed{icon("ext", "xs")}</a> ' if kind == "pulls" else ""
            main = (f'{rh(kind)}<div class="wrap"><div class="col"><div class="chead"><h2>{esc(i["title"])} <span class="mu">#{i["n"]}</span></h2>'
                    f'<div class="cmeta">{state_badge(i)}{label_html(i["labels"])}{files}<a class="btn sm" href="{url}" rel="noopener">Reply on GitHub{icon("ext", "xs")}</a></div></div>'
                    f'{box(i, "opened")}{missing}{"".join(box(c, c["kind"]) for c in thread)}</div></div>')
            write(page_file(f"/{name}/{kind}/{i['n']}/"), layout(f"{i['title']} · {USER}/{name}#{i['n']}", main, path=f"/{name}/{kind}/{i['n']}/"))


def render_repo(meta, bare, out_dir):
    name = meta["name"]
    try:
        head = git(bare, "rev-parse", "--verify", "HEAD").strip()
    except Exception:
        head = ""
    branch = (git(bare, "symbolic-ref", "--short", "HEAD", check=False).strip() or meta.get("default_branch") or "main")
    gh = f"https://github.com/{USER}/{name}"
    files_out = []

    # ---- refs
    branches, tags = [], []
    for ln in git(bare, "for-each-ref", "--sort=-creatordate",
                  "--format=%(refname)%1f%(objectname)%1f%(creatordate:unix)%1f%(contents:subject)%1f%(*objectname)", "refs/heads", "refs/tags").split("\n"):
        if not ln.strip():
            continue
        ref, sha, ts, subj, peeled = (ln.split("\x1f") + ["", "", "", ""])[:5]
        item = {"name": ref.split("/", 2)[2], "sha": peeled or sha, "ts": int(ts or 0), "subject": subj}
        (branches if ref.startswith("refs/heads/") else tags).append(item)
    branches.sort(key=lambda b: (b["name"] != branch, -b["ts"]))

    if not head:
        counts = {"commits": 0, "branches": 0, "tags": 0}
        body = repo_head(meta, "code", counts) + '<div class="wrap"><div class="empty">This repository is empty.</div></div>'
        write(page_file(f"/{name}/"), layout(f"{USER}/{name}", body, path=f"/{name}/"))
        return files_out

    def render_ref(branch, head, root, raw_root, is_default):
        # ---- tree
        children, tree_files, tree_dirs, file_sizes, blobs = {"": []}, set(), set(), [], {}
        raw = git(bare, "ls-tree", "-r", "-t", "-z", "-l", head)
        for ent in raw.split("\0"):
            if not ent:
                continue
            m, path = ent.split("\t", 1)
            mode, typ, sha, size = m.split()
            parent, base = posixpath.dirname(path), posixpath.basename(path)
            e = {"name": base, "path": path, "type": typ, "sha": sha, "size": 0 if size == "-" else int(size), "mode": mode}
            children.setdefault(parent, []).append(e)
            if typ == "tree":
                children.setdefault(path, [])
                tree_dirs.add(path)
            elif typ == "blob":
                tree_files.add(path)
                blobs[path] = e
                file_sizes.append((path, e["size"]))
        files_out = sorted(tree_files)

        commits, shallow = history[branch]
        details = detail_map[branch]
        last = {}  # path -> commit
        for c in commits:
            if c["boundary"]:
                continue
            for p in c["paths"]:
                if p not in last:
                    last[p] = c
                d = posixpath.dirname(p)
                while d and d not in last:
                    last[d] = c
                    d = posixpath.dirname(d)
        latest = commits[0] if commits else None
        latest_detail = details[0] if details else None
        n_commits = len(commits)
        commits_label = f"{n_commits}+" if shallow else str(n_commits)
        total_size = sum(s for _, s in file_sizes)
        rcounts = {**counts, "commits": commits_label}
        def rh(active):
            head_html = repo_head(meta, active, rcounts)
            if is_default:
                return head_html
            for tail in ('/"><svg', '/commits/"><svg'):
                head_html = head_html.replace(f'class="tab{" on" if (tail[1] == '"') == (active == "code") else ""}" href="/{q(name)}{tail}',
                                              f'class="tab{" on" if (tail[1] == '"') == (active == "code") else ""}" href="{root}{tail}')
            return head_html

        def file_row(e):
            p = e["path"]
            c = last.get(p)
            if e["type"] == "commit":
                return f'<div class="fr"><span class="fn">{icon("folder")}<span>{esc(e["name"])}</span><em class="sm">submodule</em></span><span class="fm"></span><span class="ft"></span></div>'
            if e["type"] == "tree":
                href, ic = f"{root}/tree/{q(p)}/", icon("folder", "dir")
            else:
                href, ic = f"{root}/blob/{q(p)}/", icon("file")
            msg = f'<a class="fm" href="{commit_href(c["sha"])}" tabindex="-1">{esc(c["subject"])}</a>' if c else '<span class="fm"></span>'
            tm = f'<span class="ft">{timetag(c["ts"])}</span>' if c else '<span class="ft"></span>'
            return f'<div class="fr"><a class="fn" href="{href}">{ic}<span>{esc(e["name"])}</span></a>{msg}{tm}</div>'

        def listing(dirpath):
            ents = sorted(children.get(dirpath, []), key=lambda e: (e["type"] != "tree", e["name"].lower()))
            rows = []
            if dirpath:
                up = posixpath.dirname(dirpath)
                href = f"{root}/tree/{q(up)}/" if up else f"{root}/"
                rows.append(f'<div class="fr up"><a class="fn" href="{href}">{icon("folder", "dir")}<span>..</span></a><span class="fm"></span><span class="ft"></span></div>')
            rows += [file_row(e) for e in ents]
            c = last.get(dirpath) if dirpath else latest
            if c:
                who = (latest_detail["author"] if (not dirpath and latest_detail) else None)
                if who is None:
                    d = next((d for d in details if d["sha"] == c["sha"]), None)
                    who = d["author"] if d else ""
                bar = (f'<div class="fr lc">{avatar(who) if who else ""}<span class="who">{esc(who)}</span>'
                       f'<a class="fm" href="{commit_href(c["sha"])}">{esc(c["subject"])}</a>'
                       f'<a class="sha" href="{commit_href(c["sha"])}">{c["sha"][:7]}</a><span class="ft">{timetag(c["ts"])}</span></div>')
            else:
                bar = ""
            return f'<div class="ftable">{bar}{"".join(rows) or "<div class=empty>Empty directory</div>"}</div>'

        def toolbar():
            clone = f"https://github.com/{USER}/{name}.git"
            ssh = f"git@github.com:{USER}/{name}.git"
            zipu = f"{gh}/archive/refs/heads/{q(branch)}.zip"
            goto = (f'<button class="btn" type="button" data-goto="{esc(name)}/">{icon("search")}<span>Go to file</span></button>') if is_default else ""
            return f"""<div class="tbar">
    <a class="btn" href="/{q(name)}/branches/">{icon('branch')}<span>{esc(branch)}</span></a>
    {goto}
    <details class="clone"><summary class="btn pri"><span>Clone</span>{icon('down')}</summary>
    <div class="pop"><label>HTTPS</label><div class="cp"><input readonly value="{esc(clone)}" aria-label="HTTPS clone URL"><button type="button" class="ib" data-copy="{esc(clone)}" aria-label="Copy">{icon('copy')}{icon('check', 'ck')}</button></div>
    <label>SSH</label><div class="cp"><input readonly value="{esc(ssh)}" aria-label="SSH clone URL"><button type="button" class="ib" data-copy="{esc(ssh)}" aria-label="Copy">{icon('copy')}{icon('check', 'ck')}</button></div>
    <a class="pl" href="{zipu}" rel="noopener">{icon('download')}<span>Download ZIP</span></a>
    <a class="pl" href="{gh}" rel="noopener">{icon('github')}<span>Open on GitHub</span></a></div></details></div>"""

        cat = CatFile(bare)
        try:
            # ---- README
            readme_html, readme_name = "", ""
            for e in children.get("", []):
                if e["type"] == "blob" and e["name"].lower() in README_NAMES:
                    data = cat.read(e["sha"]).decode("utf-8", "replace")
                    readme_name = e["name"]
                    if e["name"].lower().endswith((".md", ".markdown", ".mdx")):
                        readme_html = render_markdown(data, name, branch, "", tree_files, tree_dirs, root)
                    else:
                        readme_html = f"<pre>{esc(data)}</pre>"
                    break
            readme = (f'<section class="readme card"><header>{icon("repo")}<a href="{root}/blob/{q(readme_name)}/">{esc(readme_name)}</a></header>'
                      f'<article class="md">{readme_html}</article></section>') if readme_html else ""

            # ---- sidebar
            topics = "".join(f'<a class="topic" href="https://github.com/topics/{q(t)}" rel="noopener">{esc(t)}</a>' for t in meta.get("topics") or [])
            side = ['<aside class="side"><section class="card"><h3>About</h3>']
            side.append(f'<p>{esc(meta["description"])}</p>' if meta.get("description") else '<p class="mu">No description provided.</p>')
            if meta.get("homepage"):
                hp = meta["homepage"] if re.match(r"https?://", meta["homepage"]) else "https://" + meta["homepage"]
                side.append(f'<p class="kv">{icon("link")}<a href="{esc(hp)}" rel="noopener">{esc(re.sub(r"^https?://", "", hp).rstrip("/"))}</a></p>')
            if topics:
                side.append(f'<div class="topics">{topics}</div>')
            lic = (meta.get("license") or {}).get("name")
            if lic:
                side.append(f'<p class="kv">{icon("law")}<span>{esc(lic)}</span></p>')
            if latest:
                side.append(f'<p class="kv">{icon("clock")}<span>Updated {timetag(latest["ts"])}</span></p>')
            side.append(f'<p class="kv">{icon("star")}<span>{plural(meta.get("stargazers_count", 0), "star")} · {plural(meta.get("forks_count", 0), "fork")}</span></p>')
            side.append("</section>")
            side.append(extras_html(meta))
            lb = language_bar(file_sizes)
            if lb:
                side.append(f'<section class="card"><h3>Languages</h3>{lb}</section>')
            side.append("</aside>")
            side = "".join(side)

            # ---- repo home
            meta_bar = (f'<div class="metabar"><a href="{root}/commits/">{icon("commit")}<b>{commits_label}</b> {"Commit" if n_commits == 1 and not shallow else "Commits"}</a>'
                        f'<a href="/{q(name)}/branches/">{icon("branch")}<b>{len(branches)}</b> {"Branch" if len(branches) == 1 else "Branches"}</a>'
                        f'<a href="/{q(name)}/tags/">{icon("tag")}<b>{len(tags)}</b> {"Tag" if len(tags) == 1 else "Tags"}</a>'
                        f'<span>{icon("file")}<b>{human_size(total_size)}</b></span></div>')
            main = f'{rh("code")}<div class="wrap cols"><div class="col">{meta_bar}{toolbar()}{listing("")}{readme}</div>{side}</div>'
            write(page_file(f"{raw_root}/"), layout(f"{USER}/{name}" + (f": {meta['description']}" if meta.get("description") else ""),
                                                main, path=f"{raw_root}/", desc=meta.get("description") or "", cls="p-repo", noindex=not is_default))

            # ---- tree pages
            for d in sorted(tree_dirs):
                parts = d.split("/")
                main = (f'{rh("code")}<div class="wrap"><div class="col">{toolbar()}{crumbs(name, parts, root=root)}{listing(d)}</div></div>')
                write(page_file(f"{raw_root}/tree/{d}/"), layout(f"{d} · {USER}/{name}", main, path=f"{raw_root}/tree/{d}/", cls="p-tree", noindex=not is_default))

            # ---- blob pages
            for n_i, path in enumerate(sorted(tree_files)):
                if n_i >= MAX_FILES:
                    break
                e = blobs[path]
                fname = posixpath.basename(path)
                ext = posixpath.splitext(fname)[1].lower()
                raw_url = f"https://raw.githubusercontent.com/{USER}/{name}/{q(branch)}/{q(path)}"
                hist = f"{gh}/commits/{q(branch)}/{q(path)}"
                actions = (f'<a class="btn sm" href="{raw_url}" rel="noopener">Raw</a><a class="btn sm" href="{hist}" rel="noopener">History</a>'
                           f'<a class="btn sm" href="{gh}/blob/{q(branch)}/{q(path)}" rel="noopener">GitHub{icon("ext", "xs")}</a>')
                seg, view, extra_cls = "", "", ""
                meta_txt = human_size(e["size"])
                if ext in IMG_EXT and e["size"] <= 5_000_000:
                    view = f'<div class="imgview"><img src="{raw_url}" alt="{esc(fname)}" loading="lazy"></div>'
                elif e["size"] > MAX_BLOB:
                    view = f'<div class="notice">This file is too large to display ({human_size(e["size"])}). <a href="{raw_url}" rel="noopener">View raw</a></div>'
                else:
                    data = cat.read(e["sha"])
                    if b"\0" in data[:8000]:
                        view = f'<div class="notice">Binary file ({human_size(e["size"])}). <a href="{raw_url}" rel="noopener">Download raw</a></div>'
                    else:
                        text = data.decode("utf-8", "replace")
                        lines = highlight_lines(text, fname, colour=len(data) <= MAX_HIGHLIGHT)
                        meta_txt = f'{plural(len(lines), "line")} · {human_size(e["size"])}'
                        if not lines:
                            view = '<div class="notice">Empty file.</div>'
                        else:
                            nums = "".join(f'<a id="L{i}" href="#L{i}">{i}</a>' for i in range(1, len(lines) + 1))
                            code = "".join(f'<span id="C{i}">{l}</span>\n' for i, l in enumerate(lines, 1))
                            view = f'<div class="codebox"><pre class="ln" aria-hidden="true">{nums}</pre><pre class="code"><code>{code}</code></pre></div>'
                            if ext in (".md", ".markdown", ".mdx"):
                                md = render_markdown(text, name, branch, posixpath.dirname(path), tree_files, tree_dirs, root)
                                view = f'<article class="mdview md">{md}</article>' + view
                                seg = '<div class="seg"><button type="button" data-view="md" class="on">Preview</button><button type="button" data-view="code">Code</button></div>'
                                extra_cls = " md-on"
                c = last.get(path)
                cbar = (f'<div class="bcommit"><a href="{commit_href(c["sha"])}">{esc(c["subject"])}</a><span>{timetag(c["ts"])}</span></div>' if c else "")
                body = (f'<div class="blob card{extra_cls}"><header class="bh"><span class="bn">{icon("file")}<b>{esc(fname)}</b><em>{meta_txt}</em></span>'
                        f'{seg}<span class="acts">{actions}</span></header>{cbar}{view}</div>')
                main = f'{rh("code")}<div class="wrap"><div class="col">{toolbar()}{crumbs(name, path.split("/"), True, root=root)}{body}</div></div>'
                write(page_file(f"{raw_root}/blob/{path}/"), layout(f"{path} · {USER}/{name}", main, path=f"{raw_root}/blob/{path}/", cls="p-blob", noindex=not is_default))
        finally:
            cat.close()

        # ---- commits list
        groups, order = {}, []
        for d in details:
            day = abs_date(d["ts"])
            if day not in groups:
                groups[day] = []
                order.append(day)
            groups[day].append(d)
        items = []
        for day in order:
            items.append(f'<h3 class="day">Commits on {esc(day)}</h3><ul class="clist">')
            for d in groups[day]:
                body_flag = f'<span class="more" title="Has a description">…</span>' if d["body"] else ""
                items.append(f'<li>{avatar(d["author"])}<div class="cm"><a class="ct" href="/{q(name)}/commit/{d["sha"][:10]}/">{esc(d["subject"])}</a>{body_flag}'
                             f'<div class="cs"><b>{esc(d["author"])}</b> committed {timetag(d["ts"])}</div></div>'
                             f'<a class="sha" href="/{q(name)}/commit/{d["sha"][:10]}/">{d["sha"][:7]}</a></li>')
            items.append("</ul>")
        more = ""
        if n_commits > len(details) or shallow:
            more = f'<p class="more-link"><a href="{gh}/commits/{q(branch)}" rel="noopener">View full history on GitHub{icon("ext", "xs")}</a></p>'
        main = f'{rh("commits")}<div class="wrap"><div class="col"><h2 class="sec">History <em>{esc(branch)}</em></h2>{"".join(items)}{more}</div></div>'
        write(page_file(f"{raw_root}/commits/"), layout(f"Commits · {USER}/{name}", main, path=f"{raw_root}/commits/", cls="p-commits", noindex=not is_default))

        return tree_files, tree_dirs

    # ---- default branch first, then the most recently updated others
    others = [b for b in branches if b["name"] != branch][:MAX_BRANCHES]
    refs = [(branch, head)] + [(b["name"], b["sha"]) for b in others]
    history = {n: read_commits(bare, sha) for n, sha in refs}
    detail_map = {n: read_details(bare, sha) for n, sha in refs}
    all_details = {d["sha"]: d for ds in detail_map.values() for d in ds}
    detail_shas = set(all_details)
    boundaries = {c["sha"] for cs, _ in history.values() for c in cs if c["boundary"]}

    def commit_href(sha):
        return f"/{q(name)}/commit/{sha[:10]}/" if sha in detail_shas else f"{gh}/commit/{sha}"

    releases = meta.get("releases", [])
    shallow = history[branch][1]
    counts = {"commits": f"{len(history[branch][0])}+" if shallow else str(len(history[branch][0])),
              "branches": len(branches), "tags": len(tags), "releases": len(releases),
              **{k: sum(i["state"] == "open" for i in (meta.get("discussions") or {}).get(k, [])) for k in ("issues", "pulls")}}
    rh = rh_default = lambda active: repo_head(meta, active, counts)
    tree_files, tree_dirs = render_ref(branch, head, f"/{q(name)}", f"/{name}", True)
    files_out = sorted(tree_files)
    browsable = {branch}
    for b in others:
        seg = b["name"].replace("/", "~")   # "~" cannot appear in a git ref, so this stays unique
        render_ref(b["name"], b["sha"], f"/{q(name)}/branch/{q(seg)}", f"/{name}/branch/{seg}", False)
        browsable.add(b["name"])

    # ---- commit pages
    render_discussions(meta, rh_default, branch, tree_files, tree_dirs)

    for d in all_details.values():
        sha = d["sha"]
        boundary = sha in boundaries
        if boundary:
            diff = f'<div class="notice">History is truncated here. <a href="{gh}/commit/{sha}" rel="noopener">View this commit on GitHub</a>.</div>'
            stat = ""
        else:
            fl = parse_diff(d["patch"])
            adds, dels = sum(f["add"] for f in fl), sum(f["del"] for f in fl)
            merge_note = " (merge, compared with its first parent)" if len(d["parents"]) > 1 else ""
            stat = (f'<div class="cstat"><b>{plural(len(fl), "file")}</b> changed, <span class="plus">+{adds}</span> <span class="minus">−{dels}</span>{merge_note}</div>')
            if len(fl) > 1:
                stat += '<ul class="flist">' + "".join(
                    f'<li><a href="#f{i}">{esc(f["b"] if f["status"] != "deleted" else f["a"])}</a><span><i class="plus">+{f["add"]}</i> <i class="minus">−{f["del"]}</i></span></li>'
                    for i, f in enumerate(fl[:200])) + "</ul>"
            diff = render_diff(fl[:300]) if fl else '<div class="notice">No file changes in this commit.</div>'
        parent = ""
        if d["parents"]:
            ps = d["parents"][0]
            parent = f'<span>parent <a class="sha" href="{commit_href(ps)}">{ps[:7]}</a></span>'
        body_html = f'<pre class="cbody">{esc(d["body"])}</pre>' if d["body"] else ""
        main = (f'{rh("commits")}<div class="wrap"><div class="col"><div class="chead"><h2>{esc(d["subject"])}</h2>{body_html}'
                f'<div class="cmeta">{avatar(d["author"])}<b>{esc(d["author"])}</b><span>committed {timetag(d["ts"])}</span>{parent}'
                f'<span>commit <code class="sha">{sha[:10]}</code></span><a class="btn sm" href="{gh}/commit/{sha}" rel="noopener">GitHub{icon("ext", "xs")}</a></div></div>'
                f'{stat}{diff}</div></div>')
        write(page_file(f"/{name}/commit/{sha[:10]}/"), layout(f"{d['subject']} · {USER}/{name}@{sha[:7]}", main, path=f"/{name}/commit/{sha[:10]}/", cls="p-commit"))

    # ---- branches & tags
    released = {r["tag"] for r in releases}

    def ref_rows(items, kind):
        rows = []
        for r in items:
            link = f"{gh}/tree/{q(r['name'])}"
            isdef = kind == "b" and r["name"] == branch
            href = f"/{q(name)}/" if isdef else link
            if kind == "b" and not isdef and r["name"] in browsable:
                href = f"/{q(name)}/branch/{q(r['name'].replace('/', '~'))}/"
            if kind == "t":   # stay on the mirror: the release if there is one, else the tagged commit
                href = f"/{q(name)}/releases/#rel-{q(r['name'])}" if r["name"] in released else commit_href(r["sha"])
            rows.append(f'<div class="rr"><a class="rn2" href="{href}"{"" if href.startswith("/") else " rel=noopener"}>{icon("branch" if kind == "b" else "tag")}<span>{esc(r["name"])}</span></a>'
                        f'{"<span class=badge>default</span>" if isdef else ""}'
                        f'<a class="fm" href="{commit_href(r["sha"])}">{esc(r["subject"])}</a><span class="ft">{timetag(r["ts"]) if r["ts"] else ""}</span></div>')
        return "".join(rows) or '<div class="empty">Nothing here yet.</div>'

    main = f'{rh("releases")}<div class="wrap"><div class="col"><h2 class="sec">Releases</h2>{releases_html(releases, name, branch, tree_files, tree_dirs)}</div></div>'
    write(page_file(f"/{name}/releases/"), layout(f"Releases · {USER}/{name}", main, path=f"/{name}/releases/", cls="p-releases"))

    for kind, label, items in (("b", "branches", branches), ("t", "tags", tags)):
        main = f'{rh(label)}<div class="wrap"><div class="col"><h2 class="sec">{label.capitalize()}</h2><div class="ftable refs">{ref_rows(items, kind)}</div></div></div>'
        write(page_file(f"/{name}/{label}/"), layout(f"{label.capitalize()} · {USER}/{name}", main, path=f"/{name}/{label}/", cls="p-refs"))
    return files_out


# ───────────────────────────── orchestration ─────────────────────────────

def init_worker(cfg):
    CFG.update(cfg)


def build_one(meta, prev_key):
    name = meta["name"]
    t0 = time.time()
    bare = os.path.join(CACHE, "repos", name + ".git")
    out_dir = os.path.join(SITE, name)
    cached = os.path.join(CACHE, "out", name)
    fcache = os.path.join(CACHE, "files", name + ".json")
    try:
        retry(lambda: sync_repo(name, bare))
        head = git(bare, "rev-parse", "HEAD", check=False).strip()
        refs = git(bare, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags")
        meta = {**meta, "releases": fetch_releases(name), **fetch_extras(name), "discussions": fetch_discussions(meta)}
        sig = {"v": CFG["src"], "base": CFG["base"], "head": head, "refs": refs, "releases": meta["releases"], "discussions": meta["discussions"],
               "contributors": meta["contributors"], "deployments": meta["deployments"], "branches": MAX_BRANCHES,
               "meta": {k: meta.get(k) for k in ("description", "stargazers_count", "forks_count", "topics", "homepage", "fork", "archived", "license", "default_branch")}}
        key = hashlib.sha1(json.dumps(sig, sort_keys=True, default=str).encode()).hexdigest()
        if key == prev_key and os.path.isdir(cached) and os.path.exists(fcache):
            shutil.copytree(cached, out_dir)
            return {"name": name, "status": "cached", "key": key, "files": json.load(open(fcache)), "secs": time.time() - t0}
        files = render_repo(meta, bare, out_dir)
        shutil.rmtree(cached, ignore_errors=True)
        os.makedirs(os.path.dirname(cached), exist_ok=True)
        shutil.copytree(out_dir, cached)
        write(fcache, json.dumps(files))
        return {"name": name, "status": "built", "key": key, "files": files, "secs": time.time() - t0}
    except Exception as e:
        # keep serving the last good copy rather than dropping the repo
        if os.path.isdir(cached) and os.path.exists(fcache):
            shutil.rmtree(out_dir, ignore_errors=True)
            shutil.copytree(cached, out_dir)
            return {"name": name, "status": "stale", "key": prev_key, "files": json.load(open(fcache)), "error": str(e)[:300], "secs": time.time() - t0}
        shutil.rmtree(out_dir, ignore_errors=True)
        return {"name": name, "status": "failed", "key": None, "files": [], "error": f"{type(e).__name__}: {e}"[:400], "secs": time.time() - t0}


def minify_css(css):
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    css = re.sub(r"\s+", " ", css)
    css = re.sub(r"\s*([{};,>])\s*", r"\1", css)
    css = re.sub(r":\s+", ":", css)
    return css.replace(";}", "}").strip()


def detect_base():
    if os.environ.get("MIRROR_BASE_URL"):
        return os.environ["MIRROR_BASE_URL"].rstrip("/")
    try:
        pg = api(f"/repos/{SELF_REPO}/pages")
        if pg.get("cname"):
            return "https://" + pg["cname"]
        if pg.get("html_url"):
            return pg["html_url"].rstrip("/")
    except Exception:
        pass
    cname = os.path.join(ROOT, "CNAME")
    if os.path.exists(cname):
        return "https://" + open(cname).read().strip()
    owner, repo = SELF_REPO.split("/", 1)
    host = f"{owner.lower()}.github.io"
    return f"https://{host}" if repo.lower() == host else f"https://{host}/{repo}"


def home_page(repos, profile, built_at, extras=None, commits=()):
    extras = extras or {}
    rows = []
    for m in repos:
        lang = m.get("language")
        col = next((c for (n, c) in LANGS.values() if n == lang), "#8b949e") if lang else None
        badges = ("" if not m.get("fork") else '<span class="badge">Fork</span>') + ("" if not m.get("archived") else '<span class="badge warn">Archived</span>')
        pushed = m.get("pushed_at") or ""
        ts = int(datetime.fromisoformat(pushed.replace("Z", "+00:00")).timestamp()) if pushed else 0
        side_bits = f'<span class="lg"><i style="background:{col}"></i>{esc(lang)}</span>' if lang else ""
        side_bits += f'<span>{icon("star")}{m.get("stargazers_count", 0)}</span><span>{icon("fork")}{m.get("forks_count", 0)}</span>'
        topics = "".join(f'<span>{esc(t)}</span>' for t in m.get("topics") or [])
        rows.append(
            f'<li class="rrow" data-n="{esc(m["name"].lower())}" data-d="{esc((m.get("description") or "").lower())}" data-l="{esc((lang or "").lower())}" data-s="{m.get("stargazers_count", 0)}" data-t="{ts}">'
            f'{avatar(m["name"])}<div class="rbody"><div class="r1"><span class="mu">{esc(USER)} /</span><a class="rn" href="/{q(m["name"])}/">{esc(m["name"])}</a>{badges}<span class="rside">{side_bits}</span></div>'
            f'{f"<p>{esc(m["description"])}</p>" if m.get("description") else ""}'
            f'{f"<div class=chips>{topics}</div>" if topics else ""}'
            f'{f"<div class=r3>Updated {timetag(ts)}</div>" if ts else ""}</div></li>')
    prof = ""
    if profile:
        bits = []
        for key, ic in (("company", "repo"), ("location", "pin")):
            if profile.get(key):
                bits.append(f'<span>{icon(ic)}{esc(profile[key])}</span>')
        if profile.get("email"):
            bits.append(f'<a href="mailto:{esc(profile["email"])}">{icon("link")}{esc(profile["email"])}</a>')
        links = [profile.get("blog")] + [a.get("url") for a in extras.get("social", [])]
        for b in dict.fromkeys(x for x in links if x):
            b = b if b.startswith("http") else "https://" + b
            bits.append(f'<a href="{esc(b)}" rel="noopener">{icon("link")}{esc(re.sub(r"^https?://(www[.])?", "", b).rstrip("/"))}</a>')
        stats = (f'<span>{profile.get("followers", 0)} followers</span><span>{profile.get("following", 0)} following</span>'
                 f'<span>{profile.get("public_repos", 0)} public repos</span>')
        orgs = "".join(f'<a href="https://github.com/{esc(o["login"])}" rel="noopener" title="{esc(o["login"])}"><img src="{esc(o["avatar_url"])}&s=64" alt="{esc(o["login"])}" width="32" height="32" loading="lazy"></a>'
                       for o in extras.get("orgs", []))
        prof = (f'<section class="prof card"><img class="me" src="{esc(profile.get("avatar_url", ""))}&s=320" alt="" width="128" height="128">'
                f'<h1>{esc(profile.get("name") or USER)}</h1><p class="mu">@{esc(USER)}</p>'
                f'{f"<p>{esc(profile["bio"])}</p>" if profile.get("bio") else ""}<div class="pbits">{stats}</div>'
                f'<div class="pcol">{"".join(bits)}</div>{f"<div class=faces>{orgs}</div>" if orgs else ""}'
                f'<a class="btn" href="https://github.com/{esc(USER)}" rel="noopener">Follow on GitHub{icon("ext", "xs")}</a></section>')
    readme = ""
    if extras.get("readme"):
        readme = (f'<section class="card"><h3>{esc(USER)} / README.md</h3><article class="md">'
                  f'{render_markdown(extras["readme"], USER, "HEAD", "", set(), set())}</article></section>')
    main = f"""<nav class="htabs" aria-label="Home"><div class="wrap tabs"><a class="tab" href="#main">{icon('repo')}<span>Overview</span></a><a class="tab" href="#repos">{icon('folder')}<span>Repositories</span><em>{len(repos)}</em></a></div></nav>
<div class="wrap home"><aside>{prof}</aside><div class="hmain">{readme}{calendar_html(extras.get("calendar"))}{activity_html(commits)}
<div class="hbar" id="repos"><h2 class="sec">Repositories <em>{len(repos)}</em></h2>
<input id="rf" type="search" placeholder="Filter repositories…" aria-label="Filter repositories" autocomplete="off">
<select id="rs" aria-label="Sort repositories"><option value="t">Recently updated</option><option value="n">Name</option><option value="s">Most stars</option></select></div>
<ul class="rlist" id="rl">{"".join(rows)}</ul>
<p class="empty" id="rempty" hidden>No repositories match.</p>
<p class="synced mu">Synced {timetag(built_at)} · {esc(REBUILD_NOTE)}</p></div></div>"""
    return layout(f"{USER} · git", main, path="/", cls="p-home")


def main():
    t0 = time.time()
    shutil.rmtree(SITE, ignore_errors=True)
    os.makedirs(SITE)
    os.makedirs(CACHE, exist_ok=True)

    # assets
    css = open(os.path.join(ASSETS, "style.css"), encoding="utf-8").read()
    js = open(os.path.join(ASSETS, "app.js"), encoding="utf-8").read()
    v = hashlib.sha1((css + js).encode()).hexdigest()[:8]
    src = hashlib.sha1((open(__file__, "rb").read() + css.encode() + js.encode())).hexdigest()[:12]
    for f in os.listdir(ASSETS):
        if f not in ("style.css", "app.js", "nav.js"):
            shutil.copy(os.path.join(ASSETS, f), os.path.join(SITE, f))
    write(os.path.join(SITE, "style.css"), minify_css(css))
    write(os.path.join(SITE, "app.js"), js)
    write(os.path.join(SITE, ".nojekyll"), "")

    base = detect_base()
    prefix = urllib.parse.urlparse(base).path.rstrip("/")
    CFG.update({"base": base, "v": v, "src": src, "prefix": prefix})
    log(f"user={USER} base={base} depth={DEPTH} assets={v}")

    repos, page = [], 1
    while True:
        batch = retry(lambda: api(f"/users/{USER}/repos?per_page=100&page={page}&sort=pushed"))
        repos += batch
        if len(batch) < 100:
            break
        page += 1
    repos = [r for r in repos if r["name"] not in EXCLUDE and not r.get("disabled")]
    repos.sort(key=lambda r: r.get("pushed_at") or "", reverse=True)
    pf = os.path.join(CACHE, "profile.json")
    try:
        profile = retry(lambda: api(f"/users/{USER}"))
        json.dump(profile, open(pf, "w"))
    except Exception as e:
        log(f"  ! profile fetch failed ({e}); using cached copy")
        profile = json.load(open(pf)) if os.path.exists(pf) else {}
    log(f"{len(repos)} repositories (excluding {sorted(EXCLUDE)})")

    mp = os.path.join(CACHE, "manifest.json")
    manifest = json.load(open(mp)) if os.path.exists(mp) else {}
    results = []
    workers = max(2, min(8, (os.cpu_count() or 2) * 2))
    with ProcessPoolExecutor(max_workers=workers, initializer=init_worker, initargs=(dict(CFG),)) as ex:
        futs = {ex.submit(build_one, r, manifest.get(r["name"])): r["name"] for r in repos}
        for fut in as_completed(futs):
            res = fut.result()
            results.append(res)
            log(f"  {res['status']:<7} {res['name']:<32} {res['secs']:.1f}s" + (f"  ! {res['error']}" if res.get("error") else ""))

    ok = [r for r in results if r["status"] != "failed"]
    failed = [r for r in results if r["status"] in ("failed", "stale")]
    for r in failed:
        log(f"::warning title=mirror {r['name']}::{r.get('error')}")
    if not ok:
        log("::error::no repository could be built")
        sys.exit(1)

    json.dump({r["name"]: r["key"] for r in ok if r["key"]}, open(mp, "w"))
    # drop caches of repos that disappeared
    live = {r["name"] for r in ok}
    for sub, suffix in (("repos", ".git"), ("out", ""), ("files", ".json")):
        d = os.path.join(CACHE, sub)
        if os.path.isdir(d):
            for entry in os.listdir(d):
                if entry[:len(entry) - len(suffix)] not in live:
                    p = os.path.join(d, entry)
                    shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else os.remove(p)

    built = [r for r in repos if r["name"] in live]
    # search index
    fmap = {r["name"]: r["files"] for r in ok}
    write(os.path.join(SITE, "search.json"), json.dumps({
        "r": [{"n": m["name"], "d": m.get("description") or "", "f": fmap.get(m["name"], [])} for m in built]},
        separators=(",", ":"), ensure_ascii=False))

    now = int(time.time())
    write(os.path.join(SITE, "index.html"), home_page(built, profile, now, fetch_home_extras(), recent_commits([m["name"] for m in built], profile)))
    write(os.path.join(SITE, "404.html"), layout("Not found · git", '<div class="wrap"><div class="empty big"><h1>404</h1><p>That page does not exist in the mirror.</p><p><a class="btn pri" href="/">Browse repositories</a></p></div></div>', path="/404.html", noindex=True))
    write(os.path.join(SITE, "robots.txt"), f"User-agent: *\nAllow: /\nSitemap: {base}/sitemap.xml\n")

    # sitemap from what was actually written
    urls, pushed = [], {m["name"]: (m.get("pushed_at") or "")[:10] for m in built}
    for dirpath, _dirs, fns in os.walk(SITE):
        if "index.html" in fns:
            rel = os.path.relpath(dirpath, SITE).replace(os.sep, "/")
            rel = "" if rel == "." else rel
            top = rel.split("/")[0]
            if rel.split("/")[1:2] == ["branch"]:
                continue
            if rel and "/blob/" in "/" + rel + "/" and len(urls) > 40000:
                continue
            urls.append((rel, pushed.get(top, "")))
    urls.sort()
    sm = ['<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for rel, lm in urls[:49000]:
        sm.append(f"<url><loc>{esc(base + '/' + q(rel) + ('/' if rel else ''))}</loc>{f'<lastmod>{lm}</lastmod>' if lm else ''}</url>")
    sm.append("</urlset>")
    write(os.path.join(SITE, "sitemap.xml"), "\n".join(sm))

    sha = os.environ.get("GITHUB_SHA", "")[:7]
    write(os.path.join(SITE, "last_commit"),
          f"built:  {datetime.fromtimestamp(now, timezone.utc).isoformat()}\nsource: {SELF_REPO}@{sha or 'local'}\n"
          f"repos:  {len(built)} ({len([r for r in ok if r['status'] == 'built'])} rebuilt, "
          f"{len([r for r in ok if r['status'] == 'cached'])} cached, {len(failed)} problems)\npages:  {len(urls)}\n")
    rebuilt = any(r["status"] != "cached" for r in results) or bool(failed)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
            fh.write(f"changed={'true' if rebuilt else 'false'}\n")
    log(f"done in {time.time() - t0:.1f}s: {len(built)} repos, {len(urls)} pages, "
        f"{sum(len(f) for _, _, f in os.walk(SITE))} files")


if __name__ == "__main__":
    main()
