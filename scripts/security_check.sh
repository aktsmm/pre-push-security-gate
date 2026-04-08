#!/usr/bin/env bash
set -euo pipefail

remote_name="${1:-unknown-remote}"
remote_url="${2:-unknown-url}"
refs_file="${3:-}"

if [[ -z "$refs_file" || ! -f "$refs_file" ]]; then
  echo "[security-hook] refs file is missing." >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

ZERO_SHA="0000000000000000000000000000000000000000"
MAX_PROMPT_CHARS="${SECURITY_HOOK_MAX_PROMPT_CHARS:-28000}"
FAIL_OPEN="${SECURITY_HOOK_FAIL_OPEN:-0}"
mkdir -p "$repo_root/logs"
timestamp="$(date +"%Y%m%d-%H%M%S")"
log_file="$repo_root/logs/security-$timestamp.log"
COPILOT_COMMAND=""
COPILOT_KIND=""
COPILOT_ADD_DIR="$repo_root"

log() {
  printf '%s\n' "$1" >> "$log_file"
}

warn_or_fail() {
  local message="$1"
  if [[ "$FAIL_OPEN" == "1" ]]; then
    echo "[security-hook] $message" >&2
    echo "[security-hook] SECURITY_HOOK_FAIL_OPEN=1 のため push を継続します。" >&2
    log "Result: PASS (fail-open)"
    log "Reason: $message"
    exit 0
  fi

  echo "[security-hook] $message" >&2
  log "Result: FAIL"
  log "Reason: $message"
  exit 1
}

should_check_ref() {
  local local_ref="$1"

  if [[ "$local_ref" != refs/heads/* ]]; then
    return 1
  fi

  # Default: check every branch.
  # To limit checks to production branches only, replace this function body with:
  # case "$local_ref" in
  #   refs/heads/main|refs/heads/master) return 0 ;;
  #   *) return 1 ;;
  # esac
  return 0
}

collect_commits() {
  local remote_sha="$1"
  local local_sha="$2"
  local commits=()

  if [[ "$remote_sha" != "$ZERO_SHA" ]]; then
    while IFS= read -r commit; do
      [[ -n "$commit" ]] && commits+=("$commit")
    done < <(git rev-list --reverse "$remote_sha..$local_sha")
  else
    while IFS= read -r commit; do
      [[ -n "$commit" ]] && commits+=("$commit")
    done < <(git rev-list --reverse "$local_sha" --not --remotes)

    if [[ "${#commits[@]}" -eq 0 ]]; then
      while IFS= read -r commit; do
        [[ -n "$commit" ]] && commits+=("$commit")
      done < <(git rev-list --reverse --max-count=5 "$local_sha")
    fi
  fi

  printf '%s\n' "${commits[@]}"
}

build_patch_payload() {
  local commit
  local payload=""

  while IFS= read -r commit; do
    [[ -z "$commit" ]] && continue
    local block
    block="$(git show --stat --patch --find-renames --format=medium "$commit")"

    if (( ${#payload} + ${#block} > MAX_PROMPT_CHARS )); then
      payload+=$'\n[TRUNCATED] Prompt length limit reached.\n'
      break
    fi

    payload+="$block"
    payload+=$'\n\n'
  done < <(printf '%s\n' "$1")

  printf '%s' "$payload"
}

collect_changed_files() {
  local commits_input="$1"
  local file

  while IFS= read -r file; do
    [[ -n "$file" ]] && printf '%s\n' "$file"
  done < <(
    while IFS= read -r commit; do
      [[ -z "$commit" ]] && continue
      git show --format= --name-only "$commit"
    done < <(printf '%s\n' "$commits_input") | sort -u
  )
}

build_static_signals() {
  local files_input="$1"
  local findings=""
  local file
  local snippet
  local secret_pattern="(api[_-]?key|secret|token|password)[[:space:]]*[:=][[:space:]]*['\"][^'\"]{8,}['\"]"
  local command_pattern='os\.system\(|subprocess\.(Popen|run)\(|child_process\.exec\(|eval\('
  local xss_pattern='res\.send\(.*req\.(query|body)|innerHTML\s*=.*(req\.|location\.)'
  local ssrf_pattern='fetch\(req\.(query|body)|axios\.(get|post)\(req\.(query|body)|requests\.(get|post)\(request\.(args|form)'

  while IFS= read -r file; do
    [[ -z "$file" || ! -f "$file" ]] && continue

    snippet="$(grep -nE "$secret_pattern" "$file" || true)"
    if [[ -n "$snippet" ]]; then
      findings+="- hardcoded secret candidate in $file\n$snippet\n"
    fi

    snippet="$(grep -nE "$command_pattern" "$file" || true)"
    if [[ -n "$snippet" ]]; then
      findings+="- dangerous command execution candidate in $file\n$snippet\n"
    fi

    snippet="$(grep -nE "$xss_pattern" "$file" || true)"
    if [[ -n "$snippet" ]]; then
      findings+="- XSS candidate in $file\n$snippet\n"
    fi

    snippet="$(grep -nE "$ssrf_pattern" "$file" || true)"
    if [[ -n "$snippet" ]]; then
      findings+="- SSRF candidate in $file\n$snippet\n"
    fi
  done < <(printf '%s\n' "$files_input")

  if [[ -z "$findings" ]]; then
    findings="- No high-signal regex matches found before the Copilot review."
  fi

  printf '%b' "$findings"
}

if command -v copilot >/dev/null 2>&1; then
  COPILOT_COMMAND="$(command -v copilot)"
  COPILOT_KIND="standalone"
elif command -v copilot.exe >/dev/null 2>&1; then
  COPILOT_COMMAND="$(command -v copilot.exe)"
  COPILOT_KIND="standalone"
elif command -v gh >/dev/null 2>&1; then
  COPILOT_COMMAND="$(command -v gh)"
  COPILOT_KIND="gh-wrapper"
elif command -v gh.exe >/dev/null 2>&1; then
  COPILOT_COMMAND="$(command -v gh.exe)"
  COPILOT_KIND="gh-wrapper"
else
  log "Date: $(date '+%Y-%m-%d %H:%M:%S')"
  log "Remote: $remote_name ($remote_url)"
  warn_or_fail "Copilot CLI が見つかりません。standalone の 'copilot' コマンドをインストールしてください。"
fi

if [[ "$COPILOT_KIND" == "standalone" && "$COPILOT_COMMAND" == *.exe ]]; then
  if command -v wslpath >/dev/null 2>&1; then
    COPILOT_ADD_DIR="$(wslpath -w "$repo_root")"
  elif command -v cygpath >/dev/null 2>&1; then
    COPILOT_ADD_DIR="$(cygpath -w "$repo_root")"
  fi
fi

refs_summary=""
commits_payload=""
changed_files=""
review_required=0

while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
  [[ -z "${local_ref:-}" ]] && continue
  [[ "$local_ref" == "(delete)" ]] && continue
  should_check_ref "$local_ref" || continue

  review_required=1
  refs_summary+="- $local_ref ($local_sha) -> $remote_ref ($remote_sha)\n"

  commits_for_ref="$(collect_commits "$remote_sha" "$local_sha")"
  [[ -z "$commits_for_ref" ]] && continue

  payload_for_ref="$(build_patch_payload "$commits_for_ref")"
  if [[ -n "$payload_for_ref" ]]; then
    commits_payload+="### Ref: $local_ref -> $remote_ref\n$payload_for_ref\n"
  fi

  files_for_ref="$(collect_changed_files "$commits_for_ref")"
  if [[ -n "$files_for_ref" ]]; then
    changed_files+="$files_for_ref"
    changed_files+=$'\n'
  fi
done < "$refs_file"

if [[ "$review_required" -eq 0 ]]; then
  exit 0
fi

if [[ -z "$commits_payload" ]]; then
  log "Date: $(date '+%Y-%m-%d %H:%M:%S')"
  log "Remote: $remote_name ($remote_url)"
  log "Refs:"
  log "$(printf '%b' "$refs_summary")"
  log "Result: PASS"
  log "Reason: no commits detected for the selected refs."
  exit 0
fi

changed_files="$(printf '%s\n' "$changed_files" | sort -u | sed '/^$/d')"
static_signals="$(build_static_signals "$changed_files")"

prompt=$(cat <<EOF
You are performing a strict pre-push security review for changed code.

Context:
- Repository: $(basename "$repo_root")
- Remote: $remote_name
- Review date: $(date '+%Y-%m-%d')
- Goal: block pushes that introduce representative security risks.

Review these categories at minimum:
1. SQL injection
2. Command injection / unsafe shell execution
3. XSS or unsafe HTML rendering
4. SSRF or arbitrary outbound requests
5. Hardcoded secrets or credentials
6. Broken authentication or authorization
7. Unsafe deserialization / eval-like execution
8. Sensitive information leakage or insecure defaults

Respond in Japanese.
Do not use tools. Review only the patch data provided in this prompt.
If the patch is acceptable, include exactly one line containing: SECURITY_CHECK: PASS
If the patch is not acceptable, include exactly one line containing: SECURITY_CHECK: FAIL

Output format:
SECURITY_CHECK: PASS or FAIL
Summary: one short sentence
Findings:
- [severity] file[:line] - issue - why it matters - suggested fix

If there are no findings, write exactly:
Findings:
- none

Refs being pushed:
$(printf '%b' "$refs_summary")

Changed files:
${changed_files:-none}

Static pre-scan signals:
$static_signals

Patch data:
$commits_payload
EOF
)

log "=== Security Check Log ==="
log "Date: $(date '+%Y-%m-%d %H:%M:%S')"
log "Remote: $remote_name ($remote_url)"
log "Refs:"
log "$(printf '%b' "$refs_summary")"
log "Changed files:"
log "${changed_files:-none}"
log "Prompt max chars: $MAX_PROMPT_CHARS"
if [[ "$COPILOT_KIND" == "standalone" ]]; then
  log "Copilot CLI command: $COPILOT_COMMAND -p <prompt> --silent --no-ask-user --add-dir $COPILOT_ADD_DIR"
else
  log "Copilot CLI command: $COPILOT_COMMAND copilot -- -p <prompt>"
fi

copilot_output=""
copilot_status=0
if [[ "$COPILOT_KIND" == "standalone" ]]; then
  if ! copilot_output="$($COPILOT_COMMAND -p "$prompt" --silent --no-ask-user --add-dir "$COPILOT_ADD_DIR" 2>&1)"; then
    copilot_status=$?
  fi
else
  if ! copilot_output="$($COPILOT_COMMAND copilot -- -p "$prompt" 2>&1)"; then
    copilot_status=$?
  fi
fi

log "--- Copilot Output ---"
log "$copilot_output"
log "========================"

if [[ "$copilot_status" -ne 0 ]]; then
  warn_or_fail "Copilot CLI の実行に失敗しました。ログを確認してください: $log_file"
fi

if grep -q 'SECURITY_CHECK: PASS' <<< "$copilot_output"; then
  echo "[security-hook] PASS: security review passed." >&2
  log "Result: PASS"
  exit 0
fi

if grep -q 'SECURITY_CHECK: FAIL' <<< "$copilot_output"; then
  echo "[security-hook] FAIL: push blocked by security review." >&2
  echo "$copilot_output" >&2
  log "Result: FAIL"
  exit 1
fi

warn_or_fail "Copilot の応答を判定できませんでした。ログを確認してください: $log_file"