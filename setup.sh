#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null || true)"

if [[ -z "$hooks_dir" ]]; then
	hooks_dir="$repo_root/.git/hooks"
fi

case "$hooks_dir" in
	/*) ;;
	*) hooks_dir="$repo_root/$hooks_dir" ;;
esac

mkdir -p "$hooks_dir"
mkdir -p "$repo_root/logs"

cp "$repo_root/hooks/pre-push" "$hooks_dir/pre-push"
chmod +x "$hooks_dir/pre-push"
chmod +x "$repo_root/hooks/pre-push"
chmod +x "$repo_root/scripts/security_check.sh"

echo "Installed pre-push hook to $hooks_dir/pre-push"
echo "Primary engine: scripts/security_check.ps1 (when pwsh / pwsh.exe is available)"
echo "Fallback engine: scripts/security_check.sh"
echo "Logs will be written to $repo_root/logs"