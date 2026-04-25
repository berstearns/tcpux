# Deploy: client

A laptop install. Talks to a running queue. Pre-req: your public IP must
be on the cloud firewall *and* on the tcpux allowlist.

```bash
git clone https://github.com/berstearns/tcpux.git ~/tcpux-client
cd ~/tcpux-client

rclone copy <rclone-deploy-path>/client.env deploy/
mv deploy/client.env deploy/.env
chmod 600 deploy/.env

./tcpux ls                 # workers + their panes (idle/busy)
./tcpux shortcut ls        # registered shortcuts
```

Send-keys, two equivalent forms:

```bash
./tcpux -w <worker> -p <session:window:pane> -c '<cmd>'
./tcpux -s <shortcut-name> -c '<cmd>'
```

Manage shortcuts:

```bash
./tcpux shortcut set <name> -w <worker> -p <session:window:pane> [--force]
./tcpux shortcut del <name>
```

Allowlist admin (requires the admin token in `.env`):

```bash
./tcpux allow <ip>
./tcpux block <ip>
./tcpux get
```
