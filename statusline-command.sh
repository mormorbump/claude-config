#!/usr/bin/env bash
# Claude Code Status Line Script
# Displays: cwd | git info | context usage | model

input=$(cat)

# --- Extract data from JSON ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model_id=$(echo "$input" | jq -r '.model.id // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# --- Line 1: Current directory (replace $HOME with ~) ---
display_cwd="${cwd/#$HOME/~}"

# --- Line 2: Git info ---
git_line=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
    repo_name=$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)")
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Count staged/unstaged changes
    added=0
    modified=0
    git_status=$(git -C "$cwd" status --porcelain 2>/dev/null)
    if [ -n "$git_status" ]; then
        added=$(echo "$git_status" | grep -c '^[ADRCU?]' || true)
        modified=$(echo "$git_status" | grep -c '^.[MD]' || true)
        # Also count untracked
        untracked=$(echo "$git_status" | grep -c '^??' || true)
        added=$((added + untracked))
    fi

    diff_str=""
    if [ "$added" -gt 0 ] && [ "$modified" -gt 0 ]; then
        diff_str=" +${added} ~${modified}"
    elif [ "$added" -gt 0 ]; then
        diff_str=" +${added}"
    elif [ "$modified" -gt 0 ]; then
        diff_str=" ~${modified}"
    fi

    git_line="🐙 ${repo_name} │ 🌿 ${branch}${diff_str}"
fi

# --- Line 3: Context bar + model ---
context_line=""
if [ -n "$used_pct" ]; then
    # Build a 15-block progress bar
    pct_int=$(printf "%.0f" "$used_pct")
    filled=$(( pct_int * 15 / 100 ))
    empty=$(( 15 - filled ))
    bar=""
    for i in $(seq 1 $filled); do bar="${bar}█"; done
    for i in $(seq 1 $empty);  do bar="${bar}░"; done
    context_line="🧠 ${bar} ${pct_int}% │ 💪 ${model_id}"
else
    context_line="🧠 ░░░░░░░░░░░░░░░ --% │ 💪 ${model_id}"
fi

# --- Output ---
printf "📂 %s\n" "$display_cwd"
[ -n "$git_line" ] && printf "%s\n" "$git_line"
printf "%s\n" "$context_line"
