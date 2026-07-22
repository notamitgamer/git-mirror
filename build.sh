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

# --- tiny dependency-free commit-activity bar graph (SVG), left-to-right, responsive ---
# Used only on the per-repo activity.html page (not injected above file listings).
generate_stats_svg() {
    local git_dir="$1"
    local counts
    counts=$(git -C "$git_dir" log --format=%cd --date=format:%G-W%V 2>/dev/null | sort | uniq -c | tail -20)
    [ -z "$counts" ] && { echo ""; return; }

    local max=1
    while read -r c _; do
        [ -z "$c" ] && continue
        if [ "$c" -gt "$max" ]; then max=$c; fi
    done <<< "$counts"

    local bar_count
    bar_count=$(echo "$counts" | wc -l)
    local svg_width=$(( bar_count * 20 ))
    [ "$svg_width" -lt 40 ] && svg_width=40

    # width/height are percentage-based via CSS so it scales left-to-right on any screen size
    local svg="<svg viewBox=\"0 0 ${svg_width} 60\" preserveAspectRatio=\"none\" xmlns=\"http://www.w3.org/2000/svg\" class=\"stats-svg\" aria-label=\"commit activity, last ${bar_count} weeks\">"
    local x=0
    while read -r c w; do
        [ -z "$c" ] && continue
        local h=$(( c * 52 / max )); [ "$h" -lt 2 ] && h=2
        local y=$(( 60 - h ))
        svg="$svg<rect x=\"$x\" y=\"$y\" width=\"16\" height=\"$h\"><title>${w}: ${c} commit(s)</title></rect>"
        x=$(( x + 20 ))
    done <<< "$counts"
    svg="$svg</svg>"
    echo "$svg"
}

# 3. Fetch public repositories
echo "==> Fetching public repositories for $USERNAME..."
REPOS_JSON=$(gh repo list "$USERNAME" --visibility=public --limit 100 --json name,description -q '.[] | select(.name != "git-mirror" and .name != "register" and .name != "osma")')

echo "==> Processing repositories..."

echo "$REPOS_JSON" | jq -c '.' | while read -r repo_info; do
    REPO=$(echo "$repo_info" | jq -r '.name')
    DESC=$(echo "$repo_info" | jq -r '.description // "No description provided."')

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

    # Generate stagit HTML pages
    (
        cd "$SITE_DIR/$REPO"
        stagit "$REPOS_DIR/$REPO.git"

        # Copy assets into each repo subfolder safely
        if [ -f "$SITE_DIR/style.css" ]; then cp "$SITE_DIR/style.css" style.css; fi
        if [ -f "$SITE_DIR/logo.png" ]; then cp "$SITE_DIR/logo.png" logo.png; fi
        if [ -f "$SITE_DIR/favicon.png" ]; then cp "$SITE_DIR/favicon.png" favicon.png; fi
    )

    # --- add an "Activity" link into stagit's own nav bar on every generated page ---
    # (Log | Files | Refs | Activity | README | LICENSE -- README/LICENSE are added
    # natively by stagit itself when those files exist, we only insert Activity)
    # Matches the existing "Refs" link (with whatever relative path prefix it already has)
    # and appends the Activity link right after it, using the same prefix.
    (
        cd "$SITE_DIR/$REPO"
        find . -name "*.html" -print0 | xargs -0 sed -i -E \
            's#(<a href="([^"]*)refs\.html">Refs</a>)#\1 | <a href="\2activity.html">Activity</a>#'
    )

    # --- NEW activity.html page: clone url, github link, last commit, repo size, commit graph ---
    LAST_COMMIT_HASH=$(git -C "$REPOS_DIR/$REPO.git" log -1 --format="%H" 2>/dev/null || echo "unknown")
    LAST_COMMIT_SHORT=$(git -C "$REPOS_DIR/$REPO.git" log -1 --format="%h" 2>/dev/null || echo "unknown")
    LAST_COMMIT_TIME=$(git -C "$REPOS_DIR/$REPO.git" log -1 --format="%cd" --date=iso-strict 2>/dev/null || echo "unknown")
    REPO_SIZE=$(du -sh "$REPOS_DIR/$REPO.git" 2>/dev/null | cut -f1)
    [ -z "$REPO_SIZE" ] && REPO_SIZE="unknown"
    ACTIVITY_SVG=$(generate_stats_svg "$REPOS_DIR/$REPO.git")

    NAV_LINKS="[<a href=\"files.html\">← Root</a>] | Activity"

    {
        echo "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        echo "<title>$REPO - Activity</title><link rel=\"stylesheet\" href=\"style.css\"></head><body>"
        echo "<h1>$REPO</h1><p class=\"desc\">$DESC</p>"
        echo "<p>$NAV_LINKS</p><hr>"
        echo "<div id=\"activity-meta\">"
        echo "<p>GitHub: <a href=\"https://github.com/$USERNAME/$REPO\" target=\"_blank\">github.com/$USERNAME/$REPO</a></p>"
        echo "<p>Clone: <code>git clone https://github.com/$USERNAME/$REPO.git</code></p>"
        echo "<p>Last commit: <a href=\"https://github.com/$USERNAME/$REPO/commit/$LAST_COMMIT_HASH\" target=\"_blank\">$LAST_COMMIT_SHORT</a> ($LAST_COMMIT_TIME)</p>"
        echo "<p>Repository size (approx): $REPO_SIZE</p>"
        echo "</div>"
        if [ -n "$ACTIVITY_SVG" ]; then
            echo "<div id=\"activity-graph\"><span class=\"stats-label\">commit activity</span><div class=\"activity-graph-wrap\">$ACTIVITY_SVG</div></div>"
        fi
        echo "</body></html>"
    } > "$SITE_DIR/$REPO/activity.html"

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

    // breadcrumb bar, inserted directly above the file table
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

    # --- static breadcrumb on every individual file page (file/**/*.html) ---
    # stagit mirrors the repo's folder structure under file/, e.g.
    # file/semester_1/assignment-primary/assignment-p-01.c.html
    # Placed AFTER stagit's own header/nav block and BEFORE the file content:
    # prefers inserting right before <div id="content">; falls back to right
    # after the header's closing <hr/> if that div isn't found; falls back to
    # right after <body> only as a last resort.
    python3 - "$SITE_DIR/$REPO" <<'PYEOF'
import os, re, sys

repo_dir = sys.argv[1]
file_root = os.path.join(repo_dir, "file")
if os.path.isdir(file_root):
    for dirpath, _dirnames, filenames in os.walk(file_root):
        for fname in filenames:
            if not fname.endswith(".html"):
                continue
            full_path = os.path.join(dirpath, fname)
            rel_to_repo = os.path.relpath(full_path, repo_dir)  # file/foo/bar/baz.c.html
            parts = rel_to_repo.split(os.sep)                   # ['file','foo','bar','baz.c.html']
            depth = len(parts) - 1                              # levels below repo root
            up = "../" * depth
            folder_parts = parts[1:-1]                          # ['foo','bar']
            display_name = parts[-1][:-5] if parts[-1].endswith(".html") else parts[-1]

            crumbs = [f'<a href="{up}files.html">root</a>']
            acc = ""
            for part in folder_parts:
                acc = f"{acc}/{part}" if acc else part
                crumbs.append(f'<a href="{up}files.html#folder={acc}">{part}</a>')
            crumbs.append(f'<span>{display_name}</span>')

            breadcrumb_html = '<div id="file-breadcrumb">' + ' / '.join(crumbs) + '</div>'

            with open(full_path, "r", encoding="utf-8", errors="ignore") as f:
                html = f.read()

            if 'id="file-breadcrumb"' in html:
                continue

            if '<div id="content">' in html:
                html = html.replace('<div id="content">', breadcrumb_html + '<div id="content">', 1)
            elif re.search(r'<hr\s*/?>', html):
                html = re.sub(r'(<hr\s*/?>)', r'\1' + breadcrumb_html, html, count=1)
            elif '<body>' in html:
                html = html.replace('<body>', '<body>' + breadcrumb_html, 1)
            else:
                continue

            with open(full_path, "w", encoding="utf-8") as f:
                f.write(html)
PYEOF

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

# --- sitemap.xml ---
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
