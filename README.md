# Arena (working title)

Fast 2D arena game. Mine blocks and ore, craft items, and survive a map that crumbles under you.
Fall out of the map (bottom, left or right) and you're out. Last one standing wins the round; first to 3 wins the match.

**Download (Windows / Linux):** https://github.com/Gunn1/arena-game/releases/latest

**Play in your browser:** https://gunn1.github.io/arena-game/ (local games and joining servers; browsers can't host)

Made with [Godot 4.7](https://godotengine.org) in `godot/`. The original Python/pygame prototype is in `prototype-python/` as a reference.

## Online play

One player hosts and runs the game; everyone else joins and sends their inputs (WebSockets, port 7777).

1. Host: run the desktop version, press **H**. The lobby shows your addresses.
2. Friends: press **J**, type the host's address, press Enter. Use Tailscale if you can: no port forwarding, and the host's firewall already trusts it.
3. Host presses **Enter** to start (2-4 players).

Dedicated server (no player on it, e.g. on a home server):

    godot --headless --path godot -- --server --port 7777

Any connected player can press Enter to start a dedicated server's match.

Browsers can join, but a page served over https (like GitHub Pages) can only connect to a `wss://` server, so for browser players the server needs TLS in front of it (for example a Cloudflare Tunnel). Type the full `wss://...` address on the join screen.

There's no lag compensation yet: joiners feel their ping on their own movement.

## Controls

| | Move | Jump | Aim | Mine | Place | Items (slot 1/2/3) | Craft |
|---|---|---|---|---|---|---|---|
| Keyboard + mouse | A / D | W or Space (tap = short hop) | mouse picks the block within reach | hold left-click (click a player to hit) | right-click | Q / E / R | F |
| Local P2 | J / L | I | K = down | hold U | O | 7 / 8 / 9 | H |
| Controller | left stick / d-pad | A | right stick | hold RT | LT | X / Y / B | RB |

- **Fighting:** the mine button hits a player in front of you. Each hit adds damage %; the higher it is, the farther hits launch you. Fall out within 4 s of a hit and the hitter gets the KO.
- **The zone:** the arena crumbles from both edges toward the middle (about 50 s to close).
- **Crafting:** one press crafts the most valuable item you can afford; your HUD shows what it'll make (or what you still need).
- **Wall jump:** jump while touching a wall in the air; not off the same side twice in a row.
- **Local games:** 2/3/4 on the title screen. P2 uses the right side of the keyboard unless a controller is plugged in; P3 and P4 need controllers.
- M = mute, Esc = back.

## Items

| Item | Cost | Uses | Does |
|---|---|---|---|
| Push Wand | 3 dirt | 3 | knocks a player away |
| Rocket Boost | 1 stone, 1 copper | 3 | blast upward, works mid-air |
| Platform | 4 dirt, 1 copper | 1 | 5 blocks under your feet |
| Grapple | 2 stone, 1 copper | 3 | pulls you to the block you aim at |
| Bomb | 1 stone, 1 copper, 1 crystal | 2 | blows a hole, flings players (you too) |
| Laser | 2 stone, 1 crystal | 2 | cuts a 10-block line |

Dirt and stone share a 15-block carry limit. Copper (orange specks) and crystal (cyan, deeper) are ores; every spawn gets at least 2 copper within 4 tiles and 1 crystal within 6, the same for everyone.

## Working on it

- Open `godot/project.godot` in Godot 4.7.
- `godot/scripts/config.gd`: every tunable number. `items.gd`: item costs, uses, cooldowns.
- `world.gd` map + crumbling, `player.gd` movement/mining/crafting, `sim.gd` rounds + items + snapshots, `main.gd` screens, input, drawing, networking, `sfx.gd` sounds made in code.
- Tests: `godot --headless --path godot -s tests/test_sim.gd` (rules) and `godot/tests/net_test.sh` (online).
- Every push to `main` runs the tests and publishes the web version (`.github/workflows/build.yml`).
- New download: `git tag v0.2.0 && git push origin v0.2.0` builds Windows + Linux and makes a release.
