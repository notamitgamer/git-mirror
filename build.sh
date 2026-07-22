#!/usr/bin/env bash
set -e

# Automatically detect owner running the Action, fallback to notamitgamer locally
USERNAME="${GITHUB_REPOSITORY_OWNER:-notamitgamer}"
REPO_NAME="${GITHUB_REPOSITORY:-$USERNAME/git-mirror}"
WORK_DIR="$(pwd)"
REPOS_DIR="$WORK_DIR/raw_repos"
SITE_DIR="$WORK_DIR/site"
ASSETS_DIR="$WORK_DIR/assets"
META_FILE="$WORK_DIR/repo_meta.tsv"   # NEW: name<TAB>lang<TAB>updated, written inside the loop

# Site base URL used for sitemap.xml (CNAME wins, else github.io URL)
if [ -f "$WORK_DIR/CNAME" ]; then
    SITE_BASE_URL="https://$(cat "$WORK_DIR/CNAME" | tr -d '[:space:]')"
else
    SITE_BASE_URL="https://${USERNAME}.github.io"
fi

# 1. Capture git-mirror Repository Commit & Build Metadata
MIRROR_COMMIT_HASH=$(git -C "$WORK_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
MIRROR_FULL_HASH=$(git -C "$WORK_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
MIRROR_COMMIT_DATE=$(git -C "$WORK_DIR" log -1 --format="%cd" --date=iso-strict 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

rm -rf "$REPOS_DIR" "$SITE_DIR" "$META_FILE"
mkdir -p "$REPOS_DIR" "$SITE_DIR"
touch "$META_FILE"

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

# --- NEW: lightweight, dependency-free markdown -> HTML converter for README rendering ---
# Not a full CommonMark implementation on purpose (keeps the build fast and the page light):
# supports headings, bold/italic, inline code, links, fenced code blocks, and lists/paragraphs.
md_to_html() {
    local input_file="$1"
    sed -E \
        -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' \
        -e 's/```/\x01CODEFENCE\x01/g' \
        "$input_file" | \
    awk '
    BEGIN { in_code=0; in_list=0 }
    {
        line=$0
        if (line ~ /\x01CODEFENCE\x01/) {
            if (in_code==0) { print "<pre><code>"; in_code=1 }
            else { print "</code></pre>"; in_code=0 }
            next
        }
        if (in_code==1) { print; next }

        if (line ~ /^### /) { sub(/^### /,""); print "<h3>" line "</h3>"; next }
        if (line ~ /^## /)  { sub(/^## /,"");  print "<h2>" line "</h2>"; next }
        if (line ~ /^# /)   { sub(/^# /,"");   print "<h1>" line "</h1>"; next }

        if (line ~ /^[-*] /) {
            if (in_list==0) { print "<ul>"; in_list=1 }
            sub(/^[-*] /,"")
            print "<li>" line "</li>"
            next
        } else if (in_list==1) { print "</ul>"; in_list=0 }

        if (line == "") { next }
        print "<p>" line "</p>"
    }
    END { if(in_list==1) print "</ul>"; if(in_code==1) print "</code></pre>" }
    ' | \
    sed -E \
        -e 's/`([^`]+)`/<code>\1<\/code>/g' \
        -e 's/\*\*([^*]+)\*\*/<b>\1<\/b>/g' \
        -e 's/\*([^*]+)\*/<i>\1<\/i>/g' \
        -e 's/\[([^]]+)\]\(([^)]+)\)/<a href="\2" target="_blank">\1<\/a>/g'
}

# --- NEW: tiny dependency-free commit-activity sparkline (SVG) for repo stats ---
generate_stats_svg() {
    local git_dir="$1"
    local counts
    counts=$(git -C "$git_dir" log --format=%cd --date=format:%G-W%V 2>/dev/null | sort | uniq -c | tail -12)
    [ -z "$counts" ] && { echo ""; return; }

    local max=1
    while read -r c _; do
        [ -z "$c" ] && continue
        if [ "$c" -gt "$max" ]; then max=$c; fi
    done <<< "$counts"

    local svg="<svg viewBox=\"0 0 240 40\" xmlns=\"http://www.w3.org/2000/svg\" class=\"stats-svg\" aria-label=\"commit activity, last 12 weeks\">"
    local x=0
    while read -r c w; do
        [ -z "$c" ] && continue
        local h=$(( c * 34 / max )); [ "$h" -lt 2 ] && h=2
        local y=$(( 40 - h ))
        svg="$svg<rect x=\"$x\" y=\"$y\" width=\"16\" height=\"$h\"><title>${w}: ${c} commit(s)</title></rect>"
        x=$(( x + 20 ))
    done <<< "$counts"
    svg="$svg</svg>"
    echo "$svg"
}

# 3. Fetch public repositories
echo "==> Fetching public repositories for $USERNAME..."
# NEW: also pull pushedAt + primaryLanguage for the "last updated" and "language" badges
REPOS_JSON=$(gh repo list "$USERNAME" --visibility=public --limit 100 --json name,description,pushedAt,primaryLanguage -q '.[] | select(.name != "git-mirror" and .name != "register" and .name != "osma")')

echo "==> Processing repositories..."

echo "$REPOS_JSON" | jq -c '.' | while read -r repo_info; do
    REPO=$(echo "$repo_info" | jq -r '.name')
    DESC=$(echo "$repo_info" | jq -r '.description // "No description provided."')
    PUSHED_AT=$(echo "$repo_info" | jq -r '.pushedAt // ""')
    PUSHED_DATE=$(date -u -d "$PUSHED_AT" +"%Y-%m-%d" 2>/dev/null || echo "$PUSHED_AT")
    LANG=$(echo "$repo_info" | jq -r '.primaryLanguage.name // "N/A"')

    # Truncate description if it's longer than 30 characters
    if [ ${#DESC} -gt 30 ]; then
        DESC="${DESC:0:30}..."
    fi

    echo "------------------------------------------------"
    echo "==> Processing: $REPO"

    # Clone bare repository
    git clone --bare "https://github.com/$USERNAME/$REPO.git" "$REPOS_DIR/$REPO.git"

    # Overwrite default Git placeholder files
    echo "$DESC" > "$REPOS_DIR/$REPO.git/description"
    echo "$USERNAME" > "$REPOS_DIR/$REPO.git/owner"

    mkdir -p "$SITE_DIR/$REPO"

    # record metadata for later badge injection into the central index (subshell-safe: append to file)
    printf "%s\t%s\t%s\n" "$REPO" "$LANG" "$PUSHED_DATE" >> "$META_FILE"

    # Generate stagit HTML pages
    (
        cd "$SITE_DIR/$REPO"
        stagit "$REPOS_DIR/$REPO.git"

        # Copy assets into each repo subfolder safely
        if [ -f "$SITE_DIR/style.css" ]; then cp "$SITE_DIR/style.css" style.css; fi
        if [ -f "$SITE_DIR/logo.png" ]; then cp "$SITE_DIR/logo.png" logo.png; fi
        if [ -f "$SITE_DIR/favicon.png" ]; then cp "$SITE_DIR/favicon.png" favicon.png; fi
    )

    # --- NEW: README rendering ---------------------------------------------------
    README_SRC=""
    for candidate in README.md README.MD Readme.md README; do
        if git -C "$REPOS_DIR/$REPO.git" cat-file -e "HEAD:$candidate" 2>/dev/null; then
            README_SRC="$candidate"
            break
        fi
    done
    if [ -n "$README_SRC" ]; then
        git -C "$REPOS_DIR/$REPO.git" show "HEAD:$README_SRC" > "$WORK_DIR/_readme_tmp.md" 2>/dev/null || true
        {
            echo "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
            echo "<title>$REPO - README</title><link rel=\"stylesheet\" href=\"style.css\"></head><body>"
            echo "<div class=\"back-nav\"><a href=\"index.html\">← back to $REPO</a></div>"
            echo "<div id=\"readme-content\">"
            md_to_html "$WORK_DIR/_readme_tmp.md"
            echo "</div></body></html>"
        } > "$SITE_DIR/$REPO/readme.html"
        rm -f "$WORK_DIR/_readme_tmp.md"
    fi

    # --- NEW: repo stats sparkline, added near the top of log.html ---------------
    STATS_SVG=$(generate_stats_svg "$REPOS_DIR/$REPO.git")
    if [ -n "$STATS_SVG" ] && [ -f "$SITE_DIR/$REPO/log.html" ]; then
        STATS_BLOCK="<div id=\"repo-stats\"><span class=\"stats-label\">commit activity (12w)</span>$STATS_SVG</div>"
        # insert right after the opening <body> tag
        python3 - "$SITE_DIR/$REPO/log.html" "$STATS_BLOCK" <<'PYEOF'
import sys
path, block = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    html = f.read()
html = html.replace("<body>", "<body>" + block, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(html)
PYEOF
    fi

    # --- NEW: readme link + "copy clone url" text button on the repo's own index.html
    if [ -f "$SITE_DIR/$REPO/index.html" ]; then
        if [ -n "$README_SRC" ]; then
            sed -i "s|</body>|<div class=\"back-nav\"><a href=\"readme.html\">README</a></div>\n</body>|" "$SITE_DIR/$REPO/index.html"
        fi
        cat <<'EOF' >> "$SITE_DIR/$REPO/index.html"
<script>
document.addEventListener('DOMContentLoaded', () => {
    // Find the row/cell that contains the clone URL text and append a plain-text copy link
    const candidates = Array.from(document.querySelectorAll('td, pre'));
    const cloneCell = candidates.find(el => /git clone/i.test(el.textContent));
    if (!cloneCell) return;
    const urlMatch = cloneCell.textContent.match(/https?:\/\/\S+\.git/);
    if (!urlMatch) return;
    const url = urlMatch[0];
    const btn = document.createElement('a');
    btn.href = '#';
    btn.textContent = '[copy]';
    btn.style.marginLeft = '8px';
    btn.addEventListener('click', (e) => {
        e.preventDefault();
        navigator.clipboard.writeText(url).then(() => {
            const original = btn.textContent;
            btn.textContent = '[copied]';
            setTimeout(() => { btn.textContent = original; }, 1200);
        });
    });
    cloneCell.appendChild(btn);
});
</script>
EOF
    fi

    # --- INJECT RECURSIVE FOLDER TREE & HASH NAV SCRIPT INTO files.html ---
    if [ -f "$SITE_DIR/$REPO/files.html" ]; then
        cat <<'EOF' >> "$SITE_DIR/$REPO/files.html"
<script>
document.addEventListener('DOMContentLoaded', () => {
    const table = document.querySelector('#files, #content table');
    if (!table) return;

    const tbody = table.querySelector('tbody') || table;
    const rows = Array.from(table.querySelectorAll('tr')).filter(r => r.querySelector('td a'));
    if (!rows.length) return;

    const svgClosed = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align: middle; margin-right: 6px;"><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/><path d="M2 10h20"/></svg>`;
    const svgOpen = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align: middle; margin-right: 6px;"><path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/></svg>`;

    const root = { name: '', children: {}, files: [], path: '' };
    const nodeMap = {};

    rows.forEach(row => {
        const link = row.querySelector('td a');
        if (!link) return;

        const fullPath = link.textContent.trim();
        const parts = fullPath.split('/');

        let current = root;
        let pathAcc = '';

        for (let i = 0; i < parts.length - 1; i++) {
            const part = parts[i];
            pathAcc = pathAcc ? `${pathAcc}/${part}` : part;

            if (!current.children[part]) {
                const newNode = { name: part, children: {}, files: [], path: pathAcc, row: null, expanded: false };
                current.children[part] = newNode;
                nodeMap[pathAcc] = newNode;
            }
            current = current.children[part];
        }

        const fileName = parts[parts.length - 1];
        link.innerHTML = `<span class="file-name">${fileName}</span>`;
        current.files.push({ name: fileName, row: row });
    });

    rows.forEach(r => r.remove());

    // --- NEW: breadcrumb bar, inserted directly above the file table ---
    const breadcrumb = document.createElement('div');
    breadcrumb.id = 'breadcrumb-nav';
    table.parentNode.insertBefore(breadcrumb, table);

    function renderBreadcrumb(path) {
        const parts = path ? path.split('/') : [];
        let html = '<a href="#" data-path="">root</a>';
        let acc = '';
        parts.forEach(part => {
            acc = acc ? `${acc}/${part}` : part;
            html += ` / <a href="#" data-path="${acc}">${part}</a>`;
        });
        breadcrumb.innerHTML = html;
        breadcrumb.querySelectorAll('a').forEach(a => {
            a.addEventListener('click', (e) => {
                e.preventDefault();
                const p = a.getAttribute('data-path');
                window.location.hash = p ? `folder=${encodeURIComponent(p)}` : '';
            });
        });
    }

    function renderNode(node, depth, parentVisible) {
        const indent = depth * 14;
        const subfolderKeys = Object.keys(node.children).sort();

        subfolderKeys.forEach(key => {
            const childNode = node.children[key];
            const headerRow = document.createElement('tr');
            headerRow.classList.add('folder-header');
            childNode.row = headerRow;

            if (!parentVisible) {
                headerRow.style.display = 'none';
            }

            const totalItems = Object.keys(childNode.children).length + childNode.files.length;

            const updateHeader = () => {
                const icon = childNode.expanded ? svgOpen : svgClosed;
                headerRow.innerHTML = `<td colspan="4" style="padding-left: ${8 + indent}px !important;">${icon}<span style="vertical-align: middle;">${childNode.name}/</span> <span style="font-weight:normal;font-size:0.85em;opacity:0.7;vertical-align: middle;">(${totalItems})</span></td>`;
            };

            childNode.updateHeader = updateHeader;
            updateHeader();

            headerRow.addEventListener('click', (e) => {
                e.stopPropagation();
                childNode.expanded = !childNode.expanded;
                updateHeader();
                toggleVisibility(childNode, childNode.expanded);

                if (childNode.expanded) {
                    window.location.hash = `folder=${encodeURIComponent(childNode.path)}`;
                } else {
                    const parentPath = childNode.path.includes('/') ? childNode.path.substring(0, childNode.path.lastIndexOf('/')) : '';
                    window.location.hash = parentPath ? `folder=${encodeURIComponent(parentPath)}` : '';
                }
            });

            tbody.appendChild(headerRow);
            renderNode(childNode, depth + 1, false);
        });

        if (depth > 0) {
            node.files.sort((a, b) => a.name.localeCompare(b.name)).forEach(file => {
                const fileRow = file.row;
                const linkCell = fileRow.querySelector('td a');
                if (linkCell) {
                    linkCell.style.paddingLeft = `${indent}px`;
                }
                fileRow.style.display = parentVisible ? '' : 'none';
                tbody.appendChild(fileRow);
            });
        }
    }

    function toggleVisibility(node, show) {
        node.files.forEach(f => f.row.style.display = show ? '' : 'none');

        Object.keys(node.children).forEach(key => {
            const child = node.children[key];
            child.row.style.display = show ? '' : 'none';

            if (show && child.expanded) {
                toggleVisibility(child, true);
            } else if (!show) {
                toggleVisibility(child, false);
            }
        });
    }

    function expandToFolder(targetPath) {
        const parts = targetPath.split('/');
        let currentPath = '';
        parts.forEach(part => {
            currentPath = currentPath ? `${currentPath}/${part}` : part;
            const node = nodeMap[currentPath];
            if (node) {
                node.expanded = true;
                if (node.updateHeader) node.updateHeader();
                toggleVisibility(node, true);
                if (node.row) node.row.style.display = '';
            }
        });
    }

    renderNode(root, 0, true);

    root.files.sort((a, b) => a.name.localeCompare(b.name)).forEach(file => {
        file.row.style.display = '';
        tbody.appendChild(file.row);
    });

    function applyHashState() {
        const hash = window.location.hash;
        if (hash.startsWith('#folder=')) {
            const folderPath = decodeURIComponent(hash.replace('#folder=', ''));
            if (folderPath) {
                expandToFolder(folderPath);
                renderBreadcrumb(folderPath);
                return;
            }
        }
        if (hash === '' || hash === '#') {
            Object.values(nodeMap).forEach(node => {
                node.expanded = false;
                if (node.updateHeader) node.updateHeader();
                toggleVisibility(node, false);
                if (node.path.includes('/')) {
                    if (node.row) node.row.style.display = 'none';
                } else {
                    if (node.row) node.row.style.display = '';
                }
            });
            renderBreadcrumb('');
        }
    }

    applyHashState();
    window.addEventListener('hashchange', applyHashState);
});
</script>
EOF
    fi

    # Copy last_commit file into repo subfolder
    cat <<EOF > "$SITE_DIR/$REPO/last_commit"
Host: git.amit.is-a.dev
Source Repository: $REPO_NAME
Commit: $MIRROR_FULL_HASH
Commit Date: $MIRROR_COMMIT_DATE
Build Date: $BUILD_TIME
EOF

done

# 4. Generate central stagit-index
echo "------------------------------------------------"
echo "==> Generating central stagit-index..."
stagit-index "$REPOS_DIR"/*.git > "$SITE_DIR/index.html"

# --- NEW: inject language + last-updated badges and the search bar into the central index ---
if [ -f "$META_FILE" ] && [ -f "$SITE_DIR/index.html" ]; then
    while IFS=$'\t' read -r REPO LANG PUSHED_DATE; do
        [ -z "$REPO" ] && continue
        BADGE="<span class=\"badge lang-badge\">${LANG}</span><span class=\"badge updated-badge\">${PUSHED_DATE}</span>"
        # stagit-index links repos as href="REPO/", insert badges right after that anchor's closing tag on the same line
        sed -i "s|\(<a href=\"${REPO}/\"[^<]*</a>\)|\1 ${BADGE}|" "$SITE_DIR/index.html"
    done < "$META_FILE"
fi

python3 - "$SITE_DIR/index.html" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    html = f.read()

search_block = '''<div id="repo-search"><input type="text" id="repo-search-input" placeholder="filter repositories..." autocomplete="off"></div>
<script>
document.addEventListener('DOMContentLoaded', () => {
    const input = document.getElementById('repo-search-input');
    const table = document.querySelector('#index table, table');
    if (!input || !table) return;
    const rows = Array.from(table.querySelectorAll('tbody tr, tr')).filter(r => r.querySelector('td a'));
    input.addEventListener('input', () => {
        const q = input.value.toLowerCase();
        rows.forEach(r => {
            r.style.display = r.textContent.toLowerCase().includes(q) ? '' : 'none';
        });
    });
});
</script>
'''

if "<body>" in html:
    html = html.replace("<body>", "<body>" + search_block, 1)
else:
    html = search_block + html

with open(path, "w", encoding="utf-8") as f:
    f.write(html)
PYEOF

# Create root last_commit file
cat <<EOF > "$SITE_DIR/last_commit"
Host: git.amit.is-a.dev
Source Repository: $REPO_NAME
Commit: $MIRROR_FULL_HASH
Commit Date: $MIRROR_COMMIT_DATE
Build Date: $BUILD_TIME
EOF

# 5. Inject formatted multi-line build footer into EVERY generated HTML page
FOOTER_HTML="<div id=\"build-info\">© <a href=\"https://github.com/$USERNAME\" target=\"_blank\">$USERNAME</a> • Site Built: $BUILD_TIME • git-mirror commit: <a href=\"https://github.com/$REPO_NAME/commit/$MIRROR_FULL_HASH\" target=\"_blank\">$MIRROR_COMMIT_HASH</a> [<a href=\"/last_commit\" target=\"_blank\">view raw info</a>]<br>Originally created with <a href=\"https://codemadness.org/stagit.html\" target=\"_blank\">stagit</a> • modified by <a href=\"https://github.com/notamitgamer\">notamitgamer</a><br>Forked from <a href=\"https://github.com/notamitgamer/git-mirror\" target=\"_blank\">github.com/notamitgamer/git-mirror</a></div>"

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

# --- NEW: sitemap.xml ---
echo "------------------------------------------------"
echo "==> Generating sitemap.xml..."
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    find "$SITE_DIR" -name "*.html" | sed "s|^$SITE_DIR||" | while read -r p; do
        echo "  <url><loc>${SITE_BASE_URL}${p}</loc></url>"
    done
    echo '</urlset>'
} > "$SITE_DIR/sitemap.xml"

# --- NEW: 404.html (styled to match the site) ---
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
