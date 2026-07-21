#!/usr/bin/env bash
set -e

USERNAME="notamitgamer"
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
    for f in style.css favicon.png logo.png; do
        if [ -f "$ASSETS_DIR/$f" ]; then
            cp "$ASSETS_DIR/$f" "$SITE_DIR/$f"
        fi
    done
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

    # Copy last_commit file into repo subfolder
    cat <<EOF > "$SITE_DIR/$REPO/last_commit"
Host: git.amit.is-a.dev
Source Repository: notamitgamer/git-mirror
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
Source Repository: notamitgamer/git-mirror
Commit: $MIRROR_FULL_HASH
Commit Date: $MIRROR_COMMIT_DATE
Build Date: $BUILD_TIME
EOF

# 5. Inject formatted build footer into EVERY generated HTML page
# Uses literal UTF-8 symbols (© and •) and links view raw info to /last_commit
FOOTER_HTML="<div id=\"build-info\">© 2025-2026 <a href=\"https://github.com/notamitgamer\" target=\"_blank\">notamitgamer</a> • Site Built: $BUILD_TIME • git-mirror commit: <a href=\"https://github.com/notamitgamer/git-mirror/commit/$MIRROR_FULL_HASH\" target=\"_blank\">$MIRROR_COMMIT_HASH</a> [<a href=\"/last_commit\" target=\"_blank\">view raw info</a>]</div>"

find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    "s#</body>#$FOOTER_HTML\n</body>#g"

# Copy CNAME if present
if [ -f "$WORK_DIR/CNAME" ]; then
    cp "$WORK_DIR/CNAME" "$SITE_DIR/CNAME"
fi

echo "------------------------------------------------"
echo "==> Injecting mobile viewport meta tags..."
find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    's#<head>#<head>\n\t<meta name="viewport" content="width=device-width, initial-scale=1">#'

echo "==> Build complete! Output generated in ./site"