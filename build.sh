#!/usr/bin/env bash
set -e

export BASE_DIR="$PWD"
export REPOS_DIR="$BASE_DIR/repos"
export PUBLIC_DIR="$BASE_DIR/public"

mkdir -p "$REPOS_DIR" "$PUBLIC_DIR"

echo "[*] Fetching public repository list and descriptions from GitHub..."
# Extract repo name and description separated by a tab
curl -s "https://api.github.com/users/notamitgamer/repos?type=public&per_page=100" | \
  jq -r '.[] | [.name, (.description // "No description provided")] | @tsv' > /tmp/repos_meta.tsv

echo "[*] Processing repositories concurrently..."
while IFS=$'\t' read -r repo desc; do
  echo "$repo" "$desc"
done < /tmp/repos_meta.tsv | xargs -P 4 -n 2 ./worker.sh

echo "[*] Generating master index..."
cd "$PUBLIC_DIR" || exit 1
stagit-index "$REPOS_DIR"/*.git > index.html
sed -i 's/\/log\.html/\/files\.html/g' index.html 2>/dev/null || true
[ -f "$BASE_DIR/assets/style.css" ] && cp -f "$BASE_DIR/assets/style.css" "$PUBLIC_DIR/style.css"

echo "[+] Done."
