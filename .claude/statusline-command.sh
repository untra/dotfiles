#!/bin/sh
#
# statusline-command.sh — Claude Code status line for github.com/untra/dotfiles
#
# Renders two lines from the JSON payload Claude Code writes to stdin:
#
#   cwd: ~/Documents/untra/dotfiles | ⎇ main | (+42,-10)        Session: my-session
#   Model: Opus 5 | v2.1.100 | Ctx Used: 9.3%   In: 15.2k Out: 3.4k | Total: 30.6k | Cost: $2.45
#
# WHY THIS IS NOT ccstatusline
#
# This layout began as a ccstatusline config. Shipping ccstatusline itself would mean
# either a Node runtime in every Coder workspace, or vendoring a bun-compiled binary —
# measured at 63.6 MB (darwin-arm64) to 97.8 MB (linux-x64), the latter 2 MB under
# GitHub's hard 100 MB file limit, re-added in full on every version bump because
# binaries do not delta-compress. That is a lot of machinery for nine fields.
#
# It turns out not to be needed. Claude Code already puts the token and context numbers
# in the payload (.context_window), and everything else is one git call or one jq pass
# over the session transcript — benchmarked at 0.11s against a 10.3 MB / 4555-line
# transcript, the largest on this machine. So: jq + git, which this repo already
# requires, and nothing else.
#
# FIDELITY TO ccstatusline
#
# Deliberately mirrored so the output matches what ccstatusline rendered:
#   - In:/Out: prefer .context_window.total_{input,output}_tokens, falling back to the
#     transcript. Total: has no .context_window source upstream and is ALWAYS the
#     transcript sum including cache, which is why Total dwarfs In+Out.
#   - The transcript sum keeps only entries with a truthy stop_reason (plus a trailing
#     null one), or every entry if no entry carries the field at all. Without that,
#     streamed partials are counted several times over.
#   - Context length comes from the most recent non-sidechain, non-error entry.
#   - Context window falls back to 200000 (upstream DEFAULT_CONTEXT_WINDOW_SIZE).
#
# DEGRADATION
#
# Every segment is optional and every dependency is probed. No jq, no git, not a repo,
# no transcript, unknown terminal width — each drops its own segments and the rest still
# renders. This runs on every refresh; it must never error and never block.
#
# POSIX sh — Coder images may ship dash or busybox ash. No bashisms, no `local`,
# no `readlink -f`, no process substitution.

# No `set -e`: a failed probe is normal control flow here, not a fatal error.
set -u

CTX_DEFAULT=200000

# 256-color codes chosen to match the ccstatusline palette this replaces.
C_RESET=$(printf '\033[0m')
C_DIR=$(printf '\033[38;5;26m')
C_BRANCH=$(printf '\033[38;5;96m')
C_DIFF=$(printf '\033[38;5;178m')
C_SESSION=$(printf '\033[38;5;37m')
C_MODEL=$(printf '\033[38;5;30m')
C_CTX=$(printf '\033[38;5;26m')
C_IN=$(printf '\033[38;5;26m')
C_OUT=$(printf '\033[38;5;188m')
C_TOTAL=$(printf '\033[38;5;30m')
C_COST=$(printf '\033[38;5;70m')

SEP=' | '

input=$(cat)

#--- degraded path: no jq -----------------------------------------------------
# Nothing here can parse JSON properly, so pull the two most useful strings out
# with sed and stop. Better than a blank status line.
if ! command -v jq >/dev/null 2>&1; then
	_d=$(printf '%s' "$input" |
		sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
	_m=$(printf '%s' "$input" |
		sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
	[ -n "$_d" ] && printf '%scwd: %s%s' "$C_DIR" "$_d" "$C_RESET"
	[ -n "$_d" ] && [ -n "$_m" ] && printf '%s' "$SEP"
	[ -n "$_m" ] && printf '%sModel: %s%s' "$C_MODEL" "$_m" "$C_RESET"
	printf '\n'
	exit 0
fi

#--- payload ------------------------------------------------------------------
# One jq pass, newline-delimited in a fixed order. A dozen separate jq calls is
# what made the previous version of this script slow.
#
# `// ""` guards absent keys; note jq treats 0 as truthy, so a zero cost or zero
# token count survives rather than collapsing to "".

_fields=$(printf '%s' "$input" | jq -r '
  def s: if . == null then "" else tostring end;
  [ (.workspace.current_dir // .cwd // ""),
    (.model.display_name // ""),
    (.model.id // ""),
    (.version // ""),
    (.transcript_path // ""),
    (.cost.total_cost_usd | s),
    (.context_window.context_window_size | s),
    (.context_window.total_input_tokens | s),
    (.context_window.total_output_tokens | s),
    ( .context_window.current_usage
      | if type == "number" then .
        elif type == "object" then
          ((.input_tokens // 0)
           + (.cache_creation_input_tokens // 0)
           + (.cache_read_input_tokens // 0))
        else null end
      | s )
  ] | .[]
' 2>/dev/null)

# A malformed payload leaves every field empty; emit nothing rather than a row of
# bare labels.
[ -n "$_fields" ] || exit 0

cwd=''; model=''; model_id=''; version=''; transcript=''; cost=''
cw_size=''; cw_in=''; cw_out=''; cw_ctxlen=''

_i=0
while IFS= read -r _line; do
	_i=$((_i + 1))
	case $_i in
	1) cwd=$_line ;;
	2) model=$_line ;;
	3) model_id=$_line ;;
	4) version=$_line ;;
	5) transcript=$_line ;;
	6) cost=$_line ;;
	7) cw_size=$_line ;;
	8) cw_in=$_line ;;
	9) cw_out=$_line ;;
	10) cw_ctxlen=$_line ;;
	esac
done <<EOF
$_fields
EOF

#--- helpers ------------------------------------------------------------------

# 1234567 -> 1.2M, 15200 -> 15.2k, 42 -> 42. Mirrors upstream formatTokens().
fmt_tokens() {
	awk -v n="$1" 'BEGIN {
		if (n >= 1000000)   printf "%.1fM", n / 1000000
		else if (n >= 1000) printf "%.1fk", n / 1000
		else                printf "%d", n
	}'
}

is_num() {
	case ${1:-} in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

# Display width of a plain (escape-free) string.
#
# NOT `${#s}`: bash counts characters, but dash and busybox ash count BYTES, and
# the branch glyph ⎇ is three bytes of UTF-8. Padding computed with ${#s} lands
# two columns short on exactly the shells this repo targets. Counting bytes and
# subtracting UTF-8 continuation bytes (0x80-0xBF) is correct in every shell.
plainlen() {
	printf '%s' "${1:-}" |
		LC_ALL=C awk '{ n += length($0) - gsub(/[\200-\277]/, "") } END { print n + 0 }'
}

#--- transcript metrics -------------------------------------------------------
# Needed for Total: unconditionally (upstream has no .context_window path for it),
# and as the fallback for In:/Out:/context length. The session name is folded into
# the same pass — the transcript reaches 10 MB, and reading it twice doubles the
# cost of every refresh for one extra string.

tm_in=''; tm_out=''; tm_total=''; tm_ctxlen=''; session=''

if [ -n "$transcript" ] && [ -r "$transcript" ]; then
	_tm=$(jq -sr '
	  [ .[] | select(.message.usage) ] as $e
	  | (any($e[]; .message | has("stop_reason"))) as $hs
	  | ( if $hs then
	        [ $e[] | select(.message.stop_reason != null) ]
	      else $e end ) as $c
	  | ( [$c[].message.usage.input_tokens  // 0] | add // 0 ) as $in
	  | ( [$c[].message.usage.output_tokens // 0] | add // 0 ) as $out
	  | ( [ $c[].message.usage
	        | (.cache_read_input_tokens // 0)
	          + (.cache_creation_input_tokens // 0) ] | add // 0 ) as $cache
	  | ( [ $e[] | select(.isSidechain != true and .timestamp
	                      and (.isApiErrorMessage | not)) ]
	      | sort_by(.timestamp) | last | .message.usage
	      | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
	         + (.cache_creation_input_tokens // 0)) ) as $ctx
	  | ( [ .[] | select(.type == "custom-title" and (.customTitle // "") != "") ]
	      | last | .customTitle // "" ) as $title
	  | "\($in)\n\($out)\n\($in + $out + $cache)\n\($ctx // 0)\n\($title)"
	' "$transcript" 2>/dev/null)

	if [ -n "$_tm" ]; then
		_i=0
		while IFS= read -r _line; do
			_i=$((_i + 1))
			case $_i in
			1) tm_in=$_line ;;
			2) tm_out=$_line ;;
			3) tm_total=$_line ;;
			4) tm_ctxlen=$_line ;;
			5) session=$_line ;;
			esac
		done <<EOF
$_tm
EOF
	fi
fi

# Payload wins for In:/Out:; transcript is the fallback. Total: is transcript-only.
tok_in=$cw_in
is_num "$tok_in" || tok_in=$tm_in
tok_out=$cw_out
is_num "$tok_out" || tok_out=$tm_out
tok_total=$tm_total

ctx_len=$cw_ctxlen
is_num "$ctx_len" || ctx_len=$tm_ctxlen

# Window size: payload, else a 1m/200k marker in the model identifier, else 200000.
ctx_size=$cw_size
if ! is_num "$ctx_size" || [ "${ctx_size:-0}" -le 0 ]; then
	ctx_size=$(awk -v id="$model_id $model" 'BEGIN {
		s = tolower(id)
		if (match(s, /[0-9]+(\.[0-9]+)?[km]/)) {
			t = substr(s, RSTART, RLENGTH)
			u = substr(t, length(t))
			v = substr(t, 1, length(t) - 1) + 0
			if (v > 0) { printf "%d", (u == "m" ? v * 1000000 : v * 1000); exit }
		}
		printf ""
	}')
fi
is_num "$ctx_size" && [ "$ctx_size" -gt 0 ] || ctx_size=$CTX_DEFAULT

#--- git ----------------------------------------------------------------------
# --no-optional-locks so a refresh never contends for .git/index.lock while a
# command is mid-write.

branch=''
changes=''
if [ -n "$cwd" ] && [ -d "$cwd" ] && command -v git >/dev/null 2>&1; then
	if [ "$(git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
		branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null) ||
			branch=''
		# Detached HEAD still deserves a label.
		[ -n "$branch" ] ||
			branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null) ||
			branch=''

		_unstaged=$(git -C "$cwd" --no-optional-locks diff --shortstat 2>/dev/null)
		_staged=$(git -C "$cwd" --no-optional-locks diff --cached --shortstat 2>/dev/null)
		changes=$(awk -v a="$_unstaged" -v b="$_staged" 'BEGIN {
			ins = 0; del = 0
			s = a " " b
			n = split(s, w, /[^0-9a-z]+/)
			for (i = 1; i <= n; i++) {
				if (w[i] ~ /^insertions?$/ || w[i] ~ /^insertion$/) ins += w[i-1]
				else if (w[i] ~ /^deletions?$/ || w[i] ~ /^deletion$/) del += w[i-1]
			}
			if (ins > 0 || del > 0) printf "(+%d,-%d)", ins, del
		}')
	fi
fi

#--- terminal width -----------------------------------------------------------
# stdout is a pipe, so `tput cols` alone reports nothing. Try the explicit
# override, then the controlling terminal, then the parent process tty. Unknown
# width simply means no padding — the groups get joined with a separator instead.

width=''
if is_num "${CCSTATUSLINE_WIDTH:-}"; then
	width=$CCSTATUSLINE_WIDTH
else
	width=$(tput cols 2>/dev/null </dev/tty) || width=''
	# Claude Code may invoke this through one or more intermediate shells, none of
	# which own /dev/tty. Walk up the process tree looking for one that does, as
	# ccstatusline does. Only reached when the cheap probes have already failed.
	if ! is_num "$width"; then
		_pid=$PPID
		_hop=0
		while [ "$_hop" -lt 8 ] && is_num "${_pid:-}" && [ "$_pid" -gt 1 ]; do
			_hop=$((_hop + 1))
			_tty=$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d '[:space:]')
			case ${_tty:-} in
			'' | '?' | '??') ;;
			*)
				width=$(stty size <"/dev/$_tty" 2>/dev/null | awk '{print $2}')
				is_num "$width" && break
				;;
			esac
			_pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d '[:space:]')
		done
	fi
fi
is_num "$width" && [ "$width" -gt 20 ] || width=''

#--- compose ------------------------------------------------------------------
# Each segment is appended to a colored string and, in parallel, to a plain one.
# Padding must be measured on the plain text; measuring the colored text would
# count the escape sequences and over-pad every line.

segx() { # segx <varname-colored> <varname-plain> <colored-text> <plain-text>
	eval "_c=\$$1"
	eval "_p=\$$2"
	if [ -n "$_p" ]; then
		_c="$_c$SEP"
		_p="$_p$SEP"
	fi
	eval "$1=\$_c\$3"
	eval "$2=\$_p\$4"
}

seg() { # seg <varname-colored> <varname-plain> <color> <text>
	segx "$1" "$2" "$3$4$C_RESET" "$4"
}

emit() { # emit <left-colored> <left-plain> <right-colored> <right-plain>
	if [ -z "$2" ] && [ -z "$4" ]; then
		return 0
	fi
	if [ -z "$4" ]; then
		printf '%s\n' "$1"
		return 0
	fi
	if [ -z "$2" ]; then
		printf '%s\n' "$3"
		return 0
	fi
	if [ -n "$width" ]; then
		_gap=$((width - $(plainlen "$2") - $(plainlen "$4")))
		if [ "$_gap" -ge 2 ]; then
			printf '%s%s%s\n' "$1" "$(printf "%${_gap}s" '')" "$3"
			return 0
		fi
	fi
	printf '%s%s%s\n' "$1" "$SEP" "$3"
}

# Line 1 — location.
l1c=''; l1p=''
if [ -n "$cwd" ]; then
	# ~ for $HOME, matching the shell prompt this repo configures.
	case $cwd in
	"$HOME") _d='~' ;;
	"$HOME"/*) _d="~${cwd#"$HOME"}" ;;
	*) _d=$cwd ;;
	esac
	seg l1c l1p "$C_DIR" "cwd: $_d"
fi
[ -n "$branch" ] && seg l1c l1p "$C_BRANCH" "⎇ $branch"
[ -n "$changes" ] && seg l1c l1p "$C_DIFF" "$changes"

r1c=''; r1p=''
[ -n "$session" ] && seg r1c r1p "$C_SESSION" "Session: $session"

# Line 2 — session metrics.
l2c=''; l2p=''
[ -n "$model" ] && seg l2c l2p "$C_MODEL" "Model: $model"
[ -n "$version" ] && seg l2c l2p '' "v$version"
if is_num "$ctx_len"; then
	_pct=$(awk -v a="$ctx_len" -v b="$ctx_size" 'BEGIN { printf "%.1f", (b > 0 ? a * 100 / b : 0) }')
	seg l2c l2p "$C_CTX" "Ctx Used: ${_pct}%"
fi

r2c=''; r2p=''
# In:/Out: sit adjacent with no separator but distinct colors, as upstream renders
# them, so they are composed by hand rather than through seg().
if is_num "$tok_in" || is_num "$tok_out"; then
	_ioc=''
	_iop=''
	if is_num "$tok_in"; then
		_iop="In: $(fmt_tokens "$tok_in")"
		_ioc="$C_IN$_iop$C_RESET"
	fi
	if is_num "$tok_out"; then
		[ -n "$_iop" ] && { _iop="$_iop "; _ioc="$_ioc "; }
		_t="Out: $(fmt_tokens "$tok_out")"
		_iop="$_iop$_t"
		_ioc="$_ioc$C_OUT$_t$C_RESET"
	fi
	segx r2c r2p "$_ioc" "$_iop"
fi
is_num "$tok_total" && seg r2c r2p "$C_TOTAL" "Total: $(fmt_tokens "$tok_total")"
if [ -n "$cost" ]; then
	_cost=$(awk -v c="$cost" 'BEGIN { printf "%.2f", c }' 2>/dev/null)
	[ -n "$_cost" ] && seg r2c r2p "$C_COST" "Cost: \$$_cost"
fi

emit "$l1c" "$l1p" "$r1c" "$r1p"
emit "$l2c" "$l2p" "$r2c" "$r2p"
