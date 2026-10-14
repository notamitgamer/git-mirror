#!/usr/bin/env bash
set -e

export GITHUB_USER="notamitgamer"
export BASE_DIR="$PWD"
export REPOS_DIR="$BASE_DIR/repos"
export PUBLIC_DIR="$BASE_DIR/public"

mkdir -p "$REPOS_DIR" "$PUBLIC_DIR"

sync_and_build() {
  repo="$1"
  [ -z "$repo" ] && exit 0
  TARGET="$REPOS_DIR/${repo}.git"
  WEB_TARGET="$PUBLIC_DIR/$repo"

  if [ ! -d "$TARGET" ]; then
    git clone --depth 50 --bare "https://github.com/${GITHUB_USER}/${repo}.git" "$TARGET" 2>/dev/null || exit 0
  else
    git -C "$TARGET" fetch --depth 50 origin 2>/dev/null || true
  fi

  mkdir -p "$WEB_TARGET"
  cd "$WEB_TARGET" || exit 0

  # Standard stagit on shallow 50-commit mirror runs in < 0.5s per repo
  stagit "$TARGET" 2>/dev/null || true

  [ -f "files.html" ] && cp -f files.html index.html
  [ -f "$BASE_DIR/assets/style.css" ] && cp -f "$BASE_DIR/assets/style.css" "$WEB_TARGET/style.css"
}

export -f sync_and_build

echo "[*] Fetching public repository list for ${GITHUB_USER}..."
REPO_LIST=$(curl -s "https://api.github.com/users/${GITHUB_USER}/repos?type=public&per_page=100" | jq -r '.[].name')

echo "[*] Processing repositories in parallel (4 concurrent jobs)..."
# Correct parallel xargs syntax without -I collision
echo "$REPO_LIST" | xargs -P 4 -n 1 bash -c 'sync_and_build "$1"' _

# Master index generation
cd "$PUBLIC_DIR" || exit 1
stagit-index "$REPOS_DIR"/*.git > index.html
sed -i 's/\/log\.html/\/files\.html/g' index.html 2>/dev/null || true
[ -f "$BASE_DIR/assets/style.css" ] && cp -f "$BASE_DIR/assets/style.css" "$PUBLIC_DIR/style.css"

echo "[+] Stagit build completed successfully."
