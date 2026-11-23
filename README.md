# Arena (working title)

Fast 2D arena game. Mine blocks and ore, craft special blocks, and survive a map that crumbles under you.
Fall out of the map (bottom, left or right) and you're out. Last one standing wins the round; first to 3 wins the match.

**Download (Windows / Linux):** https://github.com/Gunn1/arena-game/releases/latest

**Play in your browser:** https://gunn1.github.io/arena-game/ (local games and joining servers; browsers can't host)

Made with [Godot 4.7](https://godotengine.org) in `godot/`. The original Python/pygame prototype is in `prototype-python/` as a reference.

## Online play

One player hosts and runs the game; everyone else joins and sends their inputs (WebSockets, port 7777).

**Quickest:** press **Enter** on the title screen to join the public server (arena.tylergunn.me). Everyone in its lobby can press Enter to start once 2+ are in. If a match is already running and there's room, you join it and spawn next round.

Or play with friends on your own machine:

1. Host: run the desktop version, press **H**. The lobby shows your addresses.
2. Friends: press **J**, type the host's address, press Enter. Use Tailscale if you can: no port forwarding, and the host's firewall already trusts it.
3. Host presses **Enter** to start (2-4 players).

Dedicated server (no player on it, e.g. on a home server):

    godot --headless --path godot -- --server --port 7777

Any connected player can press Enter to start a dedicated server's match.

Browsers can join, but a page served over https (like GitHub Pages) can only connect to a `wss://` server, so for browser players the server needs TLS in front of it (for example a Cloudflare Tunnel). Type the full `wss://...` address on the join screen.

There's no lag compensation yet: joiners feel their ping on their own movement.

## Hosting a public server

To run an always-on server that browser players can join at `wss://arena.<your-domain>`, see [`deploy/README.md`](deploy/README.md): the headless server build (`arena-server-linux.zip` on each release) runs as a hardened systemd service in a Proxmox LXC, with a Cloudflare Tunnel in front for TLS (no port forwarding, home IP stays hidden).

## Controls

| | Move | Jump | Aim | Mine | Place | Items (slot 1/2/3) | Craft |
|---|---|---|---|---|---|---|---|
| Keyboard + mouse | A / D | W or Space (tap = short hop) | mouse picks the block within reach | hold left-click (click a player to hit) | right-click | Q / E / R | F |
| Local P2 | J / L | I | K = down | hold U | O | 7 / 8 / 9 | H |
| Controller | left stick / d-pad | A | right stick | hold RT | LT | X / Y / B | RB |

- **Fighting:** click to swing. Aim assist: it hits anyone within reach roughly where you aim (70° either way), and a click during cooldown still swings when it's ready. Each hit adds damage %; the higher it is, the farther hits launch you. Fall out within 4 s of a hit and the hitter gets the KO, plus half your copper and crystal.
- **The zone:** the arena crumbles from both edges toward the middle (starts after 10 s, about 90 s to close).
- **Crafting:** tap craft to make the most valuable special block you can afford (your HUD shows which). Hold craft to open the menu: pick with the mouse, wheel, or left/right, and let go to craft it. Item keys place blocks up to 4.5 tiles away.
- **Wall jump:** jump while a wall is beside your upper body in the air; not off the same side twice in a row. Just above the floor, jump waits for the landing instead.
- **Local games:** 2/3/4 on the title screen. P2 uses the right side of the keyboard unless a controller is plugged in; P3 and P4 need controllers.
- M = mute, N = music on/off, Esc = back.

## Biomes and arenas

Every round picks a biome and an arena shape (shown in the round banner).

| Biome | Special blocks |
|---|---|
| Meadow | the classic look |
| Desert | sand on top that falls when nothing holds it up |
| Tundra | ice: you speed up and slide 4x slower |
| Mushroom | slime pads: land hard and bounce back up |
| Volcano | lava pools: touching them launches you up and burns 12% |

Any biome can have TNT: mine it (or blow it up) and it explodes a second later, credited to whoever set it off. Shapes: islands, mountain, towers with bridges, caves.

## Round events

After the first round of a match, each round has a 40% chance of an event (shown in the round banner):

| Event | Does |
|---|---|
| Low Gravity | floaty jumps, and hits launch you farther |
| Sudden Death | everyone starts at 100% |
| Fast Zone | the edges close twice as fast |
| Gold Rush | 3x the ore |
| Meteor Shower | lit TNT falls from the sky every few seconds |

## Special blocks

Crafted into your 3 slots, placed with the item keys. Fans, magnets, bounce pads, spikes, bumpers, glue and springs work on everyone, you included; mines, turrets and trapdoors ignore whoever placed them.

| Block | Cost | Blocks | Does |
|---|---|---|---|
| Ladder | 2 dirt | 4 | climb it (up/jump climbs, down slides) |
| Ice | 1 dirt, 1 stone | 2 | slippery |
| Fake Block | 2 dirt, 1 stone | 3 | looks like dirt, you fall through |
| Fan | 3 dirt | 2 | blows players away; placed above/below you it's an updraft |
| Glue | 2 dirt, 1 copper | 3 | slow walking, weak jumps |
| Bounce Pad | 2 dirt, 1 copper | 3 | launches anyone who steps on it ~5 tiles up |
| Trapdoor | 2 stone, 1 copper | 3 | drops away under enemies |
| Steel | 3 stone, 1 copper | 4 | slow to mine, bombproof |
| Magnet | 1 stone, 2 copper | 2 | pulls everyone within 6 tiles toward it |
| Spikes | 2 stone, 1 crystal | 3 | hurts and throws anyone who touches them |
| Bumper | 2 stone, 2 copper | 2 | flings back anyone who runs into it |
| Healing Spring | 1 copper, 1 crystal | 1 | heals anyone nearby, 50% total |
| Mine | 1 stone, 1 copper, 1 crystal | 2 | TNT that blows when an enemy gets close |
| Turret | 2 stone, 1 copper, 1 crystal | 1 | shoots enemies within 12 tiles; breaks after 8 shots |

Dirt and stone share a 15-block carry limit; when full, mined stone replaces a dirt. Copper (orange specks) and crystal (cyan, deeper) are ores; every spawn gets at least 2 copper within 4 tiles and 1 crystal within 6, the same for everyone.

## Working on it

- Open `godot/project.godot` in Godot 4.7.
- `godot/scripts/config.gd`: every tunable number. `items.gd`: item costs, uses, cooldowns.
- `world.gd` map + crumbling, `player.gd` movement/mining/crafting, `sim.gd` rounds + items + snapshots, `main.gd` screens, input, drawing, networking, `sfx.gd` sounds made in code.
- Tests: `godot --headless --path godot -s tests/test_sim.gd` (rules) and `godot/tests/net_test.sh` (online).
- Every push to `main` runs the tests and publishes the web version (`.github/workflows/build.yml`).
- New release: bump `GAME_VERSION` in `godot/scripts/config.gd`, then `git tag vX.Y.Z && git push origin vX.Y.Z` (CI checks they match). Online play requires the exact same version on both ends; a mismatched copy can't connect.
