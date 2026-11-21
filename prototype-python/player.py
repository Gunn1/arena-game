import math

from config import (COLS, ROWS, PLAYER_W, PLAYER_H, GRAVITY, JUMP_SPEED, MOVE_SPEED, MAX_FALL,
                    COYOTE, WALL_JUMP_SPEED, WALL_KICK, WALL_SLIDE_SPEED, WALL_COYOTE, WALL_LOCK,
                    MINE_COOLDOWN, PLACE_COOLDOWN, CARRY_LIMIT, ORE_LIMIT, SLOTS, KNOCK_DECAY,
                    GRAPPLE_SPEED, PLAYER_COLORS)
from items import ITEMS, RECIPES, MATERIALS
from world import PLACED, DROPS

# Mouse angle -> 8-way aim, in 45 degree steps starting from "right" (y points down).
OCTANTS = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]


class Player:
    def __init__(self, index, controls):
        self.index = index
        self.controls = controls
        self.color = PLAYER_COLORS[index]
        self.wins = 0
        self.spawn(0, 0)

    def spawn(self, col, ground_row):
        self.x = col + 0.5 - PLAYER_W / 2       # top-left corner, in tiles
        self.y = ground_row - PLAYER_H
        self.vy = 0.0
        self.kvx = 0.0                          # sideways speed from knockback, wall kicks and the grapple
        self.on_ground = False
        self.coyote = 0.0
        self.wall_coyote = 0.0                  # grace time to wall jump after leaving a wall
        self.wall_dir = 0                       # -1 = wall on the left, 1 = on the right
        self.last_wall = 0                      # side of the last wall jump; can't repeat it until landing
        self.wall_lock = 0.0                    # brief time after a wall jump where walking is ignored
        self.facing = 1 if col < COLS / 2 else -1
        self.aim = (self.facing, 0)
        self.inv = {m: 0 for m in MATERIALS}
        self.slots = [None] * SLOTS             # each: {"item": key, "charges": n}
        self.crafting = False                   # crafting menu open (while the craft button is held)
        self.recipe = getattr(self, "recipe", 0)   # highlighted recipe; remembered between rounds
        self.last_used = None                   # slot index last used, for the HUD flash
        self.grapple = None                     # (x, y, time left) while being pulled
        self.mine_cd = self.place_cd = self.item_cd = 0.0
        self.held = {}                          # last frame's input, for "just pressed"
        self.alive = True

    def pressed(self, inp, action):
        return inp.get(action) and not self.held.get(action)

    # --- inventory and crafting ---------------------------------------------------

    @property
    def blocks(self):
        return self.inv["dirt"] + self.inv["stone"]

    def collect(self, tile):
        material = DROPS.get(tile)
        if material in ("dirt", "stone"):
            if self.blocks < CARRY_LIMIT:
                self.inv[material] += 1
        elif material:
            self.inv[material] = min(ORE_LIMIT, self.inv[material] + 1)

    def can_afford(self, key):
        return all(self.inv[m] >= n for m, n in ITEMS[key]["cost"].items())

    def craft(self, key):
        """Pay for an item and put it in a slot: stacks onto the same item, else the first
        empty slot, else replaces the slot with the fewest charges. Returns True if crafted."""
        if not self.can_afford(key):
            return False
        for m, n in ITEMS[key]["cost"].items():
            self.inv[m] -= n
        same = next((i for i, s in enumerate(self.slots) if s and s["item"] == key), None)
        empty = next((i for i, s in enumerate(self.slots) if s is None), None)
        if same is not None:
            self.slots[same]["charges"] += ITEMS[key]["charges"]
        else:
            if empty is None:
                empty = min(range(SLOTS), key=lambda i: self.slots[i]["charges"])
            self.slots[empty] = {"item": key, "charges": ITEMS[key]["charges"]}
        return True

    def cycle_recipe(self, step=1):
        self.recipe = (self.recipe + step) % len(RECIPES)

    # --- geometry -------------------------------------------------------------------

    def tiles(self):
        x0, x1 = math.floor(self.x), math.floor(self.x + PLAYER_W - 1e-6)
        y0, y1 = math.floor(self.y), math.floor(self.y + PLAYER_H - 1e-6)
        return [(tx, ty) for tx in range(x0, x1 + 1) for ty in range(y0, y1 + 1)]

    def overlaps_tile(self, tx, ty):
        return self.x < tx + 1 and self.x + PLAYER_W > tx and self.y < ty + 1 and self.y + PLAYER_H > ty

    def wall_side(self, world):
        """-1 if a block touches our left side, 1 if our right side, else 0."""
        rows = range(math.floor(self.y + 0.1), math.floor(self.y + PLAYER_H - 0.1) + 1)
        if any(world.solid(math.floor(self.x - 0.05), ty) for ty in rows):
            return -1
        if any(world.solid(math.floor(self.x + PLAYER_W + 0.05), ty) for ty in rows):
            return 1
        return 0

    def centre(self):
        return self.x + PLAYER_W / 2, self.y + PLAYER_H / 2

    def target(self, world, placing):
        """The tile the player is aiming at: next to them, above, below, or diagonal."""
        ax, ay = self.aim
        col = math.floor(self.x + PLAYER_W / 2)
        feet = math.floor(self.y + PLAYER_H - 0.01)
        head = math.floor(self.y + 0.01)
        if ax == 0:
            return (col, feet + 1) if ay > 0 else (col, head - 1)
        # First column past our right/left edge, whether or not we're touching it.
        side = math.floor(self.x + PLAYER_W - 1e-6) + 1 if ax > 0 else math.floor(self.x + 1e-6) - 1
        if ay > 0:
            return side, feet + 1
        if ay < 0:
            return side, head - 1
        if placing or world.solid(side, feet):
            return side, feet
        return side, head

    # --- per frame ------------------------------------------------------------------

    def update(self, dt, inp, game):
        self.mine_cd = max(0.0, self.mine_cd - dt)
        self.place_cd = max(0.0, self.place_cd - dt)
        self.item_cd = max(0.0, self.item_cd - dt)

        mouse = inp.get("mouse")
        # Holding craft opens the menu. Without a mouse, left/right pick the recipe, so you stop walking.
        self.crafting = bool(inp.get("craft"))
        menu_steering = self.crafting and not mouse
        dx = 0 if menu_steering else inp["right"] - inp["left"]
        dy = inp["down"] - inp["up"]
        if dx:
            self.facing = dx
        self.aim = (dx, dy) if (dx or dy) else (self.facing, 0)

        # Mouse or right stick: aim at it, snapped to 8 directions.
        pointer = None
        if mouse:
            cx, cy = self.centre()
            pointer = (mouse[0] - cx, mouse[1] - cy)
        elif inp.get("stick_aim"):
            pointer = inp["stick_aim"]
        if pointer and math.hypot(*pointer) > (0.6 if mouse else 0.5):
            self.aim = OCTANTS[round(math.atan2(pointer[1], pointer[0]) / (math.pi / 4)) % 8]
            if self.aim[0]:
                self.facing = self.aim[0]                     # face where you aim, even walking backwards

        self.move_body(dt, dx, inp, game)
        self.use_hands(inp, game)
        self.held = dict(inp)

        # Falling out the bottom or off either side is death.
        if self.y > ROWS + 1 or self.x + PLAYER_W < -0.5 or self.x > COLS + 0.5:
            self.alive = False

    def move_body(self, dt, dx, inp, game):
        world = game.world
        self.kvx *= math.exp(-KNOCK_DECAY * dt)
        if abs(self.kvx) < 0.1:
            self.kvx = 0.0
        self.coyote = COYOTE if self.on_ground else max(0.0, self.coyote - dt)
        self.wall_lock = max(0.0, self.wall_lock - dt)
        if self.on_ground:
            self.last_wall = 0

        if self.grapple and self.pull(dt, world):
            return
        self.vy = min(self.vy + GRAVITY * dt, MAX_FALL)

        # Wall slide: holding into a wall while falling slows the fall.
        wall = 0 if self.on_ground else self.wall_side(world)
        if wall:
            self.wall_coyote, self.wall_dir = WALL_COYOTE, wall
            if dx == wall and self.vy > WALL_SLIDE_SPEED:
                self.vy = WALL_SLIDE_SPEED
        else:
            self.wall_coyote = max(0.0, self.wall_coyote - dt)

        if self.pressed(inp, "jump"):
            if self.coyote > 0:
                self.vy = -JUMP_SPEED
                self.coyote = 0.0
                game.sounds.play("jump")
            elif self.wall_coyote > 0 and self.wall_dir != self.last_wall:
                # Wall jump: up, and kicked away from the wall.
                self.vy = -WALL_JUMP_SPEED
                self.kvx = -self.wall_dir * WALL_KICK
                self.facing = -self.wall_dir
                self.wall_coyote = 0.0
                self.last_wall = self.wall_dir
                self.wall_lock = WALL_LOCK
                game.sounds.play("jump")
                side_x = self.x if self.wall_dir < 0 else self.x + PLAYER_W
                game.particles.burst(side_x, self.y + PLAYER_H * 0.7, (200, 200, 220), 8, 4, life=0.3, size=3)

        walk = 0 if self.wall_lock > 0 else dx
        self.move(world, (walk * MOVE_SPEED + self.kvx) * dt, 0)
        self.on_ground = False
        self.move(world, 0, self.vy * dt)

    def pull(self, dt, world):
        """Grapple: fly straight at the hook point. Returns True while still being pulled."""
        hx, hy, left = self.grapple
        cx, cy = self.centre()
        dist = math.hypot(hx - cx, hy - cy)
        hooked = world.solid(math.floor(hx), math.floor(hy))
        if dist < 1.0 or left <= 0 or not hooked:
            self.grapple = None
            self.kvx *= 0.4
            self.vy = min(self.vy, -4.0)                      # a little hop at the end
            return False
        self.grapple = (hx, hy, left - dt)
        ux, uy = (hx - cx) / dist, (hy - cy) / dist
        self.kvx, self.vy = ux * GRAPPLE_SPEED, uy * GRAPPLE_SPEED
        before = (self.x, self.y)
        self.move(world, self.kvx * dt, 0)
        self.on_ground = False
        self.move(world, 0, self.vy * dt)
        if math.hypot(self.x - before[0], self.y - before[1]) < 0.01:
            self.grapple = None                               # stuck on something: let go
        return True

    def use_hands(self, inp, game):
        world = game.world
        # Crafting: hold craft, pick a recipe, let go to craft it.
        if self.crafting:
            if inp.get("wheel"):                              # online: the client sends its scroll wheel
                self.cycle_recipe(1 if inp["wheel"] > 0 else -1)
            if inp.get("mouse"):
                hover = game.menu_hover(self, inp["mouse"])
                if hover is not None:
                    self.recipe = hover
            else:
                if self.pressed(inp, "right"):
                    self.cycle_recipe(1)
                if self.pressed(inp, "left"):
                    self.cycle_recipe(-1)
        elif self.held.get("craft"):                          # craft button just released
            if self.craft(RECIPES[self.recipe]):
                game.sounds.play("craft")
            else:
                game.sounds.play("nope")

        # Items: each slot has its own button.
        for i in range(SLOTS):
            slot = self.slots[i]
            if self.pressed(inp, f"item{i + 1}") and slot and self.item_cd == 0 and game.use_item(self, slot["item"]):
                self.item_cd = ITEMS[slot["item"]]["cooldown"]
                self.last_used = i
                slot["charges"] -= 1
                if slot["charges"] <= 0:
                    self.slots[i] = None

        if inp["mine"] and self.mine_cd == 0:
            tx, ty = self.target(world, placing=False)
            if world.solid(tx, ty):
                self.mine_cd = MINE_COOLDOWN
                broke = world.hit(tx, ty)
                if broke is not None:
                    self.collect(broke)
                    game.sounds.play("mine")
                else:
                    game.sounds.play("crack")
        if inp["place"] and self.place_cd == 0 and self.blocks > 0:
            tx, ty = self.target(world, placing=True)
            if world.in_bounds(tx, ty) and not world.solid(tx, ty) and not game.player_in_tile(tx, ty):
                world.set(tx, ty, PLACED)
                self.inv["dirt" if self.inv["dirt"] else "stone"] -= 1
                self.place_cd = PLACE_COOLDOWN
                game.sounds.play("place")

    def move(self, world, dx, dy):
        """Move along one axis, then push back out of any block we ran into."""
        self.x += dx
        self.y += dy
        hits = [t for t in self.tiles() if world.solid(*t)]
        if not hits:
            return
        if dx > 0:
            self.x = min(tx for tx, _ in hits) - PLAYER_W
        elif dx < 0:
            self.x = max(tx for tx, _ in hits) + 1
        if dx:
            self.kvx = 0.0
        if dy > 0:
            self.y = min(ty for _, ty in hits) - PLAYER_H
            self.vy = 0.0
            self.on_ground = True
        elif dy < 0:
            self.y = max(ty for _, ty in hits) + 1
            self.vy = 0.0
