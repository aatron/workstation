# WSL Set-up

## Settings

### Terminal

* WSL Color scheme - Dark+
* [herdr](https://herdr.dev/)

### Scripts folder

```
mkdir -p ~/tools/scripts
echo 'export PATH="$HOME/tools/scripts:$PATH"' >> ~/.bashrc
```

### Git prompt

Add to `~/.bashrc` so the prompt shows branch, dirty/stash/untracked state, and upstream while you navigate:

```
# --- git prompt ---
for f in /usr/lib/git-core/git-sh-prompt \
         /usr/share/git-core/contrib/completion/git-prompt.sh \
         /usr/share/git/completion/git-prompt.sh; do
    [ -f "$f" ] && . "$f" && break
done

if type __git_ps1 >/dev/null 2>&1; then
    GIT_PS1_SHOWDIRTYSTATE=1
    GIT_PS1_SHOWSTASHSTATE=1
    GIT_PS1_SHOWUNTRACKEDFILES=1
    GIT_PS1_SHOWUPSTREAM="auto"
    GIT_PS1_SHOWCOLORHINTS=1
    PROMPT_COMMAND='__git_ps1 "\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]" "\\\$ "'
fi
```

Then `source ~/.bashrc` (or open a new shell). Requires `git` installed.

### Micro text editor

```
sudo apt update
sudo apt install micro
sudo apt install xclip
```

#### Micro settings

* Copy/paste might need some configuration
    * Smoke test:
        * Smoke test copy/paste list between Windows and: 
            * WSL bash
            * Micro
            * Herdr bash
            * Herdr micro
        * If any fails, likely need to set `~/.bashrc` to replace the display line with `export DISPLAY=:0`
    * This setting might be needed
        * In micro, press `Ctrl + e` --> `set clipboard external`

