#!/bin/sh
#
# install.sh — dotfiles bootstrap for github.com/untra/dotfiles
#
# WHY THIS EXISTS
#
# Coder's built-in dotfiles installer clones this repo to
# ~/.config/coderv2/dotfiles and then symlinks every ROOT-level entry into
# $HOME. That cannot work here: symlink(2) will not overwrite an existing
# directory, and ~/.claude already exists in every workspace with live state
# (.credentials.json, projects/, todos/). The result is:
#
#   error: symlinking .../dotfiles/.claude to /home/coder/.claude: file exists
#
# Coder probes for a bootstrap script (install.sh first) and, when it finds
# one, runs it and returns BEFORE its own symlink loop (cli/dotfiles.go:177-221).
# So this script replaces that behavior with file-level merging: every regular
# file in the repo is placed at the same relative path under $HOME, with
# intermediate directories created as real directories.
#
# STRATEGY, by file type:
#
#   *.json      deep-merge the existing $HOME file into the REPO file (repo
#               values win, arrays are replaced not unioned), write the merged
#               result back to the repo, back up the original, then symlink.
#               Captures workspace-local settings instead of discarding them.
#   shell rc    never symlinked. An idempotent managed block is written into
#               $HOME's copy that sources the repo file, preserving whatever
#               the workspace image already put there.
#   everything  back up any pre-existing real file to a timestamped directory,
#   else        then symlink.
#
# Nothing is ever deleted. Displaced files land in
# $HOME/.dotfiles-backup/<timestamp>/<relative-path>.
#
# POSIX sh — Coder images may ship dash or busybox ash, which are stricter than
# macOS's bash-in-sh-mode. No bashisms, no GNU-only flags, no `readlink -f`.
# Idempotent: re-running is a no-op once everything is in place.
#
# Environment:
#   DOTFILES_TARGET_DIR   destination (default: $CODER_SYMLINK_DIR, else $HOME)
#   DOTFILES_DRY_RUN=1    print what would happen; change nothing
#   DOTFILES_SKIP_OMZ=1   do not fetch oh-my-zsh

set -eu

#--- locate ourselves, independent of cwd -------------------------------------
# Coder sets cwd to the repo root, but people run this by hand too.
# `cd -P && pwd -P` rather than `readlink -f`, which is absent on older macOS.

SELF=${0##*/}
case $0 in
*/*) SRC=$(CDPATH='' cd -P -- "${0%/*}" && pwd -P) ;;
*) SRC=$(pwd -P) ;;
esac

DEST=${DOTFILES_TARGET_DIR:-${CODER_SYMLINK_DIR:-${HOME:-}}}
DRY_RUN=${DOTFILES_DRY_RUN:-0}
BACKUP_ROOT=$DEST/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)

MARK_BEGIN='# >>> untra/dotfiles (managed) >>>'
MARK_END='# <<< untra/dotfiles (managed) <<<'

log() { printf '[dotfiles] %s\n' "$*"; }
warn() { printf '[dotfiles] WARN: %s\n' "$*" >&2; }
die() {
	printf '[dotfiles] ERROR: %s\n' "$*" >&2
	exit 1
}

# Every mutation goes through this so DOTFILES_DRY_RUN=1 touches nothing.
do_() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dotfiles] would: %s\n' "$*"
	else
		"$@"
	fi
}

[ -n "$DEST" ] || die "\$HOME is unset and neither DOTFILES_TARGET_DIR nor CODER_SYMLINK_DIR is set."
[ -d "$DEST" ] || die "destination '$DEST' does not exist or is not a directory."
[ -d "$SRC" ] || die "could not resolve the dotfiles directory from '\$0'."

case $SRC in
"$DEST") die "refusing to run: repo '$SRC' is the destination itself." ;;
esac

log "source:      $SRC"
log "destination: $DEST"
[ "$DRY_RUN" = 1 ] && log "mode:        DRY RUN (no changes will be made)"

#--- exclusions ---------------------------------------------------------------
# Matched against the repo-relative path. Markdown is deliberately NOT excluded
# wholesale, so a future .claude/CLAUDE.md still gets linked.

is_excluded() {
	case $1 in
	"$SELF" | install.sh | install | bootstrap.sh | bootstrap | setup.sh | setup) return 0 ;;
	README* | LICENSE* | COPYING* | CHANGELOG* | NOTICE*) return 0 ;;
	.gitignore | .gitattributes | .gitmodules) return 0 ;;
	.DS_Store | */.DS_Store) return 0 ;;
	*.bak | *.orig | *.rej | *.dotfiles-merge.* | *.dotfiles-new.*) return 0 ;;
	esac
	return 1
}

# Shell startup files, matched on basename. These are merged via a managed
# block rather than symlinked, so image-provided rc content survives.
is_rc() {
	case $1 in
	.zshrc | .zshenv | .zprofile | .zlogin | .zlogout) return 0 ;;
	.bashrc | .bash_profile | .bash_login | .bash_logout) return 0 ;;
	.profile) return 0 ;;
	esac
	return 1
}

#--- helpers ------------------------------------------------------------------

# Move a path under $DEST into the timestamped backup tree, preserving its
# relative layout. Only ever moves — never removes user data.
backup_path() {
	_bp_rel=${1#"$DEST"/}
	_bp_rel=${_bp_rel#/}
	_bp_to=$BACKUP_ROOT/$_bp_rel
	do_ mkdir -p "${_bp_to%/*}"
	do_ mv "$1" "$_bp_to"
	log "backup   $1 -> $_bp_to  ($2)"
	backed_up=$((backed_up + 1))
}

# Guarantee every intermediate directory of a relative path is a REAL directory
# under $DEST.
#
# This is the important one. A previous `coder dotfiles` run very likely left
# $HOME in a half-installed state: ~/.claude failed, but ~/.codex and ~/.gemini
# had no conflict and became whole-directory symlinks INTO this repo. Descending
# through such a link would resolve $DEST/.codex/config.toml to the repo's own
# source file, which we would then dutifully "back up" — moving the repo source
# out from under itself and leaving a dangling link.
#
# So: any ancestor symlink that resolves inside $SRC is retired. One pointing
# anywhere else (say ~/.config -> /mnt/persist/config) is the user's own
# arrangement and is followed as-is.
ensure_dir_chain() {
	case $1 in */*) ;; *) return 0 ;; esac

	_ed_ifs=$IFS
	IFS=/
	set -f
	# shellcheck disable=SC2086  # intentional split on IFS=/ into path components
	set -- ${1%/*}
	set +f
	IFS=$_ed_ifs

	_ed_cur=$DEST
	for _ed_c in "$@"; do
		_ed_cur=$_ed_cur/$_ed_c
		if [ -L "$_ed_cur" ]; then
			_ed_res=$(CDPATH='' cd -P -- "$_ed_cur" 2>/dev/null && pwd -P) || _ed_res=''
			case $_ed_res in
			"$SRC" | "$SRC"/*)
				backup_path "$_ed_cur" "stale directory symlink into the dotfiles repo"
				;;
			esac
		fi
		if [ ! -d "$_ed_cur" ]; then
			[ -e "$_ed_cur" ] && backup_path "$_ed_cur" "file occupying a directory path"
			do_ mkdir -p "$_ed_cur"
			log "mkdir    $_ed_cur"
		fi
	done
	return 0
}

# Deep-merge $2 (the existing $HOME file) into $1 (the repo file), repo winning,
# and write the result back to $1. Objects recurse and union their keys; arrays
# and scalars take the repo's value outright.
#
# Arrays replace rather than union on purpose: every JSON file here is a
# permissions policy, and .claude/settings.json deliberately ships an empty
# `permissions.allow`. Unioning would let a permissive allow-list baked into the
# workspace image survive and silently grant what the dotfiles withhold.
#
# Returns 0 if the merge was handled, 1 if the caller should fall back to
# letting the repo copy win wholesale.
# shellcheck disable=SC2016  # $a/$b/$x/$y are jq variables; shell must not expand them
JQ_DEEPMERGE='
def dm($x; $y):
  if ($x|type) == "object" and ($y|type) == "object" then
    reduce ($y|keys_unsorted[]) as $k ($x;
      .[$k] = (if ($x|has($k)) then dm($x[$k]; $y[$k]) else $y[$k] end))
  else $y end;
dm($a[0]; $b[0])
'

merge_json() {
	_mj_src=$1
	_mj_dst=$2

	if ! command -v jq >/dev/null 2>&1; then
		warn "jq not found; not merging $_mj_dst (the repo copy will win wholesale)."
		return 1
	fi
	if ! jq -e . "$_mj_dst" >/dev/null 2>&1; then
		warn "$_mj_dst is not valid JSON; not merging (the repo copy will win wholesale)."
		return 1
	fi
	if ! jq -e . "$_mj_src" >/dev/null 2>&1; then
		warn "$_mj_src is not valid JSON; not merging."
		return 1
	fi

	# Seed the temp file from the repo file so its mode survives the rewrite,
	# then truncate it in place with jq's output.
	_mj_tmp=$_mj_src.dotfiles-merge.$$
	cp -p "$_mj_src" "$_mj_tmp"
	if ! jq -n --slurpfile a "$_mj_dst" --slurpfile b "$_mj_src" "$JQ_DEEPMERGE" >"$_mj_tmp" 2>/dev/null; then
		rm -f "$_mj_tmp"
		warn "jq merge of $_mj_dst failed; the repo copy will win wholesale."
		return 1
	fi

	# Compare canonically. jq reformats, so a byte comparison against the
	# hand-written repo file would report a diff on every single run and leave
	# the workspace clone permanently dirty.
	if [ "$(jq -S -c . "$_mj_src")" = "$(jq -S -c . "$_mj_tmp")" ]; then
		rm -f "$_mj_tmp"
		return 0
	fi

	if [ "$DRY_RUN" = 1 ]; then
		rm -f "$_mj_tmp"
		printf '[dotfiles] would: merge %s into %s (captures keys the repo lacks)\n' "$_mj_dst" "$_mj_src"
		return 0
	fi

	mv "$_mj_tmp" "$_mj_src"
	log "merged   $_mj_dst -> $_mj_src (repo values kept, new keys captured)"
	merged=$((merged + 1))
	return 0
}

# Write an idempotent managed block into $2 that sources $1. Re-running replaces
# the existing block in place rather than appending a second copy, and anything
# outside the markers is left untouched.
install_rc_block() {
	_rc_src=$1
	_rc_dst=$2

	if [ "$DRY_RUN" = 1 ]; then
		printf '[dotfiles] would: ensure managed block sourcing %s in %s\n' "$_rc_src" "$_rc_dst"
		return 0
	fi

	# An older run (or Coder's default) may have left a symlink here. Reading
	# through it would splice the repo file into itself.
	if [ -L "$_rc_dst" ]; then
		backup_path "$_rc_dst" "symlinked rc file replaced by a managed block"
	fi

	_rc_new=$_rc_dst.dotfiles-new.$$
	{
		if [ -f "$_rc_dst" ]; then
			awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
				$0 == b { skip = 1 }
				skip != 1 { print }
				$0 == e { skip = 0 }
			' "$_rc_dst"
		fi
		printf '%s\n' "$MARK_BEGIN"
		printf '[ -r "%s" ] && . "%s"\n' "$_rc_src" "$_rc_src"
		printf '%s\n' "$MARK_END"
	} >"$_rc_new"

	if [ -f "$_rc_dst" ] && cmp -s "$_rc_new" "$_rc_dst"; then
		rm -f "$_rc_new"
		log "ok       ${_rc_dst#"$DEST"/} (managed block current)"
		unchanged=$((unchanged + 1))
		return 0
	fi

	mv "$_rc_new" "$_rc_dst"
	log "block    $_rc_dst (sources $_rc_src)"
	blocks=$((blocks + 1))
	return 0
}

#--- oh-my-zsh ----------------------------------------------------------------
# The repo's .zshrc sets ZSH_THEME="agnoster" and sources $ZSH/oh-my-zsh.sh, so
# the framework has to be on disk before that managed block is worth anything.
# agnoster is part of oh-my-zsh core (themes/agnoster.zsh-theme) — no separate
# clone, no custom theme directory.
#
# It is fetched at install time rather than vendored: committing upstream would
# add ~1500 files this repo does not own and would then have to be updated by
# hand. The cost is a network dependency at workspace creation, which is why
# every failure below is a warning rather than a die — a workspace with no
# network still gets every other dotfile, and .zshrc guards its own source line
# so a missing ~/.oh-my-zsh degrades to a plain zsh prompt instead of erroring on
# every shell start.

OMZ_URL=https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh

install_omz() {
	if [ "${DOTFILES_SKIP_OMZ:-0}" = 1 ]; then
		log "skip     oh-my-zsh (DOTFILES_SKIP_OMZ=1)"
		return 0
	fi
	# Nothing to bootstrap if this repo does not ship a zsh rc.
	if [ ! -f "$SRC/.zshrc" ]; then
		return 0
	fi

	_omz_dir=$DEST/.oh-my-zsh
	if [ -d "$_omz_dir" ]; then
		log "ok       oh-my-zsh (already at $_omz_dir)"
		return 0
	fi

	# The installer clones; without git it fails halfway and leaves a partial dir.
	if ! command -v git >/dev/null 2>&1; then
		warn "git not found; skipping oh-my-zsh (the prompt falls back to plain zsh)."
		return 0
	fi

	if command -v curl >/dev/null 2>&1; then
		_omz_fetch='curl -fsSL'
	elif command -v wget >/dev/null 2>&1; then
		_omz_fetch='wget -qO-'
	else
		warn "neither curl nor wget found; skipping oh-my-zsh."
		return 0
	fi

	if [ "$DRY_RUN" = 1 ]; then
		printf '[dotfiles] would: install oh-my-zsh into %s\n' "$_omz_dir"
		return 0
	fi

	# Download to a file first. Piping straight into sh hides transport failures:
	# the command substitution yields an empty string and `sh -c ''` exits 0, so a
	# 404 or a captive portal would look like a successful install.
	_omz_tmp=$DEST/.dotfiles-omz-install.$$.sh
	# shellcheck disable=SC2086  # _omz_fetch is a command + flags; must word-split
	if ! $_omz_fetch "$OMZ_URL" >"$_omz_tmp" 2>/dev/null || [ ! -s "$_omz_tmp" ]; then
		rm -f "$_omz_tmp"
		warn "could not download the oh-my-zsh installer; continuing without it."
		return 0
	fi

	log "fetch    oh-my-zsh -> $_omz_dir"
	# ZSH          install location, so this honors DOTFILES_TARGET_DIR.
	# KEEP_ZSHRC   do not write the stock ~/.zshrc template. It would land ahead of
	#              our managed block and set ZSH_THEME to robbyrussell first.
	# --unattended implies RUNZSH=no CHSH=no: no login shell exec'd at the end, no
	#              chsh(1) prompt. Either would hang Coder's bootstrap, whose stdin
	#              is /dev/null.
	if ! ZSH=$_omz_dir KEEP_ZSHRC=yes sh "$_omz_tmp" --unattended >/dev/null 2>&1; then
		rm -f "$_omz_tmp"
		warn "the oh-my-zsh installer failed; continuing without it."
		return 0
	fi
	rm -f "$_omz_tmp"

	if [ -r "$_omz_dir/oh-my-zsh.sh" ]; then
		log "install  oh-my-zsh at $_omz_dir (theme: agnoster)"
	else
		warn "oh-my-zsh reported success but $_omz_dir/oh-my-zsh.sh is missing."
	fi
	return 0
}

install_omz

#--- main ---------------------------------------------------------------------
# `find | { ... }` runs the loop body in a subshell, so the counters and the
# summary live inside it. `set -e` still aborts on error and the subshell's
# status is the pipeline's status, so failures propagate back to Coder.

find "$SRC" \( -name .git -o -name .github -o -name node_modules \) -prune \
	-o -type f -print | {
	linked=0 relinked=0 unchanged=0 merged=0 blocks=0 backed_up=0 skipped=0

	while IFS= read -r src; do
		rel=${src#"$SRC"/}

		if is_excluded "$rel"; then
			skipped=$((skipped + 1))
			continue
		fi

		ensure_dir_chain "$rel"

		dst=$DEST/$rel
		base=${rel##*/}
		parent=${dst%/*}

		# Belt and braces behind ensure_dir_chain: the parent is now a real
		# directory, so its physical path proves we are not about to operate on
		# the repo itself. Covers a repo cloned inside $HOME, bind mounts, and
		# macOS's /tmp -> /private/tmp.
		if [ -d "$parent" ]; then
			parent_phys=$(CDPATH='' cd -P -- "$parent" && pwd -P)
			if [ "$parent_phys/$base" = "$src" ]; then
				log "skip     $rel (destination is the source file)"
				skipped=$((skipped + 1))
				continue
			fi
		fi

		# Shell rc files are merged via a managed block, never symlinked —
		# unconditionally, so the behavior does not depend on whether the
		# workspace image happened to ship one.
		if is_rc "$base"; then
			install_rc_block "$src" "$dst"
			continue
		fi

		# -L before -e: -e follows symlinks and is false for a dangling one.
		if [ -L "$dst" ]; then
			current=$(readlink "$dst") || current=''
			if [ "$current" = "$src" ]; then
				log "ok       $rel (already linked)"
				unchanged=$((unchanged + 1))
				continue
			fi
			# Foreign symlink: remove the link only, never its target.
			do_ rm -f "$dst"
			log "relink   $rel (was -> ${current:-<unreadable>})"
			relinked=$((relinked + 1))
		elif [ -e "$dst" ]; then
			# A real file or directory. This is also the repair path for tools
			# that persist config with write-temp-then-rename(2), which replaces
			# our symlink with a private regular file.
			case $base in
			*.json) merge_json "$src" "$dst" || : ;;
			esac
			backup_path "$dst" "pre-existing file replaced by symlink"
		fi

		do_ ln -s "$src" "$dst"
		log "link     $dst -> $src"
		linked=$((linked + 1))

		# A symlink has no permissions of its own; exec-ability resolves to the
		# target, which git stores as mode 100755. Nothing to do but notice if
		# that bit was lost.
		case $rel in
		*.sh) [ -x "$src" ] || warn "$rel is not executable in the repo; run: git update-index --chmod=+x '$rel'" ;;
		esac
	done

	log "summary: ${linked} linked, ${relinked} relinked, ${unchanged} unchanged, ${merged} merged, ${blocks} rc blocks, ${backed_up} backed up, ${skipped} skipped"
	[ "$backed_up" -eq 0 ] || log "backups in: $BACKUP_ROOT"
}

log "done."
