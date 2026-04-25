# Deploy: queue

The queue server + allowlist admin live in a single tmux session
(`tcpux-queue`) on the target host. Pre-req: SSH access (root) and the
target's IP+ports are open on whatever cloud firewall fronts it.

```bash
git clone https://github.com/berstearns/tcpux.git ~/tcpux
cd ~/tcpux

rclone copy <rclone-deploy-path>/droplet.env deploy/
mv deploy/droplet.env deploy/.env
chmod 600 deploy/.env

# optional: seed the allowlist instead of starting empty
rclone copy <rclone-deploy-path>/allowlist.seed.json ./

./deploy.sh -c deploy -t queue -i root@<droplet-ip>
```

After it finishes:

```bash
ssh root@<droplet-ip> 'tmux list-sessions | grep tcpux-queue'
```

Should show one session with three panes (`tcpux-queue-server`,
`tcpux-queue-admin`, `tcpux-queue-state`).
