#!/usr/bin/env bash
# Agnoster-style statusLine for Claude Code
# Reads JSON from stdin, outputs a colored prompt-style status line

input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
ctx_remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# Shorten home directory to ~
home="$HOME"
short_cwd="${cwd/#$home/~}"

# ANSI color codes
RESET='\033[0m'
BOLD='\033[1m'

# Segment colors (agnoster-style)
BLUE_BG='\033[44m'
GREEN_BG='\033[42m'
YELLOW_BG='\033[43m'
CYAN_BG='\033[46m'
BLACK_FG='\033[30m'
WHITE_FG='\033[97m'

# Git info
git_branch=""
git_dirty=""
if [ -n "$cwd" ]; then
  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  if [ -n "$git_branch" ]; then
    git_status=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
    if [ -n "$git_status" ]; then
      git_dirty=" ✚"
    fi
  fi
fi

# Build status line
output=""

# Directory segment (blue background)
output="${output}$(printf "${BLUE_BG}${BLACK_FG}${BOLD} %s ${RESET}" "$short_cwd")"

# Git segment
if [ -n "$git_branch" ]; then
  if [ -n "$git_dirty" ]; then
    output="${output}$(printf "${YELLOW_BG}${BLACK_FG}${BOLD} ± %s%s ${RESET}" "$git_branch" "$git_dirty")"
  else
    output="${output}$(printf "${GREEN_BG}${BLACK_FG}${BOLD} ± %s ${RESET}" "$git_branch")"
  fi
fi

# Model segment (cyan background)
if [ -n "$model" ]; then
  output="${output}$(printf "${CYAN_BG}${BLACK_FG} %s ${RESET}" "$model")"
fi

# Context remaining
if [ -n "$ctx_remaining" ]; then
  ctx_int=$(printf "%.0f" "$ctx_remaining")
  output="${output}$(printf "${WHITE_FG} ctx:%s%% ${RESET}" "$ctx_int")"
fi

printf "%s" "$output"
