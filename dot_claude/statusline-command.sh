#!/bin/bash
# Claude Code status line:
#   project · branch[⊪] | 🤖 model | 💰 N% block (Hh Mm) | 📅 N% week | 🔥 $/hr emoji | 🧠 N%
#
# Cost data comes from `ccusage blocks --json --active` and `ccusage weekly --json`.
# Both are slow (~4s each), so we cache results in /tmp and refresh in the background.
# Costs render as percent of configurable Max-tier budgets. Defaults below
# were back-calibrated from one observed Anthropic /usage data point (ccusage's
# computed retail-rate $$ vs Anthropic's reported %) for a Max 5x account:
#   CLAUDE_BLOCK_BUDGET_USD  (default 57)
#   CLAUDE_WEEK_BUDGET_USD   (default 4500)
# These are heuristics, not Anthropic source-of-truth; recalibrate by comparing
# against `/usage` panel periodically if Anthropic changes pricing.
#
# Invoked by Claude Code with session JSON on stdin.

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // ""')

BLOCK_BUDGET=${CLAUDE_BLOCK_BUDGET_USD:-57}
WEEK_BUDGET=${CLAUDE_WEEK_BUDGET_USD:-4500}
CACHE_TTL=60
CACHE=/tmp/claude-statusline-data-$UID.cache
LOCK=/tmp/claude-statusline-refresh-$UID.lock

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

# ── ccusage data: cached, background-refreshed ──────────────────────────────
refresh_data() {
  local monday block_json
  monday=$(date -v-mon +%Y-%m-%d 2>/dev/null || date -d 'last monday' +%Y-%m-%d 2>/dev/null)
  block_json=$(ccusage blocks --json --active 2>/dev/null)
  local bc br bh bt wc
  bc=$(printf '%s' "$block_json" | jq -r '.blocks[0].costUSD                                // 0')
  br=$(printf '%s' "$block_json" | jq -r '.blocks[0].projection.remainingMinutes            // 0')
  bh=$(printf '%s' "$block_json" | jq -r '.blocks[0].burnRate.costPerHour                   // 0')
  bt=$(printf '%s' "$block_json" | jq -r '.blocks[0].burnRate.tokensPerMinuteForIndicator   // 0')
  wc=$(ccusage weekly --json 2>/dev/null \
    | jq -r --arg w "$monday" '.weekly[] | select(.week == $w) | .totalCost' | head -1)
  [ -z "$wc" ] && wc=0
  printf "block_cost=%s\nblock_remain=%s\nburn_per_hr=%s\nburn_tpmi=%s\nweek_cost=%s\n" \
    "$bc" "$br" "$bh" "$bt" "$wc" > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
}

right=""
if command -v ccusage >/dev/null 2>&1; then
  now=$(date +%s)
  mtime=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
  age=$(( now - mtime ))

  if [ ! -f "$CACHE" ]; then
    # First run: must compute synchronously (one-time ~8s hit).
    refresh_data
  elif [ "$age" -gt "$CACHE_TTL" ] && [ ! -f "$LOCK" ]; then
    # Stale: serve cached value now, refresh in background for next render.
    ( trap 'rm -f "$LOCK"' EXIT; touch "$LOCK"; refresh_data ) >/dev/null 2>&1 &
    disown 2>/dev/null
  fi

  # shellcheck source=/dev/null
  [ -f "$CACHE" ] && source "$CACHE"

  model=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
  used_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')

  block_pct=$(awk -v c="${block_cost:-0}" -v b="$BLOCK_BUDGET" 'BEGIN{printf "%d", (c/b)*100}')
  week_pct=$(awk  -v c="${week_cost:-0}"  -v b="$WEEK_BUDGET"  'BEGIN{printf "%d", (c/b)*100}')
  br=${block_remain:-0}
  h=$(( br / 60 ))
  m=$(( br % 60 ))

  emoji="🟢"
  awk -v v="${burn_tpmi:-0}" 'BEGIN{exit !(v>=2000)}' && emoji="🟡"
  awk -v v="${burn_tpmi:-0}" 'BEGIN{exit !(v>=5000)}' && emoji="🔴"

  burn_fmt=$(awk -v r="${burn_per_hr:-0}" 'BEGIN{printf "$%.1f/hr", r}')

  right_pieces=()
  [ -n "$model" ]    && right_pieces+=("🤖 ${model}")
  right_pieces+=("💰 ${block_pct}% block (${h}h ${m}m)")
  right_pieces+=("📅 ${week_pct}% week")
  right_pieces+=("🔥 ${burn_fmt} ${emoji}")
  [ -n "$used_pct" ] && right_pieces+=("$(printf '🧠 %.0f%%' "$used_pct")")

  for p in "${right_pieces[@]}"; do
    if [ -z "$right" ]; then right="$p"; else right="${right} | ${p}"; fi
  done
fi

# ── Join ─────────────────────────────────────────────────────────────────────
if [ -n "$left" ] && [ -n "$right" ]; then
  printf '%s | %s\n' "$left" "$right"
elif [ -n "$left" ]; then
  printf '%s\n' "$left"
else
  printf '%s\n' "$right"
fi
