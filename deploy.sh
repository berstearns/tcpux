#!/usr/bin/env bash
#===============================================================================
# deploy.sh — tcpux deploy orchestrator
#
#   ./deploy.sh -c deploy/ -t queue  -i local
#   ./deploy.sh -c deploy/ -t worker -i local
#   ./deploy.sh -c deploy/ -t queue  -i user@host
#
#   -c <dir>     config dir (must contain .env, remote-queue.sh, remote-worker.sh)
#   -t <type>    queue | worker
#   -i <target>  local | localhost | user@host | host
#
# The deploy lands inside a tmux session:window:panes on the target,
# addressed by canonical pane titles from the dev-rule
#   any-terminal-command-must-be-run-through-tmux-target-a-specific-tmux-…
# The remote-<type>.sh script is the only one that creates panes.
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'

CFG=""; TYPE=""; INSTANCE=""; SSH_PORT="${SSH_PORT:-22}"

usage() {
    cat <<EOF
usage: $0 -c <deploy-dir> -t <queue|worker> -i <local|user@host>
example:
  $0 -c deploy/ -t queue  -i local
  $0 -c deploy/ -t worker -i local
  $0 -c deploy/ -t queue  -i root@1.2.3.4
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c) CFG="$2"; shift 2 ;;
        -t) TYPE="$2"; shift 2 ;;
        -i) INSTANCE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "$CFG" || -z "$TYPE" || -z "$INSTANCE" ]]; then
    usage; exit 1
fi

case "$TYPE" in
    queue|worker) ;;
    *) echo "type must be queue|worker (got: $TYPE)"; exit 1 ;;
esac

CFG_DIR="$(cd "$CFG" && pwd)"
ENV_FILE="$CFG_DIR/.env"
REMOTE_SCRIPT="$CFG_DIR/remote-$TYPE.sh"
[[ -f "$ENV_FILE" ]]        || { echo "missing $ENV_FILE (cp $CFG_DIR/.env.example $ENV_FILE)"; exit 1; }
[[ -f "$REMOTE_SCRIPT" ]]   || { echo "missing $REMOTE_SCRIPT"; exit 1; }

# shellcheck disable=SC1090
set -o allexport; . "$ENV_FILE"; set +o allexport
REMOTE_ROOT="${REMOTE_ROOT:-/tmp/tcpux-deploy}"

echo -e "${CYAN}=== tcpux deploy ===${NC}"
echo -e "  config:   ${GREEN}$CFG_DIR${NC}"
echo -e "  type:     ${GREEN}$TYPE${NC}"
echo -e "  instance: ${GREEN}$INSTANCE${NC}"
echo -e "  target:   ${GREEN}$REMOTE_ROOT${NC}"

BUNDLE="/tmp/tcpux-bundle-$$.tar.gz"
trap 'rm -f "$BUNDLE"' EXIT

# Package source (no .git, no __pycache__, no deploy/ — deploy ships separately).
(cd "$SCRIPT_DIR" && tar -czf "$BUNDLE" \
    --exclude='.git' --exclude='__pycache__' --exclude='deploy' \
    axioms.py proto.py server.py worker.py client.py \
    allowlist.py allowlist_server.py allowlist.seed.json \
    AXIOMS.md README.md)

is_local() {
    [[ "$INSTANCE" == "local" || "$INSTANCE" == "localhost" || "$INSTANCE" == "127.0.0.1" ]]
}

# sshpass wrapper — if DO_PASS_FILE or ~/.do-pass exists, wrap ssh/scp.
SSH_WRAP=()
_pass_file=""
[[ -n "${DO_PASS_FILE:-}" && -f "${DO_PASS_FILE:-}" ]] && _pass_file="$DO_PASS_FILE"
[[ -z "$_pass_file" && -f "$HOME/.do-pass" ]] && _pass_file="$HOME/.do-pass"
if [[ -n "$_pass_file" ]]; then
    command -v sshpass >/dev/null || { echo "sshpass required for $_pass_file auth"; exit 1; }
    SSH_WRAP=(sshpass -f "$_pass_file")
    echo -e "${DIM}[auth] using sshpass + $_pass_file${NC}"
fi

if is_local; then
    echo -e "${DIM}[local] unpack → $REMOTE_ROOT${NC}"
    mkdir -p "$REMOTE_ROOT"
    tar -xzf "$BUNDLE" -C "$REMOTE_ROOT"
    cp "$ENV_FILE" "$REMOTE_ROOT/.env"
    echo -e "${DIM}[local] run $REMOTE_SCRIPT $REMOTE_ROOT${NC}"
    bash "$REMOTE_SCRIPT" "$REMOTE_ROOT"
else
    echo -e "${DIM}[ssh] scp bundle → $INSTANCE:/tmp/tcpux-bundle.tar.gz${NC}"
    "${SSH_WRAP[@]}" scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new \
        "$BUNDLE" "$INSTANCE:/tmp/tcpux-bundle.tar.gz"
    "${SSH_WRAP[@]}" scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new \
        "$ENV_FILE" "$INSTANCE:/tmp/tcpux.env"
    echo -e "${DIM}[ssh] pipe remote-$TYPE.sh${NC}"
    # Unpack and run the script on the target; pass install dir as $1.
    "${SSH_WRAP[@]}" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$INSTANCE" \
        "mkdir -p '$REMOTE_ROOT' && \
         tar -xzf /tmp/tcpux-bundle.tar.gz -C '$REMOTE_ROOT' && \
         mv /tmp/tcpux.env '$REMOTE_ROOT/.env' && \
         bash -s '$REMOTE_ROOT'" < "$REMOTE_SCRIPT"
fi

echo -e "${GREEN}=== deploy complete ===${NC}"
