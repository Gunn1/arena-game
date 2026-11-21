"""Headless check: generate maps, then let random-input bots play whole matches."""
import os
import random
import sys
import tempfile

os.environ["SDL_VIDEODRIVER"] = "dummy"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pygame  # noqa: E402

from config import WIDTH, HEIGHT  # noqa: E402
from controls import ACTIONS  # noqa: E402
import math  # noqa: E402

from game import Game  # noqa: E402
from items import RECIPES  # noqa: E402
from player import Player  # noqa: E402
from world import World  # noqa: E402


class Bot:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.state = {a: False for a in ACTIONS}

    def read(self, pressed):
        for a in ACTIONS:
            if self.rng.random() < 0.08:
                self.state[a] = not self.state[a]
        return dict(self.state)


def check_maps():
    import time
    from config import COLS, FAIR_SPREAD
    from world import blocks_near, fill_ratio

    w = World()
    for players in (2, 3, 4):
        for seed in range(1, 301):
            w.generate(seed, players, mode="mirrored")
            near = [blocks_near(w.grid, col, ground) for col, ground in w.spawns]
            assert len(set(near)) == 1, f"unfair mirrored map: seed {seed}, {players}p, {near}"
        print(f"mirrored {players}p: 300 maps, every spawn identical")

    for players in (2, 3, 4):
        spreads, fills, start = [], [], time.time()
        for seed in range(1, 201):
            w.generate(seed, players, mode="random")
            assert len(w.spawns) == players
            xs = [c for c, _ in w.spawns]
            assert all(b - a >= COLS // (players + 1) for a, b in zip(xs, xs[1:])), f"spawns too close: {w.spawns}"
            for col, ground in w.spawns:
                assert w.solid(col, ground), "spawn must stand on a block"
                assert not w.solid(col, ground - 1) and not w.solid(col, ground - 2), "spawn needs headroom"
            spreads.append(w.spread)
            fills.append(fill_ratio(w.grid))
        ms = (time.time() - start) / 200 * 1000
        fair = sum(s <= FAIR_SPREAD for s in spreads) / len(spreads) * 100
        print(f"random {players}p: {fair:.0f}% of maps within {FAIR_SPREAD:.0%}, worst {max(spreads):.0%}, "
              f"avg fill {sum(fills) / len(fills):.0%}, {ms:.0f} ms per map")


def check_wall_jump():
    from config import PLAYER_W
    from player import Player
    from world import STONE

    class FakeGame:
        def __init__(self, world):
            self.world = world
            self.sounds = type("S", (), {"play": lambda *a, **k: None})()
            self.particles = type("P", (), {"burst": lambda *a, **k: None})()

        def player_in_tile(self, tx, ty):
            return False

    def blank_world():
        w = World()
        w.grid = [[0] * len(w.grid[0]) for _ in w.grid]
        for y in range(5, 34):
            w.grid[y][30] = STONE                # one tall wall
        return w

    idle = {a: False for a in ACTIONS}
    # 1. Falling next to the wall, holding into it, then pressing jump.
    w = blank_world()
    p = Player(0, None)
    p.spawn(0, 0)
    p.x, p.y, p.vy = 30 - PLAYER_W, 15.0, 5.0
    game = FakeGame(w)
    p.update(1 / 60, dict(idle, right=True), game)
    assert p.vy <= 4.0 + 1e-9, "wall slide should cap fall speed"
    p.update(1 / 60, dict(idle, right=True, jump=True), game)
    assert p.vy < 0, "wall jump should launch upward"
    start_x = p.x
    for _ in range(10):
        p.update(1 / 60, dict(idle, right=True), game)
    print(f"wall jump: launched up, kicked {start_x - p.x:.2f} tiles away from the wall")

    # 2. Can a player climb a single wall by spamming jump while holding into it?
    p.spawn(0, 0)
    p.x, p.y, p.vy = 30 - PLAYER_W, 25.0, 0.0
    lowest = highest = p.y
    for frame in range(60 * 4):
        p.update(1 / 60, dict(idle, right=True, jump=frame % 2 == 0), game)
        highest = min(highest, p.y)
    print(f"single-wall climb: started at row {lowest:.1f}, highest row reached {highest:.1f}")
    assert highest > lowest - 4, "a single wall should not be climbable"

    # 3. A chimney (two walls 2 tiles apart) should still be climbable by alternating.
    for y in range(5, 34):
        w.grid[y][27] = STONE
    p.spawn(0, 0)
    p.x, p.y, p.vy = 30 - PLAYER_W, 25.0, 0.0
    highest = p.y
    for frame in range(60 * 4):
        toward = "right" if p.facing > 0 else "left"     # a wall jump faces you at the other wall
        p.update(1 / 60, dict(idle, **{toward: True}, jump=frame % 2 == 0), game)
        highest = min(highest, p.y)
    # 4. Mouse aim: snaps to 8 directions and turns the player to face the mouse.
    p.spawn(0, 0)
    p.x, p.y = 10.0, 10.0
    cx, cy = p.centre()
    for (mx, my), want in [((cx + 5, cy), (1, 0)), ((cx + 4, cy - 4), (1, -1)), ((cx, cy + 3), (0, 1)),
                           ((cx - 6, cy + 1), (-1, 0)), ((cx - 3, cy - 3.5), (-1, -1))]:
        p.update(0, dict(idle, mouse=(mx, my), right=True), game)
        assert p.aim == want, (p.aim, want)
        if want[0]:
            assert p.facing == want[0], "should face the mouse even while walking the other way"
    print("mouse aim: 8-way snapping and facing OK")
    print(f"chimney climb: started at row 25.0, highest row reached {highest:.1f}")
    assert highest < 20, "alternating between two walls should climb"


def check_items():
    from config import PLAYER_H, BOMB_FUSE, ORE_RADIUS, ORE_MIN
    from items import ITEMS
    from world import STONE, DIRT, PLACED, COPPER, CRYSTAL, ORE_TILES

    idle = {a: False for a in ACTIONS}

    def setup():
        game = Game()
        game.sounds.muted = True
        game.players = [Player(0, None), Player(1, None)]
        w = game.world
        w.grid = [[0] * len(w.grid[0]) for _ in w.grid]
        for x in range(10, 50):
            w.grid[20][x] = STONE                 # a long floor at row 20
        for p, col in zip(game.players, (15, 40)):
            p.spawn(col, 20)
        return game, game.players[0], game.players[1]

    def run(game, frames, inp=None, who=None):
        for _ in range(frames):
            for p in game.players:
                if p.alive:
                    p.update(1 / 60, inp if (inp and p is who) else idle, game)
            game.update_projectiles(1 / 60)
            game.update_bombs(1 / 60)

    # Crafting: costs, stacking, and the 3-slot limit.
    game, p, q = setup()
    assert not p.craft("push"), "can't craft without materials"
    p.inv.update(dirt=9, stone=9, copper=9, crystal=9)
    assert p.craft("push") and p.inv["dirt"] == 6 and p.slots[0] == {"item": "push", "charges": 3}
    assert p.craft("push") and p.slots[0]["charges"] == 6, "same item should stack"
    p.craft("boost"); p.craft("laser")
    assert [s["item"] for s in p.slots] == ["push", "boost", "laser"]
    p.craft("grapple")
    assert p.slots[2]["item"] == "grapple", "full slots: replaces the one with fewest charges (laser, 2)"
    print("crafting: costs, stacking and slot replacement OK")

    # Crafting through the controls: hold craft, tap right to pick a recipe, let go.
    game, p, q = setup()
    p.inv.update(stone=3, copper=2)
    p.recipe = 0
    start_x = p.x
    hold = dict(idle, craft=True)
    presses = [hold] + [dict(hold, right=True), hold] * RECIPES.index("boost") + [idle]
    for inp in presses:
        p.update(1 / 60, inp, game)
    assert p.slots[0] and p.slots[0]["item"] == "boost" and not p.crafting, p.slots
    assert abs(p.x - start_x) < 0.01, "left/right should steer the menu, not walk, while crafting"
    # ...and the slot's own button uses it.
    p.update(1 / 60, dict(idle, item1=True), game)
    assert p.vy < -10 and p.slots[0]["charges"] == 2
    print("crafting via keys: hold, pick, release, then use with the slot key OK")

    # Mouse crafting: hovering a recipe picks it.
    game, p, q = setup()
    p.inv.update(dirt=5)
    _, rects = game.menu_layout(p)
    r = rects[RECIPES.index("push")]
    from config import CELL, HUD_H
    mouse = (r.centerx / CELL, (r.centery - HUD_H) / CELL)
    p.recipe = 3
    p.update(1 / 60, dict(idle, craft=True, mouse=mouse), game)
    p.update(1 / 60, dict(idle, mouse=mouse), game)
    assert p.slots[0] and p.slots[0]["item"] == "push", p.slots
    print("crafting via mouse: hover + release OK")

    # Mining gives the right material; ore takes two hits.
    game, p, q = setup()
    game.world.grid[19][16] = COPPER
    p.aim = (1, 0)
    p.facing = 1
    for _ in range(40):
        p.update(1 / 60, dict(idle, mine=True), game)
    assert p.inv["copper"] == 1, p.inv
    print("mining ore: copper collected OK")

    # Each item's effect.
    game, p, q = setup()
    assert game.use_item(p, "boost") and p.vy < -10
    game, p, q = setup()
    p.y -= 3                                     # in the air
    assert game.use_item(p, "platform")
    assert sum(game.world.grid[int(p.y + PLAYER_H)][x] == PLACED for x in range(10, 25)) == 5
    game, p, q = setup()
    game.world.grid[11][23] = STONE              # on the 45-degree line up-right of the player
    p.aim = (1, -1)
    start = p.centre()
    assert game.use_item(p, "grapple") and p.grapple
    run(game, 30)
    assert math.hypot(p.centre()[0] - 23.5, p.centre()[1] - 11.5) < math.hypot(start[0] - 23.5, start[1] - 11.5) - 4
    game, p, q = setup()
    p.aim = (0, -1)
    assert not game.use_item(p, "grapple"), "grapple into empty sky should not spend a charge"
    game, p, q = setup()
    q.x = p.x + 2.5
    p.aim, p.facing = (1, 0), 1
    start_x = q.x
    game.use_item(p, "push")
    run(game, 40)
    assert q.x > start_x + 2.5, "push should knock the other player away"
    game, p, q = setup()
    before = game.world.block_count()
    p.aim = (1, 0)
    game.use_item(p, "laser")
    p.aim = (0, 1)
    game.use_item(p, "laser")
    assert game.world.block_count() < before
    game, p, q = setup()
    q.x = p.x + 2
    before = game.world.block_count()
    p.aim = (0, 1)
    game.use_item(p, "bomb")
    run(game, int(BOMB_FUSE * 60) + 5)
    assert game.world.block_count() <= before - 4, "bomb should blow a hole"
    assert abs(q.kvx) > 1 or q.y < 18, "bomb should fling nearby players"
    print("items: boost, platform, grapple (hit + miss), push, laser, bomb OK")

    # Ore fairness on random maps.
    w = World()
    for players in (2, 3, 4):
        for seed in range(1, 51):
            w.generate(seed, players)
            for name, tile in ORE_TILES.items():
                counts = [sum(w.get(x, y) == tile for y in range(r - ORE_RADIUS, r + ORE_RADIUS + 1)
                              for x in range(c - ORE_RADIUS, c + ORE_RADIUS + 1)) for c, r in w.spawns]
                assert min(counts) >= ORE_MIN[name], (seed, players, name, counts)
    print("ore: every spawn has at least the minimum copper and crystal nearby")


def play_matches(screen):
    pygame.joystick.init()
    for players in (2, 3, 4):
        game = Game()
        game.joysticks = [None] * 2            # pretend controllers exist so 3-4 player starts
        game.start_match(players)
        for p in game.players:
            p.controls = Bot(p.index + players * 10)
        frames, rounds = 0, set()
        while game.state != "match_over" and frames < 60 * 60 * 15:
            game.update(1 / 60, None)
            rounds.add(game.round)
            frames += 1
            if frames == 60 * 8:
                game.draw(screen)
                pygame.image.save(screen, os.path.join(tempfile.gettempdir(), f"arena_shot_{players}p.png"))
        assert game.state == "match_over", f"{players}p match never ended"
        print(f"{players} players: match over after {len(rounds)} rounds, {frames / 60:.0f}s -> {game.message}")
        game.draw(screen)


if __name__ == "__main__":
    pygame.init()
    screen = pygame.display.set_mode((WIDTH, HEIGHT))
    check_maps()
    check_wall_jump()
    check_items()
    play_matches(screen)
    print("all good")
