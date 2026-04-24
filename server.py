"""tcpux server — strict axiom-checked tmux command queue.

State is kept entirely in memory:

    STATE[worker_id] = {
        "last_update": float,
        "panes": {pane_id: {"busy": bool, "cmd": str, "ts": float, "logs": []}}
    }

    QUEUE[worker_id] = deque of pending commands (FIFO)
    DISPATCHED[cmd_id] = {"worker": ..., "op": ..., "result": ...}

Every incoming op is routed to the matching axiom check in `axioms.py`.
On success the op either mutates STATE (tmux-panes-update) or gets
enqueued for the worker. On failure the server responds with a stable
error code so the sender can cascade programmatically.
"""
import asyncio, os, sys, time
from collections import deque

import axioms
from proto import serve


HOST = os.environ.get("TCPUX_HOST", "0.0.0.0")
PORT = int(os.environ.get("TCPUX_PORT", "9998"))

STATE      = {}   # worker_id → worker record
QUEUE      = {}   # worker_id → deque[command]
DISPATCHED = {}   # cmd_id    → {"worker","op","result"}
_NEXT_ID   = [0]


# ── Colors + log ────────────────────────────────────────────────
C = {
    "reset": "\033[0m", "dim": "\033[2m", "bold": "\033[1m",
    "red": "\033[91m", "green": "\033[92m", "yellow": "\033[93m",
    "blue": "\033[94m", "magenta": "\033[95m", "cyan": "\033[96m",
}
OP_COLORS = {
    "tmux-panes-update": "blue", "send-keys": "green", "poll": "cyan",
    "ack": "magenta", "create-session": "yellow", "create-window": "yellow",
    "create-pane": "yellow", "state": "dim",
}


def _ts(): return time.strftime("%H:%M:%S")


def log(level, op, msg, addr=""):
    color = C.get(OP_COLORS.get(op, "reset"), C["reset"])
    lvl = {"INF": C["green"], "WRN": C["yellow"], "ERR": C["red"]}.get(level, C["reset"])
    src = f" {C['dim']}← {addr}{C['reset']}" if addr else ""
    print(f"{C['dim']}{_ts()}{C['reset']} {lvl}{level}{C['reset']} "
          f"{color}{C['bold']}{op:>18}{C['reset']} {msg}{src}", flush=True)


def log_startup():
    print(f"""
{C['cyan']}{C['bold']}╔══════════════════════════════════════════╗
║         TCPUX — tmux command queue       ║
╚══════════════════════════════════════════╝{C['reset']}
  {C['green']}●{C['reset']} Host: {C['bold']}{HOST}{C['reset']}
  {C['green']}●{C['reset']} Port: {C['bold']}{PORT}{C['reset']}
  {C['green']}●{C['reset']} PID:  {C['bold']}{os.getpid()}{C['reset']}
  {C['dim']}  strict axiom mode — waiting for workers...{C['reset']}
""", flush=True)


# ── Helpers ─────────────────────────────────────────────────────

def _reject(code, hint, op, addr):
    log("WRN", op, f"{C['red']}reject {code}{C['reset']} {C['dim']}{hint}{C['reset']}", addr)
    return {"ok": False, "err_code": code, "hint": hint}


def _next_id():
    _NEXT_ID[0] += 1
    return _NEXT_ID[0]


def _enqueue(worker_id, op, **fields):
    cid = _next_id()
    cmd = {"id": cid, "op": op, **fields}
    QUEUE.setdefault(worker_id, deque()).append(cmd)
    DISPATCHED[cid] = {"worker": worker_id, "op": op, "result": None}
    return cmd


# ── Route ───────────────────────────────────────────────────────

async def route(msg, addr):
    op = msg.get("op", "")

    if op == "tmux-panes-update":
        worker_id = msg.get("worker")
        panes     = msg.get("panes", {})
        ok, code, hint = axioms.check_update(worker_id, panes)
        if not ok: return _reject(code, hint, op, addr)
        rec = STATE.setdefault(worker_id, {"panes": {}, "last_update": 0.0})
        prev = rec["panes"]
        merged = {}
        for pid, pst in panes.items():
            base = prev.get(pid, {"logs": []})
            base.update(pst)
            base.setdefault("logs", [])
            merged[pid] = base
        rec["panes"] = merged
        rec["last_update"] = time.time()
        log("INF", op, f"worker {C['bold']}{worker_id}{C['reset']} "
                       f"panes={C['cyan']}{len(merged)}{C['reset']}", addr)
        return {"ok": True, "panes_seen": len(merged)}

    if op == "send-keys":
        worker_id = msg.get("worker")
        pane_id   = msg.get("pane")
        cmd       = msg.get("cmd")
        ok, code, hint = axioms.check_send_keys(STATE, worker_id, pane_id, cmd)
        if not ok: return _reject(code, hint, op, addr)
        pane = STATE[worker_id]["panes"][pane_id]
        if pane.get("busy"):
            return _reject("SK5_PANE_BUSY",
                           f"pane {pane_id} is busy with {pane.get('cmd','?')}",
                           op, addr)
        c = _enqueue(worker_id, "send-keys", pane=pane_id, cmd=cmd)
        log("INF", op, f"{C['bold']}#{c['id']}{C['reset']} → "
                       f"{C['cyan']}{worker_id}{C['reset']}/{pane_id} "
                       f"{C['dim']}{cmd[:50]}{C['reset']}", addr)
        return {"ok": True, "id": c["id"]}

    if op == "create-session":
        worker_id = msg.get("worker")
        session   = msg.get("session")
        ok, code, hint = axioms.check_create_session(STATE, worker_id, session)
        if not ok: return _reject(code, hint, op, addr)
        c = _enqueue(worker_id, "create-session", session=session)
        log("INF", op, f"{C['bold']}#{c['id']}{C['reset']} {worker_id}/{session}", addr)
        return {"ok": True, "id": c["id"]}

    if op == "create-window":
        worker_id = msg.get("worker")
        session   = msg.get("session")
        window    = msg.get("window")
        ok, code, hint = axioms.check_create_window(STATE, worker_id, session, window)
        if not ok: return _reject(code, hint, op, addr)
        c = _enqueue(worker_id, "create-window", session=session, window=window)
        log("INF", op, f"{C['bold']}#{c['id']}{C['reset']} {worker_id}/{session}:{window}", addr)
        return {"ok": True, "id": c["id"]}

    if op == "create-pane":
        worker_id = msg.get("worker")
        pane_id   = msg.get("pane")
        ok, code, hint = axioms.check_create_pane(STATE, worker_id, pane_id)
        if not ok: return _reject(code, hint, op, addr)
        c = _enqueue(worker_id, "create-pane", pane=pane_id)
        log("INF", op, f"{C['bold']}#{c['id']}{C['reset']} {worker_id}/{pane_id}", addr)
        return {"ok": True, "id": c["id"]}

    if op == "poll":
        worker_id = msg.get("worker")
        ok, code, hint = axioms.check_poll(worker_id)
        if not ok: return _reject(code, hint, op, addr)
        q = QUEUE.get(worker_id)
        if not q:
            return {"ok": True, "cmd": None}
        c = q.popleft()
        log("INF", op, f"{C['bold']}#{c['id']}{C['reset']} → "
                       f"{C['cyan']}{worker_id}{C['reset']} {c['op']}", addr)
        return {"ok": True, "cmd": c}

    if op == "ack":
        cmd_id = msg.get("id")
        ok, code, hint = axioms.check_ack(DISPATCHED, cmd_id)
        if not ok: return _reject(code, hint, op, addr)
        DISPATCHED[cmd_id]["result"] = msg.get("result")
        status = "ok" if (msg.get("result") or {}).get("ok") else "err"
        color = C["green"] if status == "ok" else C["red"]
        log("INF", op, f"{C['bold']}#{cmd_id}{C['reset']} → {color}{status}{C['reset']}", addr)
        return {"ok": True}

    if op == "state":
        return {"ok": True, "state": STATE, "queue": {w: list(q) for w, q in QUEUE.items()}}

    if op == "status":
        cmd_id = msg.get("id")
        d = DISPATCHED.get(cmd_id)
        if not d: return _reject("ST1_UNKNOWN", f"cmd {cmd_id} unknown", op, addr)
        return {"ok": True, **d}

    return _reject("UNKNOWN_OP", f"unknown op {op!r}", op or "???", addr)


def _evt(kind, **kv):
    if kind == "connect":
        print(f"{C['dim']}{_ts()}{C['reset']} {C['green']}CON{C['reset']} "
              f"{C['dim']}← {kv.get('addr','?')}{C['reset']}", flush=True)
    else:
        print(f"{C['dim']}{_ts()}{C['reset']} {C['yellow']}DIS{C['reset']} "
              f"{C['dim']}← {kv.get('addr','?')}{C['reset']}", flush=True)


async def _main():
    log_startup()
    await serve(HOST, PORT, route, on_event=_evt)


if __name__ == "__main__":
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        print("\nshutting down")
