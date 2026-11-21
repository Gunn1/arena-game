import random

from config import (COLS, ROWS, TOP_ROW, MIN_FILL, MAP_MODE, FAIR_SPREAD, FAIR_RADIUS, MIN_NEAR, ORE_RADIUS, ORE_MIN,
                    CRUMBLE_GRACE, CRUMBLE_WARN, CRUMBLE_START, CRUMBLE_END, CRUMBLE_RAMP)

EMPTY, DIRT, STONE, PLACED, COPPER, CRYSTAL = 0, 1, 2, 3, 4, 5
HARD = {STONE, COPPER, CRYSTAL}          # take two hits to mine
DROPS = {DIRT: "dirt", PLACED: "dirt", STONE: "stone", COPPER: "copper", CRYSTAL: "crystal"}
ORE_TILES = {"copper": COPPER, "crystal": CRYSTAL}


def value_noise(rng, w, h, cell):
    """Smooth random field: random values on a coarse grid, blended in between."""
    gw, gh = w // cell + 3, h // cell + 3
    g = [[rng.random() for _ in range(gw)] for _ in range(gh)]

    def smooth(t):
        return t * t * (3 - 2 * t)

    def sample(x, y):
        fx, fy = x / cell, y / cell
        x0, y0 = int(fx), int(fy)
        tx, ty = smooth(fx - x0), smooth(fy - y0)
        top = g[y0][x0] * (1 - tx) + g[y0][x0 + 1] * tx
        bot = g[y0 + 1][x0] * (1 - tx) + g[y0 + 1][x0 + 1] * tx
        return top * (1 - ty) + bot * ty

    return sample


def neighbours(grid, x, y):
    count = 0
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            nx, ny = x + dx, y + dy
            if (dx or dy) and 0 <= ny < len(grid) and 0 <= nx < len(grid[0]) and grid[ny][nx]:
                count += 1
    return count


def remove_specks(grid, min_size):
    """Delete floating clumps smaller than min_size tiles."""
    h, w = len(grid), len(grid[0])
    seen = [[False] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            if not grid[y][x] or seen[y][x]:
                continue
            stack, part = [(x, y)], []
            seen[y][x] = True
            while stack:
                cx, cy = stack.pop()
                part.append((cx, cy))
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if 0 <= nx < w and 0 <= ny < h and grid[ny][nx] and not seen[ny][nx]:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            if len(part) < min_size:
                for px, py in part:
                    grid[py][px] = EMPTY


def smooth(grid):
    """Fill tiles surrounded by blocks, clear tiles that are mostly alone."""
    return [[DIRT if neighbours(grid, x, y) >= 5 else EMPTY if neighbours(grid, x, y) <= 2 else grid[y][x]
             for x in range(len(grid[0]))] for y in range(len(grid))]


def fill_ratio(grid):
    return sum(1 for row in grid for t in row if t) / (len(grid[0]) * (ROWS - TOP_ROW))


def assign_types(grid):
    """Top 3 tiles of each column are dirt, deeper is stone."""
    for x in range(len(grid[0])):
        depth = 0
        for y in range(len(grid)):
            if grid[y][x]:
                grid[y][x] = DIRT if depth < 3 else STONE
                depth += 1
            else:
                depth = 0


def add_ores(rng, grid):
    """Sprinkle copper through the stone, and crystal in the deeper stone."""
    for y in range(len(grid)):
        for x in range(len(grid[0])):
            if grid[y][x] != STONE:
                continue
            r = rng.random()
            if r < 0.035:
                grid[y][x] = COPPER
            elif r < 0.055 and y > ROWS * 0.6:
                grid[y][x] = CRYSTAL


def even_out_ores(rng, grid, spawns):
    """Give every spawn the same amount of each ore nearby (turning stone into ore)."""
    def area(col, row):
        return [(x, y) for y in range(max(0, row - ORE_RADIUS), min(len(grid), row + ORE_RADIUS + 1))
                for x in range(max(0, col - ORE_RADIUS), min(len(grid[0]), col + ORE_RADIUS + 1))]

    for name, tile in ORE_TILES.items():
        counts = [sum(grid[y][x] == tile for x, y in area(*s)) for s in spawns]
        target = max(max(counts), ORE_MIN[name])
        for spawn, count in zip(spawns, counts):
            stones = [(x, y) for x, y in area(*spawn) if grid[y][x] == STONE]
            rng.shuffle(stones)
            for x, y in stones[:target - count]:
                grid[y][x] = tile


def blocks_near(grid, col, row):
    """How much ground a spawn has around it: blocks in a square of FAIR_RADIUS."""
    return sum(1 for y in range(max(0, row - FAIR_RADIUS), min(ROWS, row + FAIR_RADIUS + 1))
               for x in range(max(0, col - FAIR_RADIUS), min(COLS, col + FAIR_RADIUS + 1)) if grid[y][x])


def pick_spawns(rng, grid, players):
    """Choose spawn spots that are spread out and have about the same ground around them.
    Returns (spawns sorted left to right, spread) where spread 0 = perfectly even."""
    spots = []
    for x in range(3, COLS - 3):                          # stay off the deadly side edges
        y = next((y for y in range(ROWS) if grid[y][x]), None)
        if y is not None and y >= 2 and blocks_near(grid, x, y) >= MIN_NEAR:
            spots.append((x, y))                          # top block of the column, open sky above
    near = {spot: blocks_near(grid, *spot) for spot in spots}
    min_gap = COLS // (players + 1)
    best, best_spread = None, 2.0
    for _ in range(400):
        pick = []
        for spot in rng.sample(spots, len(spots)):
            if all(abs(spot[0] - other[0]) >= min_gap for other in pick):
                pick.append(spot)
                if len(pick) == players:
                    break
        if len(pick) < players:
            continue
        counts = [near[spot] for spot in pick]
        spread = (max(counts) - min(counts)) / max(counts)
        if spread < best_spread:
            best, best_spread = sorted(pick), spread
        if spread <= FAIR_SPREAD / 3:
            break
    return best, best_spread


def make_random(rng, players):
    """A fully random map. Rerolls until it finds spawns within FAIR_SPREAD of each other
    (keeps the fairest attempt if none get there)."""
    best = None
    for _ in range(40):
        big = value_noise(rng, COLS, ROWS, 7)
        small = value_noise(rng, COLS, ROWS, 3)
        grid = [[EMPTY] * COLS for _ in range(ROWS)]
        for y in range(TOP_ROW, ROWS - 2):
            for x in range(2, COLS - 2):
                depth = (y - TOP_ROW) / (ROWS - TOP_ROW)
                if big(x, y) * 0.7 + small(x, y) * 0.3 + depth * 0.1 > 0.55:
                    grid[y][x] = DIRT
        grid = smooth(grid)
        remove_specks(grid, 6)
        if fill_ratio(grid) < MIN_FILL:
            continue
        spawns, spread = pick_spawns(rng, grid, players)
        if spawns and (best is None or spread < best[2]):
            best = (grid, spawns, spread)
        if best and best[2] <= FAIR_SPREAD:
            break
    if best is None:
        raise RuntimeError("could not generate a random map")
    assign_types(best[0])
    add_ores(rng, best[0])
    even_out_ores(rng, best[0], best[1])
    return best


def make_segment(rng, seg_w):
    """One player's slice of the map. It is mirrored left-right, and its outer
    columns stay empty, so every copy of it is exactly the same.
    Returns (tiles, spawn_col, ground_row)."""
    half = (seg_w + 1) // 2
    for _ in range(50):
        big = value_noise(rng, half, ROWS, 7)
        small = value_noise(rng, half, ROWS, 3)
        seg = [[EMPTY] * seg_w for _ in range(ROWS)]
        for y in range(TOP_ROW, ROWS - 2):
            for x in range(1, half):                      # column 0 is the gap to the next segment
                centre = x / (half - 1)                   # 0 at the edge, 1 in the middle
                depth = (y - TOP_ROW) / (ROWS - TOP_ROW)
                v = big(x, y) * 0.7 + small(x, y) * 0.3 + centre * 0.14 + depth * 0.1
                if v > 0.58:
                    seg[y][x] = seg[y][seg_w - 1 - x] = DIRT

        seg = smooth(seg)
        remove_specks(seg, 6)
        if fill_ratio(seg) < MIN_FILL:
            continue

        # Spawn on the highest ground near the middle; build a small ledge if there is none.
        col = seg_w // 2
        ground = next((y for y in range(ROWS) if seg[y][col]), None)
        if ground is None or ground < TOP_ROW:
            ground = 15
            for x in (col - 1, col, col + 1):
                seg[ground][x] = DIRT
                seg[ground][seg_w - 1 - x] = DIRT

        assign_types(seg)
        add_ores(rng, seg)
        even_out_ores(rng, seg, [(col, ground)])
        return seg, col, ground
    raise RuntimeError("could not generate a map segment")


class World:
    def __init__(self):
        self.grid = [[EMPTY] * COLS for _ in range(ROWS)]
        self.spawns = []
        self.cracked = set()
        self.warnings = {}       # (x, y) -> seconds until it breaks
        self.elapsed = 0.0
        self.crumble_timer = 0.0
        self.rng = random.Random()
        self.broken = []         # (x, y, tile, cause) since the game last drained it
        self.spread = 0.0        # how uneven the spawns are (0 = identical ground around each)
        self.record = False      # host: log every change so it can be sent to clients
        self.changes = []        # ["t", x, y, tile, cause] / ["c", x, y] crack / ["w", x, y] warning
        self.version = 0         # bumps every new map

    def generate(self, seed, players, mode=MAP_MODE):
        self.rng = random.Random(seed)
        if mode == "mirrored":
            # One mirrored segment per player, copied side by side: every spawn is identical.
            seg_w = COLS // players
            offset = (COLS - seg_w * players) // 2
            seg, col, ground = make_segment(self.rng, seg_w)
            self.grid = [[EMPTY] * COLS for _ in range(ROWS)]
            for i in range(players):
                for y in range(ROWS):
                    for x in range(seg_w):
                        self.grid[y][offset + i * seg_w + x] = seg[y][x]
            self.spawns = [(offset + i * seg_w + col, ground) for i in range(players)]
            self.spread = 0.0
        else:
            self.grid, self.spawns, self.spread = make_random(self.rng, players)
        self.cracked.clear()
        self.warnings.clear()
        self.broken.clear()
        self.changes.clear()
        self.version += 1
        self.elapsed = 0.0
        self.crumble_timer = CRUMBLE_START

    def in_bounds(self, x, y):
        return 0 <= x < COLS and 0 <= y < ROWS

    def get(self, x, y):
        return self.grid[y][x] if self.in_bounds(x, y) else EMPTY

    def solid(self, x, y):
        return self.get(x, y) != EMPTY

    def set(self, x, y, tile, cause="mine"):
        if not self.in_bounds(x, y):
            return
        old = self.grid[y][x]
        self.grid[y][x] = tile
        if self.record and old != tile:
            self.changes.append(["t", x, y, tile, cause])
        if tile == EMPTY and old != EMPTY:
            self.broken.append((x, y, old, cause))
        if tile == EMPTY:
            self.cracked.discard((x, y))
            self.warnings.pop((x, y), None)

    def hit(self, x, y):
        """Mine a block. Returns the tile type if it broke, else None (empty, or a hard block just cracked)."""
        tile = self.get(x, y)
        if tile == EMPTY:
            return None
        if tile in HARD and (x, y) not in self.cracked:
            self.cracked.add((x, y))
            if self.record:
                self.changes.append(["c", x, y])
            return None
        self.set(x, y, EMPTY)
        return tile

    def crumble_interval(self):
        t = min(1.0, max(0.0, self.elapsed - CRUMBLE_GRACE) / CRUMBLE_RAMP)
        return CRUMBLE_START + (CRUMBLE_END - CRUMBLE_START) * t

    def update(self, dt):
        self.elapsed += dt
        for pos in list(self.warnings):
            self.warnings[pos] -= dt
            if self.warnings[pos] <= 0:
                self.set(*pos, EMPTY, cause="crumble")
        if self.elapsed < CRUMBLE_GRACE:
            return
        self.crumble_timer -= dt
        while self.crumble_timer <= 0:
            self.start_crumble()
            self.crumble_timer += self.crumble_interval()

    def start_crumble(self):
        choices = [(x, y) for y in range(ROWS) for x in range(COLS)
                   if self.grid[y][x] and (x, y) not in self.warnings]
        if choices:
            x, y = self.rng.choice(choices)
            self.warnings[(x, y)] = CRUMBLE_WARN
            if self.record:
                self.changes.append(["w", x, y])

    def block_count(self):
        return sum(1 for row in self.grid for t in row if t)
