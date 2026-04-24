#!/usr/bin/env bash
#===============================================================================
# remote-queue.sh — runs on the target instance to start the tcpux queue server
#                   inside a dedicated tmux session:window:panes.
#
# Invoked by deploy.sh with a single arg: the install directory containing
# the unpacked tcpux source and the deploy .env. Idempotent.
#
# The dev-rule "every terminal command must run through a titled tmux pane"
# exempts the bootstrap calls below (new-session / new-window / split-window /
# pane-name send-keys). Everything that runs AFTER bootstrap lives inside the
# titled panes we create here.
#===============================================================================
set -euo pipefail

INSTALL="${1:?install dir required}"
cd "$INSTALL"
set -o allexport; . ./.env; set +o allexport

SESSION="${QUEUE_SESSION:-tcpux-queue}"
WINDOW="${QUEUE_WINDOW:-queue}"
P_SERVER="${QUEUE_PANE_SERVER:-tcpux-queue-server}"
P_STATE="${QUEUE_PANE_STATE:-tcpux-queue-state}"
HOST="${TCPUX_HOST:-127.0.0.1}"
PORT="${TCPUX_PORT:-9998}"
PY="${PYTHON:-python3}"
SHELL_NAMES='^(bash|zsh|fish|sh|dash|tcsh|ksh)$'

say() { printf '  %s\n' "$*"; }

# ── 1. session ─────────────────────────────────────────────────
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n "$WINDOW" -c "$INSTALL"
    say "created session $SESSION"
else
    say "session $SESSION exists"
fi

# ── 2. window ──────────────────────────────────────────────────
if ! tmux list-windows -t "$SESSION" -F '#W' | grep -qx "$WINDOW"; then
    tmux new-window -t "$SESSION" -n "$WINDOW" -c "$INSTALL"
    say "created window $WINDOW"
else
    say "window $WINDOW exists"
fi

# ── 3. server pane (first pane of this window) ─────────────────
first_idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | head -1)
tmux select-pane -t "$SESSION:$WINDOW.$first_idx" -T "$P_SERVER"
cur=$(tmux display-message -p -t "$SESSION:$WINDOW.$first_idx" '#{pane_current_command}')
if [[ "$cur" =~ $SHELL_NAMES ]]; then
    tmux send-keys -t "$SESSION:$WINDOW.$first_idx" \
        "cd $INSTALL && TCPUX_HOST=$HOST TCPUX_PORT=$PORT $PY server.py" Enter
    say "started server in pane $P_SERVER"
else
    say "pane $P_SERVER busy ($cur) — leaving alone"
fi

# ── 4. state pane (split if missing) ───────────────────────────
have_state=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_title}' | grep -cx "$P_STATE" || true)
if [[ "$have_state" -eq 0 ]]; then
    tmux split-window -t "$SESSION:$WINDOW" -c "$INSTALL"
    # index of the just-created pane = the last one
    idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | tail -1)
    tmux select-pane -t "$SESSION:$WINDOW.$idx" -T "$P_STATE"
    # wait 2s so the server has time to bind, then poll state.
    tmux send-keys -t "$SESSION:$WINDOW.$idx" \
        "cd $INSTALL && sleep 2 && while sleep 5; do $PY -c 'import os,json,sys; os.environ[\"TCPUX_PORT\"]=\"$PORT\"; sys.path.insert(0,\".\"); from proto import rpc; print(json.dumps(rpc(\"$HOST\",$PORT,{\"op\":\"state\"}),indent=2,default=str)[:800]); print(\"---\")'; done" Enter
    say "started state tail in pane $P_STATE"
else
    say "state pane $P_STATE already exists"
fi

# ── 5. report ─────────────────────────────────────────────────
echo
echo "queue @ $SESSION:$WINDOW"
tmux list-panes -t "$SESSION:$WINDOW" \
    -F '  pane #{pane_index}  title=#{pane_title}  cmd=#{pane_current_command}'
