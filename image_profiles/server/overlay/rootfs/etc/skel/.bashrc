# /etc/skel/.bashrc — ShaniOS server profile default bash config
# Applied to every new user including cloud-init's 'shanios' user and root.
# Consistent with .zshrc — same aliases, same tools, same mcfly/starship.

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# ── Starship prompt ───────────────────────────────────────────────────────────
export STARSHIP_CONFIG="${STARSHIP_CONFIG:-/etc/starship/server.toml}"
if [ -x /usr/bin/starship ]; then
    __main() {
        local major="${BASH_VERSINFO[0]}"
        local minor="${BASH_VERSINFO[1]}"
        if ((major > 4)) || { ((major == 4)) && ((minor >= 1)); }; then
            source <("/usr/bin/starship" init bash --print-full-init)
        else
            source /dev/stdin <<<"$("/usr/bin/starship" init bash --print-full-init)"
        fi
    }
    __main
    unset -f __main
fi

# ── Terminal title: user@host:path ────────────────────────────────────────────
case "$TERM" in
    xterm*|rxvt*|screen*|tmux*)
        PROMPT_COMMAND='printf "\033]0;%s@%s:%s\007" "$USER" "$HOSTNAME" "${PWD/$HOME/~}"'
        ;;
esac

# ── PATH ──────────────────────────────────────────────────────────────────────
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
[[ -d "/usr/local/bin"   ]] && export PATH="/usr/local/bin:$PATH"

# ── History ───────────────────────────────────────────────────────────────────
HISTFILE=~/.bash_history
HISTSIZE=50000
HISTFILESIZE=10000
HISTCONTROL=ignoredups:erasedups   # no duplicate entries
shopt -s histappend                # append; don't overwrite on exit
shopt -s cmdhist                   # save multi-line commands as one entry
# Flush history after every command so multiple sessions don't clobber each other
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }history -a"

# ── Shell options ─────────────────────────────────────────────────────────────
shopt -s checkwinsize   # update LINES/COLUMNS after each command
shopt -s autocd         # type a path to cd into it
shopt -s cdspell        # auto-correct minor cd typos
shopt -s dirspell       # auto-correct directory names in completion
shopt -s globstar       # ** matches all files and dirs recursively
shopt -s nocaseglob     # case-insensitive globbing

# ── Completion ────────────────────────────────────────────────────────────────
if ! shopt -oq posix; then
    if [[ -f /usr/share/bash-completion/bash_completion ]]; then
        source /usr/share/bash-completion/bash_completion
    elif [[ -f /etc/bash_completion ]]; then
        source /etc/bash_completion
    fi
fi

# ── mcfly: smart shell history (replaces Ctrl-R) ─────────────────────────────
export MCFLY_FUZZY=true
export MCFLY_RESULTS=20
export MCFLY_INTERFACE_VIEW=BOTTOM
export MCFLY_RESULTS_SORT=LAST_RUN
command -v mcfly &>/dev/null && eval "$(mcfly init bash)"

# ── fzf ───────────────────────────────────────────────────────────────────────
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
[[ -f /usr/share/fzf/key-bindings.bash ]] && source /usr/share/fzf/key-bindings.bash
[[ -f /usr/share/fzf/completion.bash   ]] && source /usr/share/fzf/completion.bash

# ── Coloured output ───────────────────────────────────────────────────────────
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias dir='dir --color=auto'
alias vdir='vdir --color=auto'
alias ip='ip -color'

# ── Navigation ────────────────────────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias ......='cd ../../../../..'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'

# ── Archive ───────────────────────────────────────────────────────────────────
alias tarnow='tar -acf'
alias untar='tar -zxvf'
alias wget='wget -c'   # resume interrupted downloads

# ── Process & memory ──────────────────────────────────────────────────────────
alias psmem='ps auxf | sort -nr -k 4'
alias psmem10='ps auxf | sort -nr -k 4 | head -10'
alias pscpu='ps auxf | sort -nr -k 3'
alias pscpu10='ps auxf | sort -nr -k 3 | head -10'

# ── Logging ───────────────────────────────────────────────────────────────────
alias jctl='journalctl -p 3 -xb'
alias jf='journalctl -f'
alias jfu='journalctl -f -u'

# ── Systemd ───────────────────────────────────────────────────────────────────
alias sc='systemctl'
alias scs='systemctl status'
alias sce='systemctl enable --now'
alias scd='systemctl disable --now'
alias scr='systemctl restart'

# ── Network ───────────────────────────────────────────────────────────────────
alias ports='ss -tulnp'
alias myip='curl -s ifconfig.me'
alias localip='ip -br a'
alias hw='hwinfo --short 2>/dev/null || inxi -b'

# ── Disk & Btrfs ──────────────────────────────────────────────────────────────
alias df='df -hT'
alias du='du -sh'
alias dua='du -sh *'
alias btrfsdf='btrfs filesystem df'
alias btrfsus='btrfs filesystem usage'

# ── Containers ────────────────────────────────────────────────────────────────
alias docker='podman'
alias dps='podman ps -a'
alias dim='podman images'
alias dex='podman exec -it'
alias dlg='podman logs -f'

# ── ShaniOS ───────────────────────────────────────────────────────────────────
alias shani-update='sudo shani-deploy update'

# ── Safety nets ───────────────────────────────────────────────────────────────
alias rm='rm -I'
alias cp='cp -i'
alias mv='mv -i'
alias ln='ln -i'

# ── Environment ───────────────────────────────────────────────────────────────
export EDITOR=vim
export VISUAL=vim
export PAGER=less
export LESS='-R --use-color'
export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
