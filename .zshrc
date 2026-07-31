#
# .zshrc — sourced from a managed block in $HOME/.zshrc, not symlinked.
# See install.sh for why (image-provided rc content has to survive).
#

# Path to your oh-my-zsh installation. install.sh puts it here; the parameter
# expansion lets a workspace image that already installed it elsewhere win.
export ZSH="${ZSH:-$HOME/.oh-my-zsh}"

# agnoster ships with oh-my-zsh core, so there is nothing extra to clone.
# It is a *powerline* theme: the segment separators and the branch glyph render
# as tofu unless the terminal uses a patched font (Meslo LG, or any Nerd Font).
# That font is a setting on the machine you connect FROM — it cannot be fixed
# from inside the workspace.
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="agnoster"

# agnoster opens every prompt with a user@host segment. Setting DEFAULT_USER to
# the workspace user hides it when you are who you expect to be, leaving just
# path and git state. Export DEFAULT_USER beforehand to keep the segment.
DEFAULT_USER="${DEFAULT_USER:-$USER}"

plugins=(git)

# Guarded: a workspace with no network (or no git) never got oh-my-zsh, and this
# file must degrade to a plain zsh prompt rather than print an error on every
# single shell start.
if [ -r "$ZSH/oh-my-zsh.sh" ]; then
	source "$ZSH/oh-my-zsh.sh"
fi
