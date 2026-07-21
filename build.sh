#!/usr/bin/env bash
set -e

# Configuration
USERNAME="notamitgamer"
WORK_DIR="$(pwd)"
REPOS_DIR="$WORK_DIR/raw_repos"
SITE_DIR="$WORK_DIR/site"

# Cleanup & directory setup
rm -rf "$REPOS_DIR" "$SITE_DIR"
mkdir -p "$REPOS_DIR" "$SITE_DIR"

echo "==> Fetching public repositories for $USERNAME..."

# Filter out both git-mirror AND register
REPOS=$(gh repo list "$USERNAME" --public --limit 100 --json name -q '.[] | select(.name != "git-mirror" and .name != "register") | .name')

echo "==> Repositories to mirror:"
echo "$REPOS"

# 1. Clone bare repos and generate individual stagit pages
for REPO in $REPOS; do
    echo "------------------------------------------------"
    echo "==> Processing: $REPO"
    
    # Clone bare copy
    git clone --bare "https://github.com/$USERNAME/$REPO.git" "$REPOS_DIR/$REPO.git"
    
    # Setup stagit site directory for this repo
    mkdir -p "$SITE_DIR/$REPO"
    
    # Run stagit inside the repo target folder
    (
        cd "$SITE_DIR/$REPO"
        stagit "$REPOS_DIR/$REPO.git"
    )
done

# 2. Generate central index page listing all repos
echo "------------------------------------------------"
echo "==> Generating central stagit-index..."
stagit-index "$REPOS_DIR"/*.git > "$SITE_DIR/index.html"

# 3. Copy stagit assets (favicon, logo, css) to the root site directory
FIRST_REPO=$(echo "$REPOS" | head -n 1)
if [ -n "$FIRST_REPO" ]; then
    cp "$SITE_DIR/$FIRST_REPO/favicon.png" "$SITE_DIR/favicon.png" 2>/dev/null || true
    cp "$SITE_DIR/$FIRST_REPO/logo.png" "$SITE_DIR/logo.png" 2>/dev/null || true
    cp "$SITE_DIR/$FIRST_REPO/style.css" "$SITE_DIR/style.css" 2>/dev/null || true
fi

echo "==> Build complete! Output generated in ./site"
