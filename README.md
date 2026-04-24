# tcpux

A strict, axiom-first TCP command queue for tmux. The server accepts
**only** tmux-shaped commands that satisfy an explicit algebra (see
[AXIOMS.md](./AXIOMS.md)). Everything else is rejected with a stable
error code so senders can cascade programmatically.

## Layout

    server.py              — in-memory queue + axiom-checked router + ip gate
    worker.py              — polls server, reports tmux pane state, executes ops
    client.py              — CLI submit with auto-cascade on rejection
    axioms.py              — pure predicates, one per command family
    allowlist.py           — redux-style reducer + IP axioms + atomic JSON store
    allowlist_server.py    — admin TCP server with allow/block/get ops
    allowlist.seed.json    — initial allowed IPs (bootstrap only)
    proto.py               — framed-JSON TCP helpers (zero deps)
    AXIOMS.md              — formal command algebra

## Minimal use case

    # terminal 1 — server
    python server.py

    # terminal 2 — worker (on the remote/target host)
    python worker.py --name worker1

    # terminal 3 — client
    python client.py -w worker1 -p sessions2:w7:p1 \
        -c "cd ~/simple-tcp-comm && git pull && python worker.py"

On the client side the flow is:

1. Server validates the `send-keys` against the strict axioms.
2. If the pane `sessions2:w7:p1` does not exist for `worker1`, the
   server rejects with `SK3_PANE_NOT_EXIST`.
3. The client cascades: `create-pane` → (if missing) `create-window`
   → (if missing) `create-session`. Each construction op is itself
   strictly axiomatic.
4. The worker picks up the queued creation ops, runs tmux, and the next
   `tmux-panes-update` reflects the new state.
5. The client retries `send-keys`.

tmux auto-assigns pane indices, so the actually created `pane_id` may
differ from the requested one. The client prints the current pane set
for the worker in that case, and the sender retries with a real id.

## Deploy

`deploy.sh` ships the source + a config dir to a target instance (local
or SSH) and starts queue/worker inside canonical tmux panes:

    ./deploy.sh -c deploy/ -t queue  -i local
    ./deploy.sh -c deploy/ -t worker -i local
    ./deploy.sh -c deploy/ -t queue  -i root@1.2.3.4

`deploy/.env` (gitignored; template in `deploy/.env.example`) drives the
session/window/pane titles, TCP host/port, and install root. Each type
lands in a dedicated session:

    queue  → session `tcpux-queue`  / window `queue`  / panes `tcpux-queue-server`  + `tcpux-queue-state`
    worker → session `tcpux-worker` / window `worker` / panes `tcpux-worker-main`   + `tcpux-worker-obs`

All command dispatch on the target happens through titled tmux panes per
[this dev-rule](https://github.com/berstearns/all-my-tiny-projects/blob/main/claude-rules/dev-rules/any-terminal-command-must-be-run-through-tmux-target-a-specific-tmux-session-window-pane-and-create-it-if-not-exists.md).

## IP allowlist

All connections to the main queue are gated by a JSON allowlist at
`TCPUX_ALLOWLIST_DB`. The file is maintained by `allowlist_server.py`,
a separate TCP admin daemon with three ops:

    allowlist_server.py allow 1.2.3.4     # move ip to allowed
    allowlist_server.py block 1.2.3.4     # move ip to blocked
    allowlist_server.py get                # dump current state

Mutations are guarded by a shared `TCPUX_ADMIN_TOKEN`. The state is a
redux-style reducer: every ALLOW moves an ip to `allowed` and removes it
from `blocked`, and vice versa. Invariants (`allowed ∩ blocked = ∅`,
every entry a valid IPv4) are re-checked on every reduce. See AXIOMS.md
for the full axiom list.

The queue deploy starts `allowlist_server.py serve` automatically in a
dedicated tmux pane (`tcpux-queue-admin`). The db file is seeded from
`allowlist.seed.json` only if it does not already exist on the target.
Production ports and the admin token live in `deploy/.env` (gitignored).

## Env vars

| var | default | who |
|---|---|---|
| `TCPUX_HOST` | `0.0.0.0` (server) / `127.0.0.1` (worker/client) | all |
| `TCPUX_PORT` | `9998` | all |
| `TCPUX_WORKER` | hostname | worker |
| `TCPUX_POLL` | `2` | worker (seconds between poll) |
| `TCPUX_SYNC` | `5` | worker (seconds between tmux-panes-update) |

## Philosophy

The server is deliberately dumb: it enforces axioms and nothing else.
All knowledge of tmux lives in the worker; all cascade logic lives in
the client. The algebra is in [AXIOMS.md](./AXIOMS.md) — read it first.
