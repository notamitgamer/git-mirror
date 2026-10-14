#!/usr/bin/env bash
set -e

USERNAME="${GITHUB_REPOSITORY_OWNER:-notamitgamer}"
REPO_NAME="${GITHUB_REPOSITORY:-$USERNAME/git-mirror}"
WORK_DIR="$(pwd)"
REPOS_DIR="$WORK_DIR/raw_repos"
SITE_DIR="$WORK_DIR/site"
ASSETS_DIR="$WORK_DIR/assets"

PAGES_CNAME=$(gh api "repos/${REPO_NAME}/pages" --jq '.cname // empty' 2>/dev/null || echo "")
if [ -n "$PAGES_CNAME" ]; then
    SITE_BASE_URL="https://${PAGES_CNAME}"
else
    SITE_BASE_URL="https://${USERNAME}.github.io"
fi

MIRROR_COMMIT_HASH=$(git -C "$WORK_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
MIRROR_FULL_HASH=$(git -C "$WORK_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
MIRROR_COMMIT_DATE=$(git -C "$WORK_DIR" log -1 --format="%cd" --date=iso-strict 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

mkdir -p "$REPOS_DIR" "$SITE_DIR"

echo "==> Copying root assets..."
if [ -d "$ASSETS_DIR" ]; then
    for f in style.css favicon.png logo.png icon.png; do
        if [ -f "$ASSETS_DIR/$f" ]; then
            cp "$ASSETS_DIR/$f" "$SITE_DIR/$f"
        fi
    done
    if [ -f "$SITE_DIR/favicon.png" ]; then
        cp "$SITE_DIR/favicon.png" "$SITE_DIR/favicon.ico"
    fi
fi

echo "==> Fetching public repositories for $USERNAME..."
REPOS_JSON=$(gh repo list "$USERNAME" --visibility=public --limit 100 --json name,description -q '.[] | select(.name != "git-mirror" and .name != "register" and .name != "osma")')

echo "==> Processing repositories in parallel (4 workers)..."
echo "$REPOS_JSON" | jq -c -j '. | tostring + "\u0000"' | xargs -0 -n 1 -P 4 ./worker.sh

echo "==> Generating central stagit-index..."
stagit-index "$REPOS_DIR"/*.git > "$SITE_DIR/index.html"
sed -i 's/\/log\.html/\/files\.html/g' "$SITE_DIR/index.html" 2>/dev/null || true

cat <<EOFLAST > "$SITE_DIR/last_commit"
Host: git.amit.is-a.dev
Source Repository: $REPO_NAME
Commit: $MIRROR_FULL_HASH
Commit Date: $MIRROR_COMMIT_DATE
Build Date: $BUILD_TIME
EOFLAST

FOOTER_HTML="<div id=\"build-info\">© <a href=\"https://github.com/$USERNAME\" target=\"_blank\">$USERNAME</a> • Site Built: $BUILD_TIME • git-mirror commit: <a href=\"https://github.com/$REPO_NAME/commit/$MIRROR_FULL_HASH\" target=\"_blank\">$MIRROR_COMMIT_HASH</a> [<a href=\"/last_commit\" target=\"_blank\">view raw info</a>]<br>Originally created with <a href=\"https://codemadness.org/stagit.html\" target=\"_blank\">stagit</a> • modified by <a href=\"https://github.com/notamitgamer\">notamitgamer</a><br>Forked from <a href=\"https://github.com/notamitgamer/git-mirror\" target=\"_blank\">github.com/notamitgamer/git-mirror</a></div>"

find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    "s|</body>|$FOOTER_HTML\n</body>|g"

if [ -f "$WORK_DIR/CNAME" ]; then
    cp "$WORK_DIR/CNAME" "$SITE_DIR/CNAME"
fi

find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    's#<head>#<head>\n\t<meta name="viewport" content="width=device-width, initial-scale=1">#'

echo "==> Generating sitemap.xml..."
SITEMAP_LASTMOD=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    find "$SITE_DIR" -name "*.html" | sed "s|^$SITE_DIR||" | while read -r p; do
        echo "  <url><loc>${SITE_BASE_URL}${p}</loc><lastmod>${SITEMAP_LASTMOD}</lastmod></url>"
    done
    echo '</urlset>'
} > "$SITE_DIR/sitemap.xml"

cat <<EOF404 > "$SITE_DIR/404.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>404 - Not Found</title>
    <link rel="stylesheet" href="/style.css">
</head>
<body>
    <h1>404</h1>
    <p class="desc">The page you're looking for doesn't exist.</p>
    <div class="back-nav"><a href="/">← back to index</a></div>
</body>
</html>
EOF404

echo "==> Build complete! Output generated in ./site"
