#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

mkdir -p "$repo_root/.git/hooks"
mkdir -p "$repo_root/logs"

cp "$repo_root/hooks/pre-push" "$repo_root/.git/hooks/pre-push"
chmod +x "$repo_root/.git/hooks/pre-push"
chmod +x "$repo_root/hooks/pre-push"
chmod +x "$repo_root/scripts/security_check.sh"

echo "Installed pre-push hook to $repo_root/.git/hooks/pre-push"
echo "Logs will be written to $repo_root/logs"