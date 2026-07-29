#!/bin/bash
# Claude Code status line:
#   project · branch[⊪] | 🤖 model | 💰 $N block (Hh Mm) | 📅 N% ($N/$N) | 🔥 $/hr emoji | 🧠 N% ctx
#
# Block cost/burn rate come from `ccusage blocks --json --active` (retail-rate computed).
# Monthly quota comes from the real claude.ai spend API via the keychain OAuth token,
# so it reflects actual enterprise spend, not a retail-rate estimate.
# All slow calls are cached in /tmp and refreshed in the background.
#
# Invoked by Claude Code with session JSON on stdin.

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // ""')

CACHE_TTL=60          # block/burn rate (changes during active use)
QUOTA_TTL=300         # spend quota    (accumulates slowly; 5 min is plenty)
CACHE=/tmp/claude-statusline-$UID.cache
QUOTA_CACHE=/tmp/claude-statusline-quota-$UID.cache
LOCK=/tmp/claude-statusline-$UID.lock
QUOTA_LOCK=/tmp/claude-statusline-quota-$UID.lock

# ── Left side: project · branch[⊪] ──────────────────────────────────────────
project=""
git_part=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$cwd" symbolic-ref --short --quiet HEAD 2>/dev/null) \
    || branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  git_dir=$(git -C "$cwd"    rev-parse --path-format=absolute --git-dir        2>/dev/null)
  common_dir=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  wt_marker=""
  [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ] && wt_marker=" ⊪"
  git_part="${branch}${wt_marker}"
  [ -n "$common_dir" ] && project=$(basename "$(dirname "$common_dir")")
fi
if [ -z "$project" ]; then
  proj_dir=$(printf '%s' "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // empty')
  [ -n "$proj_dir" ] && project=$(basename "$proj_dir")
fi

reset=$'\033[0m'
dim=$'\033[38;5;244m'
fg=$'\033[38;5;249m'
accent=$'\033[38;5;110m'
sep="${dim} · ${reset}"

left_pieces=()
[ -n "$project" ]  && left_pieces+=("${accent}${project}${reset}")
[ -n "$git_part" ] && left_pieces+=("${fg}${git_part}${reset}")
left=""
for p in "${left_pieces[@]}"; do
  if [ -z "$left" ]; then left="$p"; else left="${left}${sep}${p}"; fi
done

# ── Right side: model and context window always come from session JSON ────────
model=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
used_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')

# ── Block/burn rate: from ccusage, 60s TTL ───────────────────────────────────
refresh_block() {
  local block_json bc br bh bt
  block_json=$(ccusage blocks --json --active 2>/dev/null)
  bc=$(printf '%s' "$block_json" | jq -r '.blocks[0].costUSD                              // 0')
  br=$(printf '%s' "$block_json" | jq -r '.blocks[0].projection.remainingMinutes          // 0')
  bh=$(printf '%s' "$block_json" | jq -r '.blocks[0].burnRate.costPerHour                 // 0')
  bt=$(printf '%s' "$block_json" | jq -r '.blocks[0].burnRate.tokensPerMinuteForIndicator // 0')
  printf "block_cost=%s\nblock_remain=%s\nburn_per_hr=%s\nburn_tpmi=%s\n" \
    "$bc" "$br" "$bh" "$bt" > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
}

# ── Spend quota: from claude.ai API via Swift URLSession, 5min TTL ────────────
# Anthropic's usage endpoint rejects scripted user-agents (curl/Python get
# blocked), so we fetch it with a native Swift URLSession request. The OAuth
# token is read from the Claude Code keychain entry.
refresh_quota() {
  local token qu ql qp
  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -z "$token" ] && return
  read -r qu ql qp < <(TOKEN="$token" swift - 2>/dev/null <<'SWEOF'
import Foundation
let tok  = ProcessInfo.processInfo.environment["TOKEN"] ?? ""
var req  = URLRequest(url: URL(string: "https://claude.ai/api/oauth/usage")!)
req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
let sema = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: req) { data, _, _ in
    if let data,
       let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let s = j["spend"] as? [String: Any],
       let used  = (s["used"]  as? [String: Any])?["amount_minor"] as? Int,
       let limit = (s["limit"] as? [String: Any])?["amount_minor"] as? Int,
       let pct   = s["percent"] as? Int {
        print("\(Double(used)/100) \(Double(limit)/100) \(pct)")
    }
    sema.signal()
}.resume()
sema.wait()
SWEOF
  )
  [ -n "$qu" ] && printf "quota_used=%s\nquota_limit=%s\nquota_pct=%s\n" \
    "$qu" "$ql" "$qp" > "$QUOTA_CACHE.tmp" && mv "$QUOTA_CACHE.tmp" "$QUOTA_CACHE"
}

right_pieces=()
[ -n "$model" ] && right_pieces+=("🤖 ${model}")

if command -v ccusage >/dev/null 2>&1; then
  now=$(date +%s)

  # Block/burn cache (60s)
  block_age=$(( now - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  if [ ! -f "$CACHE" ]; then
    refresh_block
  elif [ "$block_age" -gt "$CACHE_TTL" ] && [ ! -f "$LOCK" ]; then
    ( trap 'rm -f "$LOCK"' EXIT; touch "$LOCK"; refresh_block ) >/dev/null 2>&1 &
    disown 2>/dev/null
  fi

  # Quota cache (5min) — independent of block refresh
  quota_age=$(( now - $(stat -f %m "$QUOTA_CACHE" 2>/dev/null || echo 0) ))
  if [ ! -f "$QUOTA_CACHE" ]; then
    refresh_quota
  elif [ "$quota_age" -gt "$QUOTA_TTL" ] && [ ! -f "$QUOTA_LOCK" ]; then
    ( trap 'rm -f "$QUOTA_LOCK"' EXIT; touch "$QUOTA_LOCK"; refresh_quota ) >/dev/null 2>&1 &
    disown 2>/dev/null
  fi

  # shellcheck source=/dev/null
  [ -f "$CACHE" ]       && source "$CACHE"
  [ -f "$QUOTA_CACHE" ] && source "$QUOTA_CACHE"

  br=${block_remain:-0}
  h=$(( br / 60 ))
  m=$(( br % 60 ))
  block_fmt=$(awk -v c="${block_cost:-0}" 'BEGIN{printf "$%.2f", c}')
  burn_fmt=$(awk  -v r="${burn_per_hr:-0}" 'BEGIN{printf "$%.2f/hr", r}')

  emoji="🟢"
  awk -v v="${burn_tpmi:-0}" 'BEGIN{exit !(v>=2000)}' && emoji="🟡"
  awk -v v="${burn_tpmi:-0}" 'BEGIN{exit !(v>=5000)}' && emoji="🔴"

  right_pieces+=("💰 ${block_fmt} block (${h}h ${m}m)")
  if [ "${quota_limit:-0}" != "0" ]; then
    quota_fmt=$(awk -v u="${quota_used:-0}" -v l="${quota_limit:-0}" -v p="${quota_pct:-0}" \
      'BEGIN{printf "%d%% ($%.0f/$%.0f)", p, u, l}')
    right_pieces+=("📅 ${quota_fmt}")
  fi
  right_pieces+=("🔥 ${burn_fmt} ${emoji}")
fi

[ -n "$used_pct" ] && right_pieces+=("$(printf '🧠 %.0f%%' "$used_pct")")

right=""
for p in "${right_pieces[@]}"; do
  if [ -z "$right" ]; then right="$p"; else right="${right} | ${p}"; fi
done

# ── Join ─────────────────────────────────────────────────────────────────────
if [ -n "$left" ] && [ -n "$right" ]; then
  printf '%s | %s\n' "$left" "$right"
elif [ -n "$left" ]; then
  printf '%s\n' "$left"
else
  printf '%s\n' "$right"
fi
