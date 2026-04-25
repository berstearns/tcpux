# Deploy: worker

Each worker process owns one user's tmux server on one host. The deploy
lands in a `tcpux-worker` session on the target. Pick a unique
`WORKER_NAME` per worker.

## Variant A — worker as root on the queue's host

```bash
git clone https://github.com/berstearns/tcpux.git ~/tcpux
cd ~/tcpux

rclone copy <rclone-deploy-path>/droplet.env deploy/
mv deploy/droplet.env deploy/.env
chmod 600 deploy/.env

./deploy.sh -c deploy -t worker -i root@<droplet-ip>
```

## Variant B — worker as a non-root user (own tmux server)

The repo ships `deploy-claude-runner/` as a per-role template. Clone it
for the new user and customize.

```bash
git clone https://github.com/berstearns/tcpux.git ~/tcpux
cd ~/tcpux

cp -r deploy-claude-runner deploy-<user>
# edit deploy-<user>/.env:
#   WORKER_NAME=<unique>
#   REMOTE_ROOT=/home/<user>/tcpux
#   TCPUX_PORT=<from rclone client.env>
#   WORKER_PANE_MAIN=tcpux-worker-main-<user>
#   WORKER_PANE_OBS=tcpux-worker-obs-<user>

./deploy.sh -c deploy-<user> -t worker -i <user>@<host>
```

Pre-req for Variant B: the target user can SSH with the password file
at `~/.do-pass` (or `~/.do-pass-<user>`); see the `do-ssh-pass` script.

## Verify

```bash
# from a client
./tcpux ls                       # the new worker should appear
./tcpux ls <worker-name>         # filter
```
