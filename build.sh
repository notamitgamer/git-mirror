#!/usr/bin/env bash
set -e

USERNAME="notamitgamer"
WORK_DIR="$(pwd)"
REPOS_DIR="$WORK_DIR/raw_repos"
SITE_DIR="$WORK_DIR/site"
ASSETS_DIR="$WORK_DIR/assets"

rm -rf "$REPOS_DIR" "$SITE_DIR"
mkdir -p "$REPOS_DIR" "$SITE_DIR"

echo "==> Fetching public repositories for $USERNAME..."

# 1. Fetch repos along with their GitHub descriptions
REPOS_JSON=$(gh repo list "$USERNAME" --visibility=public --limit 100 --json name,description -q '.[] | select(.name != "git-mirror" and .name != "register" and .name != "osma")')

echo "==> Processing repositories..."

echo "$REPOS_JSON" | jq -c '.' | while read -r repo_info; do
    REPO=$(echo "$repo_info" | jq -r '.name')
    DESC=$(echo "$repo_info" | jq -r '.description // "No description provided."')

    echo "------------------------------------------------"
    echo "==> Processing: $REPO"
    
    # Clone bare repository
    git clone --bare "https://github.com/$USERNAME/$REPO.git" "$REPOS_DIR/$REPO.git"
    
    # Overwrite default Git placeholder files with actual info
    echo "$DESC" > "$REPOS_DIR/$REPO.git/description"
    echo "$USERNAME" > "$REPOS_DIR/$REPO.git/owner"
    
    mkdir -p "$SITE_DIR/$REPO"
    (
        cd "$SITE_DIR/$REPO"
        stagit "$REPOS_DIR/$REPO.git"
        
        # Copy assets into each repo subfolder
        [ -f "$SITE_DIR/style.css" ] && cp "$SITE_DIR/style.css" style.css
        [ -f "$SITE_DIR/logo.png" ] && cp "$SITE_DIR/logo.png" logo.png
        [ -f "$SITE_DIR/favicon.png" ] && cp "$SITE_DIR/favicon.png" favicon.png
    )
done

# 2. Copy root assets
echo "------------------------------------------------"
echo "==> Copying root assets..."
if [ -d "$ASSETS_DIR" ]; then
    for f in style.css favicon.png logo.png; do
        if [ -f "$ASSETS_DIR/$f" ]; then
            cp "$ASSETS_DIR/$f" "$SITE_DIR/$f"
        fi
    done
fi

# 3. Generate central stagit-index
echo "------------------------------------------------"
echo "==> Generating central stagit-index..."
stagit-index "$REPOS_DIR"/*.git > "$SITE_DIR/index.html"

# Copy CNAME if present
if [ -f "$WORK_DIR/CNAME" ]; then
    cp "$WORK_DIR/CNAME" "$SITE_DIR/CNAME"
fi

echo "------------------------------------------------"
echo "==> Injecting mobile viewport meta tags..."
find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    's#<head>#<head>\n\t<meta name="viewport" content="width=device-width, initial-scale=1">#'

echo "==> Build complete! Output generated in ./site"
