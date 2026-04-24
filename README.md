# tcpux

A strict, axiom-first TCP command queue for tmux. The server accepts
**only** tmux-shaped commands that satisfy an explicit algebra (see
[AXIOMS.md](./AXIOMS.md)). Everything else is rejected with a stable
error code so senders can cascade programmatically.

## Layout

    server.py   — in-memory queue + axiom-checked router
    worker.py   — polls server, reports tmux pane state, executes ops
    client.py   — CLI submit with auto-cascade on rejection
    axioms.py   — pure predicates, one per command family
    proto.py    — framed-JSON TCP helpers (zero deps)
    AXIOMS.md   — formal command algebra

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
