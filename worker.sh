#!/usr/bin/env bash

repo="$1"
desc="$2"
[ -z "$repo" ] && exit 0

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/echo

BASE_DIR="$PWD"
REPOS_DIR="$BASE_DIR/repos"
PUBLIC_DIR="$BASE_DIR/public"
TARGET="$REPOS_DIR/${repo}.git"
WEB_TARGET="$PUBLIC_DIR/$repo"

mkdir -p "$REPOS_DIR" "$PUBLIC_DIR" "$WEB_TARGET"

# 1. Clone or fetch with timeout
if [ ! -d "$TARGET" ]; then
  timeout 25s git clone --depth 50 --bare "https://github.com/notamitgamer/${repo}.git" "$TARGET" 2>/dev/null || exit 0
else
  timeout 20s git -C "$TARGET" fetch --depth 50 origin 2>/dev/null || true
fi

# 2. Write metadata for stagit and stagit-index
if [ -n "$desc" ] && [ "$desc" != "null" ]; then
  echo "$desc" > "$TARGET/description"
else
  echo "Mirror of https://github.com/notamitgamer/${repo}" > "$TARGET/description"
fi

echo "notamitgamer" > "$TARGET/owner"
echo "https://git.amit.is-a.dev/$repo" > "$TARGET/url"

# 3. Generate stagit pages
cd "$WEB_TARGET" || exit 0
stagit "$TARGET" 2>/dev/null || true

# 4. Set files.html as landing page and copy style
[ -f "files.html" ] && cp -f files.html index.html
[ -f "$BASE_DIR/assets/style.css" ] && cp -f "$BASE_DIR/assets/style.css" "$WEB_TARGET/style.css"

echo "[✓] Built: $repo"
