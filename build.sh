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

REPOS=$(gh repo list "$USERNAME" --public --limit 100 --json name -q '.[] | select(.name != "git-mirror" and .name != "register") | .name')

echo "==> Repositories to mirror:"
echo "$REPOS"

for REPO in $REPOS; do
    echo "------------------------------------------------"
    echo "==> Processing: $REPO"

    git clone --bare "https://github.com/$USERNAME/$REPO.git" "$REPOS_DIR/$REPO.git"

    mkdir -p "$SITE_DIR/$REPO"

    (
        cd "$SITE_DIR/$REPO"
        stagit "$REPOS_DIR/$REPO.git"
    )
done

echo "------------------------------------------------"
echo "==> Generating central stagit-index..."
stagit-index "$REPOS_DIR"/*.git > "$SITE_DIR/index.html"

echo "------------------------------------------------"
echo "==> Copying assets..."
if [ -d "$ASSETS_DIR" ]; then
    for f in style.css favicon.png logo.png; do
        if [ -f "$ASSETS_DIR/$f" ]; then
            cp "$ASSETS_DIR/$f" "$SITE_DIR/$f"
            for REPO in $REPOS; do
                cp "$ASSETS_DIR/$f" "$SITE_DIR/$REPO/$f"
            done
        else
            echo "WARNING: $ASSETS_DIR/$f not found, skipping"
        fi
    done
else
    echo "WARNING: $ASSETS_DIR not found — no CSS/assets will be applied"
fi

echo "------------------------------------------------"
echo "==> Injecting mobile viewport meta tags..."
find "$SITE_DIR" -name "*.html" -print0 | xargs -0 sed -i \
    's#<head>#<head>\n\t<meta name="viewport" content="width=device-width, initial-scale=1">#'

echo "==> Build complete! Output generated in ./site"