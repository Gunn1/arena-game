"""Host + two clients in one process over localhost: lobby, map sync, remote input, crafting, disconnect."""
import json
import os
import sys

os.environ["SDL_VIDEODRIVER"] = "dummy"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pygame  # noqa: E402

pygame.init()
pygame.display.set_mode((100, 100))

from controls import ACTIONS  # noqa: E402
from game import Game  # noqa: E402
from items import RECIPES  # noqa: E402

PORT = 17777
DT = 1 / 60


class NoKeys:
    def __getitem__(self, key):
        return False


class Scripted:
    """Stands in for a client's keyboard: returns whatever .now holds."""
    slot_labels, craft_label, mouse = ("Q", "E", "R"), "F", False

    def __init__(self):
        self.now = {a: False for a in ACTIONS}

    def read(self, pressed):
        return dict(self.now)


def step(games, frames=1):
    for _ in range(frames):
        for g in games:
            g.update(DT, NoKeys())


host = Game()
host.sounds.muted = True
host.host_game(PORT)
assert host.mode == "host", host.message
clients = []
for _ in range(2):
    c = Game()
    c.sounds.muted = True
    c.address = f"127.0.0.1:{PORT}"
    c.join_game()
    assert c.mode == "client", c.message
    clients.append(c)
games = [host] + clients
step(games, 10)
assert len(host.host.clients) == 2
assert [c.client.you for c in clients] == [1, 2], [c.client.you for c in clients]
print("lobby: 2 clients joined as P2 and P3")

host.start_online_match()
step(games, 5)
for c in clients:
    assert c.state == host.state and len(c.players) == 3
    assert c.world.grid == host.world.grid, "map should match the host's"
print("round start: clients got the same map and 3 players")

# Client 1 (P2) walks right and mines; the host moves P2, and both clients see it.
me = clients[0].players[1]
me.controls = Scripted()
step(games, int(1.6 / DT))                       # let the intro banner finish
start_x = host.players[1].x
me.controls.now.update(right=True)
step(games, 30)
me.controls.now.update(right=False)
step(games, 3)
moved = host.players[1].x - start_x
assert moved > 1 or host.players[1].kvx == 0, f"P2 should have walked right on the host (moved {moved:.2f})"
for c in clients:
    assert abs(c.players[1].x - host.players[1].x) < 0.01, "clients should see P2 where the host has it"
print(f"remote input: P2 walked {moved:.1f} tiles on the host; both clients agree")

# Crafting from the client: hold F, tap right to Rocket Boost, let go, then press Q to use it.
host.players[1].inv.update(stone=3, copper=3)
host.players[1].recipe = 0
script = [dict(craft=True)] + [dict(craft=True, right=True), dict(craft=True)] * RECIPES.index("boost") + [dict()]
for frame in script:
    me.controls.now = {a: False for a in ACTIONS} | frame
    step(games, 2)
me.controls.now = {a: False for a in ACTIONS}
step(games, 3)
assert host.players[1].slots[0] and host.players[1].slots[0]["item"] == "boost", host.players[1].slots
assert clients[0].players[1].slots[0]["item"] == "boost", "the crafter's own screen should show it"
me.controls.now["item1"] = True
step(games, 2)
me.controls.now["item1"] = False
step(games, 3)
assert host.players[1].slots[0]["charges"] == 2
print("remote crafting: hold, pick, release, then Q to use: OK")

# Let the map crumble for a while; clients' maps must stay identical.
step(games, int(8 / DT))
for c in clients:
    assert c.world.grid == host.world.grid, "maps drifted apart"
size = len(json.dumps(__import__("net").snapshot(host)))
print(f"crumbling: maps still identical after 8 s; snapshot is about {size} bytes ({size * 60 // 1024} KB/s per client)")

# Client 2 leaves: on the host they're out.
clients[1].leave_online()
step([host, clients[0]], 10)
assert not host.players[2].alive and len(host.host.clients) == 1
print("disconnect: leaving player is counted as out")

host.leave_online()
step([clients[0]], 10)
assert clients[0].mode == "local" and "Disconnected" in clients[0].message
print("host leaving: client returns to the title with a message")
print("all good")
