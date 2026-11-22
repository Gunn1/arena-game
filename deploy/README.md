# Hosting a public Arena server

This runs the headless dedicated server in a Proxmox LXC and puts a Cloudflare Tunnel in front of it, so anyone (including browser players on https://gunn1.github.io/arena-game/) can join at `wss://arena.example.com`. Replace `arena.example.com` with your own hostname everywhere below.

```
player --wss://--> Cloudflare edge --tunnel--> cloudflared (in the LXC) --ws://localhost:7777--> arena-server
```

The tunnel only makes outbound connections, so no router port forwarding is needed and your home IP isn't published.

Files here:

| File | What it is |
|---|---|
| `install.sh` | installs or updates the server (run on the LXC as root) |
| `arena-server.service` | hardened systemd unit, user `arena`, binary in `/opt/arena` |
| `cloudflared-config.example.yml` | tunnel config: hostname -> `http://localhost:7777`, everything else 404 |

The server binary comes from the GitHub release asset `arena-server-linux.zip` (built by `.github/workflows/build.yml` when a `v*` tag is pushed). Make at least one release after this was added, or the download will 404.

## 1. Create the LXC

In Proxmox: **Create CT**

- **Unprivileged container: yes** (the default; keep it).
- Template: Debian 12 or 13 (any Debian/Ubuntu with glibc 2.28+ works).
- 1 core, 512 MB RAM, 4 GB disk is plenty (the server uses about 100 MB RAM).
- Network: DHCP or a static IP on your LAN.

Start it, open its console, and update it:

    apt update && apt full-upgrade -y

## 2. Install the game server

As root in the LXC:

    curl -fsSLO https://raw.githubusercontent.com/Gunn1/arena-game/main/deploy/install.sh
    less install.sh          # read it first
    bash install.sh

It creates the `arena` user, puts the binary in `/opt/arena`, installs `/etc/systemd/system/arena-server.service`, and starts it. Check:

    systemctl status arena-server
    journalctl -u arena-server -f     # should show "Dedicated server listening on port 7777"

## 3. Keep port 7777 off the LAN

The game can't be told to listen on 127.0.0.1 only; it listens on all interfaces. Only cloudflared (same container, via localhost) should reach it.

- Don't port-forward 7777 on your router.
- Block it on the LXC. Either enable the Proxmox firewall for the container (Datacenter and CT **Firewall -> Options**, input policy DROP, add an ACCEPT rule for SSH from your LAN if you use it), or use nftables inside the LXC:

      apt install -y nftables

  then add this to the end of `/etc/nftables.conf`:

      table inet arena {
          chain input {
              type filter hook input priority 0; policy accept;
              iifname != "lo" tcp dport 7777 drop
          }
      }

  and run `systemctl enable --now nftables`.

From another machine on the LAN, `curl -m 3 http://<lxc-ip>:7777` should now time out.

## 4. Install cloudflared

As root in the LXC (Cloudflare's apt repo):

    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
        > /etc/apt/sources.list.d/cloudflared.list
    apt update && apt install -y cloudflared

## 5. Create the tunnel

You need a domain whose DNS is on Cloudflare.

    cloudflared tunnel login                                    # opens a URL; pick your domain
    cloudflared tunnel create arena                             # prints the tunnel UUID, writes ~/.cloudflared/<UUID>.json
    cloudflared tunnel route dns arena arena.example.com        # creates the CNAME

## 6. Configure it

    mkdir -p /etc/cloudflared
    cp ~/.cloudflared/<UUID>.json /etc/cloudflared/
    chmod 600 /etc/cloudflared/<UUID>.json
    curl -fsSL https://raw.githubusercontent.com/Gunn1/arena-game/main/deploy/cloudflared-config.example.yml \
        -o /etc/cloudflared/config.yml

Edit `/etc/cloudflared/config.yml`: put the UUID in both places and your hostname in `hostname:`. Check it:

    cloudflared tunnel ingress validate
    cloudflared tunnel ingress rule https://arena.example.com    # should match the localhost:7777 rule

The `<UUID>.json` file is the tunnel's secret. Don't commit it or paste it anywhere.

## 7. Run cloudflared as a service

    cloudflared service install
    systemctl enable --now cloudflared
    systemctl status cloudflared

Test the whole path from any machine (expect `HTTP/1.1 101 Switching Protocols`):

    curl -i -N -m 5 -H "Connection: Upgrade" -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        https://arena.example.com/

## How players join

Press **J** on the title screen and type the full address, including the scheme:

    wss://arena.example.com

Works from the browser version and the desktop builds. Typing just `arena.example.com` won't work: without a scheme the game adds `:7777`, which the tunnel doesn't serve. Any connected player presses Enter to start (2-4 players).

## Updating

Push a new `v*` tag so a release with `arena-server-linux.zip` is built, then on the LXC:

    bash install.sh

It downloads the latest release, replaces the binary, and restarts the service (players in a match get disconnected). Pin a version with `ARENA_VERSION=v0.3.0 bash install.sh`.

## Security notes

- This is a public endpoint with no login: anyone with the address can join. One server runs one game, max 4 players; a 5th joiner, or anyone joining mid-match, is disconnected. That also means 4 strangers can fill the lobby and lock everyone else out until they leave.
- The server process only runs the game. It runs as the unprivileged `arena` user with no capabilities, a read-only filesystem except `/var/lib/arena`, and a 512 MB memory cap (see `arena-server.service`).
- Keep the LXC unprivileged and patched (`apt update && apt full-upgrade`, or enable `unattended-upgrades`). Update cloudflared the same way.
- Cloudflare sits in front, so players see Cloudflare's IPs, not your home IP. It does not protect against someone joining and griefing a match; if that becomes a problem, add Cloudflare rate limiting or Access rules for the hostname.
- The release zip has no published checksum, so `install.sh` trusts GitHub's HTTPS download.

## Troubleshooting

- `arena-server` exits with status 226/NAMESPACE or similar: some sandboxing options in the unit may not be allowed in your container. Comment out the `Protect*`/`Private*` lines one at a time in `/etc/systemd/system/arena-server.service`, then `systemctl daemon-reload && systemctl restart arena-server`. (The unit is overwritten when you rerun `install.sh`.)
- Browser says it can't connect: check you typed `wss://`, that `cloudflared` is running, and the curl test in step 7.


## Automatic updates

`install.sh` also installs `arena-update.timer`. Every 5 minutes it checks the latest GitHub release and, if it's newer than `/opt/arena/VERSION` **and nobody is connected**, reinstalls the server. Online play needs the same version on both ends, so this keeps the server in step with the web version and the downloads. Check it with `systemctl list-timers arena-update.timer` and `journalctl -u arena-update`.
