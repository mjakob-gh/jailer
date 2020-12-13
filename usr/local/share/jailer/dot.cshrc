# $FreeBSD: stable/12/bin/csh/dot.cshrc 363525 2020-07-25 11:57:39Z pstef $
#
# .cshrc - csh resource script, read at beginning of execution by each shell
#
# see also csh(1), environ(7).
# more examples available at /usr/share/examples/csh/
#
# Sets SSH_AUTH_SOCK to the user's ssh-agent socket path if running
#
# This has a couple caveats, the most notable being that if a user
# has multiple ssh-agent(1) processes running, this will very likely
# set SSH_AUTH_SOCK to point to the wrong file/domain socket.
if (${?SSH_AUTH_SOCK} != "1") then
        setenv SSH_AUTH_SOCK `sockstat -u | awk '/^${USER}.+ ssh-agent/ { print $6 }'`
endif

# Change only root's prompt
if (`id -g` == 0) then
        set prompt="root@%m# "
endif

alias h         history 25
alias j         jobs -l
alias la        ls -aF
alias lf        ls -FA
alias ll        ls -lAF

# read(2) of directories may not be desirable by default, as this will provoke
# EISDIR errors from each directory encountered.
# alias grep    grep -d skip

# A righteous umask
umask 22

set path = (/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin $HOME/bin)

setenv  EDITOR          vi
setenv  PAGER           less
setenv  BLOCKSIZE       K

setenv LESS         --RAW-CONTROL-CHARS

setenv LC_CTYPE     C.UTF-8
setenv LC_TIME      C.UTF-8
setenv LC_NUMERIC   C.UTF-8
setenv LC_MONETARY  C.UTF-8
setenv LC_MESSAGES  C.UTF-8
setenv LC_COLLATE   C.UTF-8

if ($?prompt) then
        setenv TERM xterm-256color
        # An interactive shell -- set some stuff up
        set prompt = "%N@%m:%~ %# "
        set promptchars = "%#"

        set filec
        set history = 1000
        set savehist = (1000 merge)
        set autolist = ambiguous
        # Use history to aid expansion
        set autoexpand
        set autorehash
        set mail = (/var/mail/$USER)
        if ( $?tcsh ) then
                bindkey "^W" backward-delete-word
                bindkey -k up history-search-backward
                bindkey -k down history-search-forward
                # This maps the "Delete" key to do the right thing
                # Pressing CTRL-v followed by the key of interest will print the shell's
                # mapping for the key
                bindkey "^[[3~" delete-char-or-list-or-eof
                bindkey "^[[1~" beginning-of-line
                bindkey "^[[4~" end-of-line

                # Make the Ins key work
                bindkey "^[[2~" overwrite-mode

                # Color on many system utilities
                setenv CLICOLOR 1
        endif
endif
