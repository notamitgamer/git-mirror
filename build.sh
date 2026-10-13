#!/usr/bin/env bash
set -e

# Automatically detect owner running the Action, fallback to notamitgamer locally
USERNAME="${GITHUB_REPOSITORY_OWNER:-notamitgamer}"
REPO_NAME="${GITHUB_REPOSITORY:-$USERNAME/git-mirror}"
WORK_DIR="$(pwd)"
REPOS_DIR="$WORK_DIR/raw_repos"
SITE_DIR="$WORK_DIR/site"
ASSETS_DIR="$WORK_DIR/assets"

# Site base URL used for sitemap.xml (CNAME wins, else github.io URL)
PAGES_CNAME=$(gh api "repos/${REPO_NAME}/pages" --jq '.cname // empty' 2>/dev/null || echo "")
if [ -n "$PAGES_CNAME" ]; then
    SITE_BASE_URL="https://${PAGES_CNAME}"
else
    SITE_BASE_URL="https://${USERNAME}.github.io"
fi

# 1. Capture git-mirror Repository Commit & Build Metadata
MIRROR_COMMIT_HASH=$(git -C "$WORK_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
MIRROR_FULL_HASH=$(git -C "$WORK_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
MIRROR_COMMIT_DATE=$(git -C "$WORK_DIR" log -1 --format="%cd" --date=iso-strict 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

rm -rf "$REPOS_DIR" "$SITE_DIR"
mkdir -p "$REPOS_DIR" "$SITE_DIR"

# 2. Copy root assets FIRST
echo "------------------------------------------------"
echo "==> Copying root assets..."
if [ -d "$ASSETS_DIR" ]; then
    for f in style.css favicon.png logo.png icon.png; do
        if [ -f "$ASSETS_DIR/$f" ]; then
            cp "$ASSETS_DIR/$f" "$SITE_DIR/$f"
        fi
    done
    # Fallback for favicon.ico
    if [ -f "$SITE_DIR/favicon.png" ]; then
        cp "$SITE_DIR/favicon.png" "$SITE_DIR/favicon.ico"
    fi
fi

# 3. Fetch public repositories
echo "==> Fetching public repositories for $USERNAME..."
REPOS_JSON=$(gh repo list "$USERNAME" --visibility=public --limit 100 --json name,description -q '.[] | select(.name != "git-mirror" and .name != "register" and .name != "osma")')

echo "==> Processing repositories with gitmal..."
echo "$REPOS_JSON" | jq -c '.' | while read -r repo_info; do
    REPO=$(echo "$repo_info" | jq -r '.name')
    DESC=$(echo "$repo_info" | jq -r '.description // "No description provided."')

    # Truncate description if it's longer than 30 characters
    if [ ${#DESC} -gt 30 ]; then
        DESC="${DESC:0:30}..."
    fi

    echo "------------------------------------------------"
    echo "==> Processing: $REPO"

    # Clone standard repository (gitmal requires a working tree, shallow clone saves time)
    git clone --depth 1 "https://github.com/$USERNAME/$REPO.git" "$REPOS_DIR/$REPO"

    mkdir -p "$SITE_DIR/$REPO"

    # Generate static HTML pages using gitmal
    gitmal "$REPOS_DIR/$REPO" \
        --output "$SITE_DIR/$REPO" \
        --clone-base "https://github.com/$USERNAME/$REPO" \
        --theme github-dark

    # Copy assets into each repo subfolder safely
    if [ -f "$SITE_DIR/style.css" ]; then cp "$SITE_DIR/style.css" "$SITE_DIR/$REPO/style.css"; fi
    if [ -f "$SITE_DIR/logo.png" ]; then cp "$SITE_DIR/logo.png" "$SITE_DIR/$REPO/logo.png"; fi
    if [ -f "$SITE_DIR/favicon.png" ]; then cp "$SITE_DIR/favicon.png" "$SITE_DIR/$REPO/favicon.png"; fi

    # Track repo data for the custom root index
    echo "$REPO|$DESC" >> "$WORK_DIR/repos_manifest.txt"
done

# 4. Generate central root index.html
echo "------------------------------------------------"
echo "==> Generating root index.html..."
{
    echo "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
    echo "<title>Repositories - $USERNAME</title><link rel=\"stylesheet\" href=\"style.css\"></head><body>"
    echo "<h1>Repositories</h1><hr>"
    echo "<table id=\"index\"><thead><tr><th>Name</th><th>Description</th></tr></thead><tbody>"

    if [ -f "$WORK_DIR/repos_manifest.txt" ]; then
        while IFS='|' read -r r_name r_desc; do
            echo "<tr><td><a href=\"$r_name/index.html\">$r_name</a></td><td class=\"desc\">$r_desc</td></tr>"
        done < "$WORK_DIR/repos_manifest.txt"
        rm -f "$WORK_DIR/repos_manifest.txt"
    fi

    echo "</tbody></table></body></html>"
} > "$SITE_DIR/index.html"

# Create root last_commit file
cat <<EOF > "$SITE_DIR/last_commit"
Host: git.amit.is-a.dev
Source Repository: $REPO_NAME
Commit: $MIRROR_FULL_HASH
Commit Date: $MIRROR_COMMIT_DATE
Build Date: $BUILD_TIME
EOF

# 5. Inject formatted multi-line build footer into EVERY generated HTML page
FOOTER_HTML="<div id=\"build-info\">
  <a href=\"https://github.com/$USERNAME\" target=\"_blank\">$USERNAME</a> | 
  Site Built: $BUILD_TIME | 
  git-mirror commit: <a href=\"https://github.com/$REPO_NAME/commit/$MIRROR_FULL_HASH\" target=\"_blank\">$MIRROR_COMMIT_HASH</a> [<a href=\"/last_commit\" target=\"_blank\">view raw info</a>]<br>Originally created with <a href=\"https://github.com/antonmedv/gitmal\" target=\"_blank\">gitmal</a> | 
  slightly modified by <a href=\"https://github.com/notamitgamer\">notamitgamer</a>"

find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    "s|</body>|$FOOTER_HTML\n</body>|g"

# Copy CNAME if present
if [ -f "$WORK_DIR/CNAME" ]; then
    cp "$WORK_DIR/CNAME" "$SITE_DIR/CNAME"
fi

echo "------------------------------------------------"
echo "==> Injecting mobile viewport meta tags..."
find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    's#<head>#<head>\n\t<meta name="viewport" content="width=device-width, initial-scale=1">#'

# --- sitemap.xml ---
echo "------------------------------------------------"
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

# --- 404.html (styled to match the site) ---
echo "==> Generating 404.html..."
cat <<EOF > "$SITE_DIR/404.html"
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
EOF

echo "==> Build complete! Output generated in ./site"
