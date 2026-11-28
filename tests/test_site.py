#!/usr/bin/env python3
"""Build a mirror from made-up data (no network) and check it in a real browser. Exit code 1 on any failure."""
import functools
import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.mkdtemp()
WORK = os.path.join(TMP, "work")
shutil.copytree(ROOT, WORK, ignore=shutil.ignore_patterns(".git", "site", ".cache", "tests"))
for k in list(os.environ):
    if k.startswith("MIRROR_") or k in ("GITHUB_OUTPUT", "GH_TOKEN", "GITHUB_TOKEN"):
        del os.environ[k]
os.environ.update(GITHUB_REPOSITORY="bob/git-mirror", GITHUB_REPOSITORY_OWNER="bob")
sys.path.insert(0, WORK)
import build  # noqa: E402

LONG = "A-Very-Long-Repository-Name-That-Must-Not-Break-The-Layout"
HOSTILE = "<svg/onload=alert(1)></svg> <img/src=x onerror=alert(2)> [x](javascript:alert(3)) <a href='javascript:alert(4)'>y</a>"
SOURCE = os.path.join(TMP, "source")


def git(*a):
    subprocess.run(["git", "-C", SOURCE, "-c", "user.name=bob", "-c", "user.email=bob@example.com", *a], check=True, capture_output=True)


def put(path, text):
    os.makedirs(os.path.dirname(os.path.join(SOURCE, path)), exist_ok=True)
    with open(os.path.join(SOURCE, path), "w") as fh:
        fh.write(text)


os.makedirs(SOURCE)
git("init", "-q", "-b", "main")
put("README.md", "# One\n## Two\n## Three\n## Four\n\n> [!TIP]\n> hint\n\n```\ncode\n```\n\n" + HOSTILE + "\n")
put("app.py", "x = 1\n" + "# " + "long " * 80 + "\n")
put(".github/note.txt", "hi\n")
git("add", "-A")
git("commit", "-qm", "first")
git("tag", "v1")
git("branch", "feat/x")


def api(path):
    user = {"login": "eve", "avatar_url": "data:,?v=1"}
    if "/repos?" in path:
        base = {"pushed_at": "2026-01-01T00:00:00Z", "description": "words " * 40, "topics": ["one", "two", "three"] * 3, "has_issues": True}
        return [{**base, "name": "demo", "language": "Python", "fork": False},
                {**base, "name": LONG, "language": "Rust", "fork": True, "has_issues": False}]
    if path.endswith("/pages"):
        return {"html_url": "https://bob.github.io/git-mirror/"}
    if "/demo/issues?" in path:
        return [{"number": 1, "title": "A bug", "state": "open", "user": user, "body": HOSTILE, "comments": 0, "labels": [{"name": "bug", "color": "ff0000"}]}]
    if path.endswith("/readme"):
        return {"content": "IyBIZWxsbw=="}
    if path == "/users/bob":
        return {"login": "bob", "name": "Bob", "avatar_url": "data:,?v=1", "bio": "bio " * 20}
    return []


def graphql(query, variables):
    if "pinned" in query:
        return {"user": {"pinnedItems": {"nodes": []}}}
    weeks = [{"contributionDays": [{"date": f"2026-{w // 5 + 1:02d}-01", "contributionCount": d, "weekday": d, "contributionLevel": "NONE"} for d in range(7)]} for w in range(53)]
    return {"user": {"contributionsCollection": {"contributionCalendar": {"totalContributions": 9, "weeks": weeks}}}}


def sync(name, bare):
    if not os.path.isdir(bare):
        subprocess.run(["git", "clone", "-q", "--bare", SOURCE, bare], check=True)


build.api, build.graphql, build.sync_repo, build.TOKEN = api, graphql, sync, "t"
build.main()

SITE = os.path.join(TMP, "srv")
shutil.copytree(os.path.join(WORK, "site"), os.path.join(SITE, "git-mirror"))


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=SITE))
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_port}/git-mirror/"

from playwright.sync_api import sync_playwright  # noqa: E402

failures = []


def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        failures.append(what)


PAGES = ["", "~repos/", "demo/", "demo/blob/app.py/", "demo/commits/", "demo/branches/", "demo/tags/", "demo/issues/",
         "demo/issues/1/", "demo/branch/feat~x/", "demo/tree/.github/", LONG + "/"]

with sync_playwright() as p:
    browser = p.chromium.launch()
    for width in (360, 1366):
        context = browser.new_context(viewport={"width": width, "height": 800}, service_workers="block")
        page = context.new_page()
        problems = []
        page.on("pageerror", lambda e: problems.append(str(e)))
        page.on("dialog", lambda d: (problems.append("script ran: " + d.message), d.dismiss()))
        for path in PAGES:
            response = page.goto(URL + path)
            page.wait_for_load_state("load")
            check(response.ok and page.evaluate("document.documentElement.scrollWidth") <= width, f"{width}px /{path} loads without sideways scroll")

        page.goto(URL + "~repos/")
        rows = page.locator(".rrow:visible")
        check(rows.count() == 2, f"{width}px both repositories listed")
        page.check("#rfork")
        check(rows.count() == 1 and page.inner_text("#rcount") == "Showing 1 of 2", f"{width}px hide forks hides and counts")
        page.reload()
        check(page.is_checked("#rfork") and rows.count() == 1, f"{width}px filter survives reload")
        page.uncheck("#rfork")
        page.select_option("#rlang", "rust")
        check(rows.count() == 1, f"{width}px language filter")
        page.select_option("#rlang", "")
        page.fill("#rf", "zzzz")
        check(rows.count() == 0 and page.is_visible("#rempty"), f"{width}px text filter with no match")

        page.click(".htabs a:has-text('Overview')")
        page.wait_for_selector(".cal")
        check(page.locator("#rl").count() == 0, f"{width}px Overview is its own page")
        page.locator(".cal i").nth(3).click()
        check("on 2026" in page.inner_text(".caltip"), f"{width}px graph shows a day's count")

        page.select_option("#theme", "latte")
        page.goto(URL + "demo/")
        check(page.evaluate("document.documentElement.dataset.theme") == "latte", f"{width}px theme is remembered")
        check(page.locator(".copybtn").count() >= 1 and page.locator(".toc").count() == 1 and page.locator(".alert.tip").count() == 1,
              f"{width}px README has copy button, contents and alert")
        check(page.locator(".rhead .tab:has-text('Issues')").count() == 1 and page.locator(".rhead .tab:has-text('Releases')").count() == 0,
              f"{width}px empty tabs are hidden")
        page.goto(URL + "demo/blob/app.py/")
        page.click("[data-wrap]")
        check(page.evaluate("document.querySelector('.codebox').scrollWidth <= document.querySelector('.codebox').clientWidth + 1"), f"{width}px line wrap")
        check(not problems, f"{width}px no script errors {problems[:3]}")
        context.close()
    browser.close()

server.shutdown()
shutil.rmtree(TMP, ignore_errors=True)
print(f"{len(failures)} failure(s)")
sys.exit(1 if failures else 0)
