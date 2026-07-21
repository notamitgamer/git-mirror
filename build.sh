#!/usr/bin/env bash
set -e

# Automatically detect owner running the Action, fallback to notamitgamer locally
USERNAME="${GITHUB_REPOSITORY_OWNER:-notamitgamer}"
REPO_NAME="${GITHUB_REPOSITORY:-$USERNAME/git-mirror}"
WORK_DIR="$(pwd)"
REPOS_DIR="$WORK_DIR/raw_repos"
SITE_DIR="$WORK_DIR/site"
ASSETS_DIR="$WORK_DIR/assets"

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

echo "==> Processing repositories..."

echo "$REPOS_JSON" | jq -c '.' | while read -r repo_info; do
    REPO=$(echo "$repo_info" | jq -r '.name')
    DESC=$(echo "$repo_info" | jq -r '.description // "No description provided."')

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
            }
        } else if (hash === '' || hash === '#') {
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

# Create root last_commit file
cat <<EOF > "$SITE_DIR/last_commit"
Host: git.amit.is-a.dev
Source Repository: $REPO_NAME
Commit: $MIRROR_FULL_HASH
Commit Date: $MIRROR_COMMIT_DATE
Build Date: $BUILD_TIME
EOF

# 5. Inject UNIVERSAL SMART BACK NAVIGATION SCRIPT into EVERY generated HTML page

D=$'\x01'
find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    "s${D}</body>${D}<script>\n\
document.addEventListener('DOMContentLoaded', () => {\n\
    const path = window.location.pathname;\n\
    if (path === '/' || path.endsWith('/index.html') && !path.includes('/site/')) {\n\
        const repoLinks = document.querySelectorAll('#index a');\n\
        if (repoLinks.length && !document.querySelector('.back-nav')) return;\n\
    }\n\
    if (path === '/' || path.endsWith('/site/index.html')) return;\n\
    const firstHr = document.querySelector('hr');\n\
    if (!firstHr) return;\n\
    const container = document.createElement('div');\n\
    container.className = 'back-nav';\n\
    container.style.margin = '8px 0 12px 0';\n\
    container.style.fontWeight = 'bold';\n\
    container.style.fontSize = '13px';\n\
    const segments = path.split('/').filter(Boolean);\n\
    if (!segments.length) return;\n\
    const fileIdx = segments.indexOf('file');\n\
    const commitIdx = segments.indexOf('commit');\n\
    let fallbackHref = '/';\n\
    \n\
    /* --- CONSTANT LABEL: ALWAYS JUST SVG + \"Back\" --- */\n\
    const svgIcon = '<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\" style=\"vertical-align: text-bottom; margin-right: 5px;\" class=\"lucide lucide-arrow-left-icon lucide-arrow-left\"><path d=\"m12 19-7-7 7-7\"/><path d=\"M19 12H5\"/></svg>';\n\
    const fallbackLabel = svgIcon + 'Back';\n\
    \n\
    if (fileIdx !== -1 && fileIdx < segments.length - 1) {\n\
        const repoRootUrl = '/' + segments.slice(0, fileIdx).join('/');\n\
        const filePathSegments = segments.slice(fileIdx + 1);\n\
        if (filePathSegments.length > 1) {\n\
            const folderPath = filePathSegments.slice(0, -1).join('/');\n\
            fallbackHref = repoRootUrl + '/files.html#folder=' + encodeURIComponent(folderPath);\n\
        } else {\n\
            fallbackHref = repoRootUrl + '/files.html';\n\
        }\n\
    } else if (commitIdx !== -1) {\n\
        const repoRootUrl = '/' + segments.slice(0, commitIdx).join('/');\n\
        fallbackHref = repoRootUrl + '/log.html';\n\
    } else if (path.endsWith('files.html')) {\n\
        const hash = window.location.hash;\n\
        if (hash.startsWith('#folder=')) {\n\
            const folderPath = decodeURIComponent(hash.replace('#folder=', ''));\n\
            const parts = folderPath.split('/').filter(Boolean);\n\
            if (parts.length > 1) {\n\
                fallbackHref = '#folder=' + encodeURIComponent(parts.slice(0, -1).join('/'));\n\
            } else {\n\
                fallbackHref = '#';\n\
            }\n\
        } else {\n\
            fallbackHref = '/';\n\
        }\n\
    } else {\n\
        fallbackHref = '/';\n\
    }\n\
    const link = document.createElement('a');\n\
    link.href = fallbackHref;\n\
    link.innerHTML = fallbackLabel;\n\
    link.style.textDecoration = 'none';\n\
    link.addEventListener('click', (e) => {\n\
        if (window.history.length > 1) {\n\
            e.preventDefault();\n\
            window.history.back();\n\
        }\n\
    });\n\
    container.appendChild(link);\n\
    firstHr.parentNode.insertBefore(container, firstHr.nextSibling);\n\
});\n\
</script>\n</body>${D}g"

# 6. Inject formatted multi-line build footer into EVERY generated HTML page
FOOTER_HTML="<div id=\"build-info\">© <a href=\"https://github.com/$USERNAME\" target=\"_blank\">$USERNAME</a> • Site Built: $BUILD_TIME • git-mirror commit: <a href=\"https://github.com/$REPO_NAME/commit/$MIRROR_FULL_HASH\" target=\"_blank\">$MIRROR_COMMIT_HASH</a> [<a href=\"/last_commit\" target=\"_blank\">view raw info</a>]<br>Originally created with <a href=\"https://codemadness.org/stagit.html\" target=\"_blank\">stagit</a> • modified by <a href=\"https://github.com/notamitgamer\">notamitgamer</a><br>Forked from <a href=\"https://github.com/notamitgamer/git-mirror\" target=\"_blank\">github.com/notamitgamer/git-mirror</a></div>"

find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    "s${D}</body>${D}$FOOTER_HTML\n</body>${D}g"

# Copy CNAME if present
if [ -f "$WORK_DIR/CNAME" ]; then
    cp "$WORK_DIR/CNAME" "$SITE_DIR/CNAME"
fi

echo "------------------------------------------------"
echo "==> Injecting mobile viewport meta tags..."
find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    's#<head>#<head>\n\t<meta name="viewport" content="width=device-width, initial-scale=1">#'

echo "==> Build complete! Output generated in ./site"
