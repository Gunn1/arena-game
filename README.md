# Arena (working title)

Fast 2D arena game. Mine blocks, place only what you mined, and survive a map that crumbles under you.
Fall out of the map (bottom, left or right) and you're out. Last one standing wins the round; first to 3 wins the match.

## Get it and run it

Needs Python 3.10+.

    git clone https://github.com/Gunn1/arena-game.git
    cd arena-game
    python -m venv .venv

Linux / macOS:

    .venv/bin/pip install -r requirements.txt
    .venv/bin/python main.py

Windows (PowerShell):

    .venv\Scripts\pip install -r requirements.txt
    .venv\Scripts\python main.py

To update later: `git pull`. Everyone in an online game must be on the same version.

Test (headless): `.venv/bin/python tests/smoke_test.py`

## Online play

Every player needs this folder (same version) and Python with pygame-ce.

1. Host: press **H** on the title screen. The lobby shows your Tailscale and LAN addresses.
2. Friends: press **J**, type the host's address, press Enter.
3. Host presses **Enter** to start once everyone has joined (up to 4 players).

The host runs the game; everyone else sends their inputs and sees what the host sends (TCP port 7777, set by `NET_PORT` in `config.py`). Use Tailscale: on the host PC, `tailscale0` is in firewalld's trusted zone, so no firewall changes are needed. LAN joins would need port 7777 opened in the public zone. There's no lag compensation yet, so joiners feel their ping on their own movement.

Online, everyone uses the P1 controls below on their own PC. `2`/`3`/`4` on the title screen still starts a local game on one PC.

Test: `.venv/bin/python tests/net_test.py` (host + 2 clients over localhost).

## Controls

| | Move | Jump | Aim | Mine | Place | Items (slot 1/2/3) | Craft |
|---|---|---|---|---|---|---|---|
| P1 | A / D | W or Space | mouse | left-click | right-click | Q / E / R | hold F |
| P2 | J / L | I | K = down | U | O | 7 / 8 / 9 | hold H |
| Controller | left stick / d-pad | A | right stick | RT | LT | X / Y / B | hold RB |

- **Crafting:** hold the craft key to open the menu, pick a recipe (hover with the mouse, scroll wheel, or left/right), let go to craft it. While a keyboard/controller player holds craft, left/right steer the menu instead of walking.
- **Items:** 3 slots, each used by its own button. Crafting an item you already hold adds charges; with all 3 slots full, it replaces the slot with the fewest charges.
- **Controllers** are used automatically: plug one in and P2 gets it; P3 and P4 need one each.
- Wall jump: press jump while touching a wall in the air. You can't wall jump off the same side twice in a row.
- Set `MOUSE_PLAYER = None` in `config.py` for keyboard-only P1 (mine Q, place E, items 1/2/3).
- M = mute, Esc = menu, Enter after a match = rematch.

## Items

Mine dirt and stone (they share the 15-block carry limit) and ore: copper (orange specks) and crystal (cyan, deeper down).

| Item | Cost | Uses | Does |
|---|---|---|---|
| Push Wand | 3 dirt | 3 | knocks a player away |
| Rocket Boost | 1 stone, 1 copper | 3 | blast upward, works mid-air |
| Platform | 4 dirt, 1 copper | 1 | 5 blocks under your feet |
| Grapple | 2 stone, 1 copper | 3 | pulls you to the block you aim at |
| Bomb | 1 stone, 1 copper, 1 crystal | 2 | blows a hole, flings players (you too) |
| Laser | 2 stone, 1 crystal | 2 | cuts a 10-block line |

Costs, uses and cooldowns are in `items.py`; strengths are in `config.py`.

## Files

- `config.py` - every tunable number (speeds, crumble rate, cooldowns, rounds to win)
- `world.py` - map generation (random with fair spawn picking, or mirrored via `MAP_MODE`) and crumbling
- `player.py` - movement, collision, mining and placing
- `game.py` - rounds, abilities, drawing
- `items.py` - item recipes, uses, cooldowns and icons
- `controls.py` - keyboard, mouse and controller input
- `net.py` - online play: host, client, snapshots
- `effects.py` - particles and sound effects (synthesized in code, no asset files)
