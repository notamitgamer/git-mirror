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
REPOS_JSON=$(gh repo list "$USERNAME" --visibility=public --limit 100 --json name,description,pushedAt,primaryLanguage -q '.[] | select(.name != "git-mirror" and .name != "register" and .name != "osma")')

echo "==> Processing repositories with gitmal..."
echo "$REPOS_JSON" | jq -c '.' | while read -r repo_info; do
    REPO=$(echo "$repo_info" | jq -r '.name')
    DESC=$(echo "$repo_info" | jq -r '.description // "No description provided."')

    # Truncate description if it's longer than 50 characters for a cleaner look
    if [ ${#DESC} -gt 50 ]; then
        DESC="${DESC:0:50}..."
    fi

    echo "------------------------------------------------"
    echo "==> Processing: $REPO"

    # Clone standard repository (Full clone to display complete commit history)
    git clone "https://github.com/$USERNAME/$REPO.git" "$REPOS_DIR/$REPO"

    mkdir -p "$SITE_DIR/$REPO"

    # Generate static HTML pages using gitmal
    gitmal "$REPOS_DIR/$REPO" \
        --output "$SITE_DIR/$REPO" \
        --owner "$USERNAME" \
        --name "$REPO" \
        --theme github-dark

    # --- git clone support over plain HTTP ("dumb" protocol) ---
    # Git's bare-repo files (HEAD, info/, objects/, refs/, packed-refs) don't clash with
    # gitmal's output (index.html, blob/, commit/, commits/, raw/, ...), so they can live
    # in the same folder. That makes `git clone https://git.amit.is-a.dev/<repo>` work.
    BARE_DIR="$REPOS_DIR/$REPO.bare"
    git clone --bare --quiet "https://github.com/$USERNAME/$REPO.git" "$BARE_DIR"
    git --git-dir="$BARE_DIR" update-server-info
    for item in HEAD info objects refs packed-refs; do
        if [ -e "$BARE_DIR/$item" ]; then cp -r "$BARE_DIR/$item" "$SITE_DIR/$REPO/$item"; fi
    done
    rm -rf "$BARE_DIR"

    # Copy assets into each repo subfolder safely
    if [ -f "$SITE_DIR/style.css" ]; then cp "$SITE_DIR/style.css" "$SITE_DIR/$REPO/style.css"; fi
    if [ -f "$SITE_DIR/logo.png" ]; then cp "$SITE_DIR/logo.png" "$SITE_DIR/$REPO/logo.png"; fi
    if [ -f "$SITE_DIR/favicon.png" ]; then cp "$SITE_DIR/favicon.png" "$SITE_DIR/$REPO/favicon.png"; fi

    # Track repo data for the custom root index (tab-separated; HTML-escape the description)
    PUSHED=$(echo "$repo_info" | jq -r '.pushedAt // ""')
    LANG_NAME=$(echo "$repo_info" | jq -r '.primaryLanguage.name // "-"')
    DESC_ESC=$(printf '%s' "$DESC" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')
    printf '%s\t%s\t%s\t%s\n' "$REPO" "$DESC_ESC" "$PUSHED" "$LANG_NAME" >> "$WORK_DIR/repos_manifest.txt"
done

# 4. Generate central root index.html
echo "------------------------------------------------"
echo "==> Generating root index.html..."
{
    echo "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
    echo "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    echo "<title>Repositories - $USERNAME</title><link rel=\"stylesheet\" href=\"style.css\"></head><body>"
    echo "<main>"
    echo "<div class=\"repo-header\"><h1>Repositories</h1><input id=\"repo-search\" type=\"search\" placeholder=\"Filter repositories...\" aria-label=\"Filter repositories\"></div>"
    echo "<div class=\"table-container\">"
    echo "<table id=\"repo-table\"><thead><tr><th>Repository</th><th class=\"col-desc\">Description</th><th class=\"col-lang\">Language</th><th class=\"col-updated\">Updated</th><th class=\"col-clone\">Clone</th></tr></thead><tbody>"

    if [ -f "$WORK_DIR/repos_manifest.txt" ]; then
        while IFS=$'\t' read -r r_name r_desc r_pushed r_lang; do
            echo "<tr><td><a href=\"$r_name/\">$r_name</a></td><td class=\"desc col-desc\">$r_desc</td><td class=\"col-lang\">$r_lang</td><td class=\"col-updated\"><time datetime=\"$r_pushed\">$r_pushed</time></td><td class=\"col-clone\"><button class=\"copy-btn\" type=\"button\" data-clone=\"git clone https://git.amit.is-a.dev/$r_name\" title=\"Copy: git clone https://git.amit.is-a.dev/$r_name\">Copy</button></td></tr>"
        done < "$WORK_DIR/repos_manifest.txt"
        rm -f "$WORK_DIR/repos_manifest.txt"
    fi

    echo "</tbody></table></div><p id=\"no-results\" class=\"desc\" hidden>No repositories match your filter.</p></main>"
    cat <<'JSEOF'
<script>
(function () {
  // Relative "updated" times
  var rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
  var units = [['year', 31536000], ['month', 2592000], ['day', 86400], ['hour', 3600], ['minute', 60]];
  document.querySelectorAll('time[datetime]').forEach(function (t) {
    var d = new Date(t.getAttribute('datetime'));
    if (isNaN(d)) { t.textContent = '-'; return; }
    var secs = (d - Date.now()) / 1000;
    t.title = d.toLocaleString();
    for (var i = 0; i < units.length; i++) {
      if (Math.abs(secs) >= units[i][1] || units[i][0] === 'minute') {
        t.textContent = rtf.format(Math.round(secs / units[i][1]), units[i][0]);
        break;
      }
    }
  });

  // Live filter (name, description, language); "/" focuses the box
  var input = document.getElementById('repo-search');
  var rows = Array.prototype.slice.call(document.querySelectorAll('#repo-table tbody tr'));
  var empty = document.getElementById('no-results');
  input.addEventListener('input', function () {
    var q = input.value.trim().toLowerCase(), shown = 0;
    rows.forEach(function (r) {
      var hit = r.textContent.toLowerCase().indexOf(q) !== -1;
      r.hidden = !hit;
      if (hit) shown++;
    });
    empty.hidden = shown !== 0;
  });
  document.addEventListener('keydown', function (e) {
    if (e.key === '/' && document.activeElement !== input) { e.preventDefault(); input.focus(); }
  });

  // Copy-to-clipboard for the clone command
  document.querySelectorAll('.copy-btn').forEach(function (b) {
    b.addEventListener('click', function () {
      var done = function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy'; }, 1500); };
      if (navigator.clipboard) { navigator.clipboard.writeText(b.dataset.clone).then(done); }
    });
  });
})();
</script>
JSEOF
    echo "</body></html>"
} > "$SITE_DIR/index.html"

# Create root last_commit file
cat <<EOF > "$SITE_DIR/last_commit"
Host: git.amit.is-a.dev
Source Repository: $REPO_NAME
Commit: $MIRROR_FULL_HASH
Commit Date: $MIRROR_COMMIT_DATE
Build Date: $BUILD_TIME
EOF

# Fingerprint of repo state, read by the workflow's change detection on the next run
echo "${FINGERPRINT:-none}" > "$SITE_DIR/fingerprint.txt"

# 5. Inject formatted build header and footer with INLINE styles to match Gitmal
echo "------------------------------------------------"
echo "==> Injecting global header and footer..."

HEADER_HTML="<div style=\"background-color: #1b1b1f; border-bottom: 1px solid #2e2e34; padding: 12px 24px; display: flex; align-items: center; justify-content: space-between; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;\"><a href=\"/\" style=\"color: #6eb6ff; text-decoration: none; font-size: 14px; font-weight: 600; display: flex; align-items: center; gap: 6px;\"><span style=\"font-size: 16px;\">←</span> Back to Repositories</a><span style=\"color: #9c9ca4; font-size: 13px; font-weight: 500;\">git.amit.is-a.dev</span></div>"

FOOTER_HTML="<div style=\"text-align: center; padding: 24px 16px; font-size: 13px; color: #9c9ca4; border-top: 1px solid #2e2e34; margin-top: 40px; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;\">Site Built: $BUILD_TIME | git-mirror commit: <a href=\"https://github.com/$REPO_NAME/commit/$MIRROR_FULL_HASH\" target=\"_blank\" style=\"color: #6eb6ff; text-decoration: none;\">$MIRROR_COMMIT_HASH</a> [<a href=\"/last_commit\" target=\"_blank\" style=\"color: #6eb6ff; text-decoration: none;\">raw info</a>]<br>Originally created with <a href=\"https://github.com/antonmedv/gitmal\" target=\"_blank\" style=\"color: #6eb6ff; text-decoration: none;\">gitmal</a> | Modified by <a href=\"https://github.com/notamitgamer\" style=\"color: #6eb6ff; text-decoration: none;\">notamitgamer</a></div>"

# Header (with "Back to Repositories") goes on every page except the root index itself
find "$SITE_DIR" -name "*.html" ! -path "$SITE_DIR/index.html" -print0 | xargs -0 sed -i \
    -e "s~<body>~<body>\n$HEADER_HTML~g"
# Footer goes on every page
find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    -e "s~</body>~$FOOTER_HTML\n</body>~g"

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
<main>
<div class="repo-header"><h1>404</h1></div>
<p class="desc">The page you're looking for doesn't exist.</p>
<br>
<a href="/">← back to index</a>
</main>
</body>
</html>
EOF

echo "==> Build complete! Output generated in ./site"
