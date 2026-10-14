#!/usr/bin/env bash

repo_info="$1"
[ -z "$repo_info" ] && exit 0

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/echo

USERNAME="${GITHUB_REPOSITORY_OWNER:-notamitgamer}"
REPO_NAME="${GITHUB_REPOSITORY:-$USERNAME/git-mirror}"
WORK_DIR="$PWD"
REPOS_DIR="$WORK_DIR/raw_repos"
SITE_DIR="$WORK_DIR/site"

REPO=$(echo "$repo_info" | jq -r '.name')
DESC=$(echo "$repo_info" | jq -r '.description // "No description provided."')

# Truncate long descriptions (cards have room for more than the old 30 chars)
if [ ${#DESC} -gt 140 ]; then
    DESC="${DESC:0:140}..."
fi

TARGET="$REPOS_DIR/$REPO.git"
WEB_TARGET="$SITE_DIR/$REPO"

mkdir -p "$REPOS_DIR" "$WEB_TARGET"

# 1. Shallow clone/fetch
if [ ! -d "$TARGET" ]; then
    timeout 25s git clone --depth 50 --bare "https://github.com/$USERNAME/$REPO.git" "$TARGET" 2>/dev/null || exit 0
else
    timeout 20s git -C "$TARGET" fetch --depth 50 origin 2>/dev/null || true
fi

# 2. Set stagit metadata
echo "$DESC" > "$TARGET/description"
echo "$USERNAME" > "$TARGET/owner"

# 3. Generate stagit pages
(
    cd "$WEB_TARGET"
    stagit "$TARGET" 2>/dev/null || true
    if [ -f "$SITE_DIR/style.css" ]; then cp "$SITE_DIR/style.css" style.css; fi
    if [ -f "$SITE_DIR/logo.png" ]; then cp "$SITE_DIR/logo.png" logo.png; fi
    if [ -f "$SITE_DIR/favicon.png" ]; then cp "$SITE_DIR/favicon.png" favicon.png; fi
)

# 4. Make files.html default landing page
[ -f "$WEB_TARGET/files.html" ] && cp -f "$WEB_TARGET/files.html" "$WEB_TARGET/index.html"

# 5. Insert Activity Link into Stagit's Navbar
(
    cd "$WEB_TARGET"
    find . -name "*.html" -print0 | xargs -0 sed -i -E \
        's#(<a href="([^"]*)refs\.html">Refs</a>)#\1 | <a href="\2activity.html">Activity</a>#' 2>/dev/null || true
)

# 6. Generate SVG stats graph & activity.html
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

    local svg="<svg viewBox=\"0 0 ${svg_width} 60\" preserveAspectRatio=\"none\" xmlns=\"http://www.w3.org/2000/svg\" class=\"stats-svg\" aria-label=\"commit activity, last ${bar_count} weeks\">"
    local x=0
    while read -r c w; do
        [ -z "$c" ] && continue
        local h=$(( c * 52 / max )); [ "$h" -lt 2 ] && h=2
        local y=$(( 60 - h ))
        svg="$svg<rect x=\"$x\" y=\"$y\" width=\"16\" height=\"$h\"><title>${w}:${c} commit(s)</title></rect>"
        x=$(( x + 20 ))
    done <<< "$counts"
    svg="$svg</svg>"
    echo "$svg"
}

LAST_COMMIT_HASH=$(git -C "$TARGET" log -1 --format="%H" 2>/dev/null || echo "unknown")
LAST_COMMIT_SHORT=$(git -C "$TARGET" log -1 --format="%h" 2>/dev/null || echo "unknown")
LAST_COMMIT_TIME=$(git -C "$TARGET" log -1 --format="%cd" --date=iso-strict 2>/dev/null || echo "unknown")
REPO_SIZE=$(du -sh "$TARGET" 2>/dev/null | cut -f1)
[ -z "$REPO_SIZE" ] && REPO_SIZE="unknown"
ACTIVITY_SVG=$(generate_stats_svg "$TARGET")

BACK_ARROW_SVG='<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-move-left-icon lucide-move-left"><path d="m12 19-7-7 7-7"/><path d="M19 12H5"/></svg>'
NAV_LINKS="<a href=\"files.html\" class=\"nav-arrow\">${BACK_ARROW_SVG}</a>"

{
    echo "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
    echo "<title>$REPO - Activity</title><link rel=\"stylesheet\" href=\"style.css\"></head><body>"
    echo "<h1>$REPO</h1><p class=\"desc\">$DESC</p>"
    echo "<p>$NAV_LINKS</p><hr>"
    echo "<div id=\"activity-meta\">"
    echo "<h2>Activity record of '<u>$USERNAME/$REPO</u>'</h2><br>"
    echo "<p>GitHub: <a href=\"https://github.com/$USERNAME/$REPO\" target=\"_blank\">github.com/$USERNAME/$REPO</a></p>"
    echo "<p>Clone: <code>git clone https://github.com/$USERNAME/$REPO.git</code></p><br>"
    echo "<p>Last commit: <a href=\"https://github.com/$USERNAME/$REPO/commit/$LAST_COMMIT_HASH\" target=\"_blank\">$LAST_COMMIT_SHORT</a> ($LAST_COMMIT_TIME)</p>"
    echo "<p>Repository size (approx): $REPO_SIZE</p>"
    echo "</div>"
    if [ -n "$ACTIVITY_SVG" ]; then
        echo "<div id=\"activity-graph\"><span class=\"stats-label\">commit activity</span><div class=\"activity-graph-wrap\">$ACTIVITY_SVG</div></div>"
    fi
    echo "</body></html>"
} > "$WEB_TARGET/activity.html"

# 7. Inject recursive folder tree script into files.html
if [ -f "$WEB_TARGET/files.html" ]; then
    cat <<'JSEOF' >> "$WEB_TARGET/files.html"
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
JSEOF
fi

# 8. Python Breadcrumbs on file/**/*.html
python3 - "$WEB_TARGET" <<'PYEOF'
import os, re, sys

repo_dir = sys.argv[1]
file_root = os.path.join(repo_dir, "file")
if os.path.isdir(file_root):
    for dirpath, _dirnames, filenames in os.walk(file_root):
        for fname in filenames:
            if not fname.endswith(".html"):
                continue
            full_path = os.path.join(dirpath, fname)
            rel_to_repo = os.path.relpath(full_path, repo_dir)
            parts = rel_to_repo.split(os.sep)
            depth = len(parts) - 1
            up = "../" * depth
            folder_parts = parts[1:-1]
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

echo "[✓] Built: $REPO"
