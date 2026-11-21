import math
import random

import pygame

from config import (CELL, COLS, ROWS, HUD_H, WIDTH, HEIGHT, PLAYER_W, PLAYER_H, CARRY_LIMIT, SLOTS,
                    PUSH_SPEED, PUSH_RANGE, PUSH_KNOCK, PUSH_LIFT, LASER_LENGTH, LASER_SHOW,
                    BOOST_SPEED, GRAPPLE_RANGE, GRAPPLE_TIME, BOMB_THROW, BOMB_FUSE, BOMB_RADIUS,
                    BOMB_BLAST, BOMB_KNOCK, PLATFORM_WIDTH, CRUMBLE_WARN,
                    ROUNDS_TO_WIN, ROUND_INTRO, ROUND_OUTRO, MOUSE_PLAYER)
from effects import Particles, Sounds
from controls import KEY_HELP, KeyboardControls, JoystickControls, keyboard_layouts
from net import Host, Client, RemoteControls
from config import NET_PORT
from items import ITEMS, RECIPES, MATERIALS, MATERIAL_COLORS, cost_text, draw_icon
from player import Player
from world import World, EMPTY, DIRT, STONE, PLACED, COPPER, CRYSTAL  # noqa: F401

TILE_COLORS = {DIRT: (138, 90, 51), STONE: (109, 111, 134), PLACED: (176, 132, 84),
               COPPER: (109, 111, 134), CRYSTAL: (109, 111, 134)}
ORE_SPECKS = {COPPER: MATERIAL_COLORS["copper"], CRYSTAL: MATERIAL_COLORS["crystal"]}
GRASS, GRASS_LIGHT = (92, 194, 74), (139, 227, 111)
DANGER = (255, 77, 94)
INK, DIM = (238, 240, 255), (169, 174, 214)
PANEL = (20, 23, 46)
PLAYER_COLORS_UI = [(255, 107, 107), (79, 168, 255), (255, 210, 63), (183, 123, 255)]


def lerp_color(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


class Game:
    def __init__(self):
        self.running = True
        self.state = "title"
        self.world = World()
        self.players = []
        self.joysticks = []
        self.projectiles = []
        self.bombs = []
        self.beams = []
        self.round = 0
        self.timer = 0.0
        self.message = ""
        self.time = 0.0
        self.font_big = pygame.font.Font(None, 84)
        self.font = pygame.font.Font(None, 30)
        self.font_small = pygame.font.Font(None, 22)
        self.background = self.make_background()
        self.particles = Particles()
        self.sounds = Sounds()
        self.shake = 0.0
        self.offset = (0, 0)
        self.match_size = 2
        self.mode = "local"          # "local" (same keyboard), "host" or "client"
        self.host = None
        self.client = None
        self.events = []             # host: sounds and bursts to replay on clients
        self.address = ""            # what the player typed on the join screen

    # --- match flow -------------------------------------------------------------

    def start_match(self, count):
        """P1 is always the keyboard (and mouse). Everyone else gets a controller if one is
        plugged in; if not, P2 falls back to the right side of the keyboard."""
        p1, p2 = keyboard_layouts()
        if len(self.joysticks) < count - 2:
            self.message = f"{count} players needs {count - 2} controller(s) plugged in"
            return
        controls = [KeyboardControls(p1, mouse=(MOUSE_PLAYER == 0))]
        if len(self.joysticks) < count - 1:
            controls.append(KeyboardControls(p2))
        controls += [JoystickControls(j) for j in self.joysticks[:count - len(controls)]]
        self.players = [Player(i, controls[i]) for i in range(count)]
        self.match_size = count
        self.round = 0
        self.new_round()

    def new_round(self):
        self.round += 1
        self.world.generate(random.randrange(1, 2**31), len(self.players))
        for player, (col, ground) in zip(self.players, self.world.spawns):
            player.spawn(col, ground)
        self.projectiles.clear()
        self.bombs.clear()
        self.beams.clear()
        self.particles.items.clear()
        self.state = "intro"
        self.timer = ROUND_INTRO

    def end_round(self):
        alive = [p for p in self.players if p.alive]
        if alive:
            alive[0].wins += 1
            self.message = f"P{alive[0].index + 1} wins the round"
            self.sounds.play("round")
        else:
            self.message = "Draw: nobody scores"
        self.state = "outro"
        self.timer = ROUND_OUTRO

    # --- online -----------------------------------------------------------------

    def host_game(self, port=NET_PORT):
        try:
            self.host = Host(port)
        except OSError as err:
            self.message = f"Can't host on port {NET_PORT}: {err.strerror}"
            return
        self.mode, self.state, self.message = "host", "lobby", ""
        self.world.record = True
        self.particles.log = self.sounds.log = self.events

    def join_game(self):
        try:
            self.client = Client(self.address)
        except (OSError, ValueError) as err:
            self.message = f"Couldn't connect to {self.address}: {getattr(err, 'strerror', None) or err}"
            self.state = "join"
            return
        self.mode, self.state, self.message = "client", "lobby", ""
        self.players = []

    def leave_online(self, message=""):
        if self.host:
            self.host.close()
        if self.client:
            self.client.close()
        self.host = self.client = None
        self.mode, self.state, self.message = "local", "title", message
        self.world.record = False
        self.particles.log = self.sounds.log = None
        self.players = []

    def start_online_match(self):
        """Host: you are P1, each connected friend is the next player."""
        self.players = [Player(0, KeyboardControls("p1_mouse", mouse=True))]
        self.players += [Player(i + 1, RemoteControls(c)) for i, c in enumerate(self.host.clients)]
        self.match_size = len(self.players)
        self.round = 0
        self.new_round()

    def client_update(self, dt, pressed):
        why = self.client.poll(self)
        if why:
            self.leave_online(f"Disconnected: {why}")
            return
        me = self.players[self.client.you] if self.client.you < len(self.players) else None
        if me and me.controls and self.state in ("intro", "play", "outro"):
            self.client.send_input(me.controls.read(pressed))
        for pos in self.world.warnings:                  # tick crumble warnings for the shake effect only
            self.world.warnings[pos] = max(0.01, self.world.warnings[pos] - dt)
        self.drain_broken()

    def mouse_player(self):
        return next((p for p in self.players if getattr(p.controls, "mouse", False)), None)

    def handle_events(self, events):
        for e in events:
            if e.type == pygame.QUIT:
                self.running = False
            elif e.type == pygame.JOYDEVICEADDED:
                self.joysticks.append(pygame.joystick.Joystick(e.device_index))
            elif e.type == pygame.JOYDEVICEREMOVED:
                self.joysticks = [j for j in self.joysticks if j.get_instance_id() != e.instance_id]
            elif e.type == pygame.MOUSEWHEEL and self.state == "play" and e.y:
                mp = self.mouse_player()
                step = -1 if e.y > 0 else 1
                if self.mode == "client" and mp and mp.crafting:
                    self.client.wheel += step
                elif mp and mp.alive and mp.crafting:
                    mp.cycle_recipe(step)
            elif e.type == pygame.TEXTINPUT and self.state == "join":
                self.address = (self.address + e.text)[:60]
            elif e.type == pygame.KEYDOWN:
                if e.key == pygame.K_ESCAPE:
                    if self.state == "title":
                        self.running = False
                    elif self.mode != "local":
                        self.leave_online()
                    else:
                        self.state, self.message = "title", ""
                elif self.state == "title" and e.key == pygame.K_h:
                    self.host_game()
                elif self.state == "title" and e.key == pygame.K_j:
                    self.state, self.message = "join", ""
                elif self.state == "title" and e.key in (pygame.K_2, pygame.K_3, pygame.K_4):
                    self.start_match(3 if e.key == pygame.K_3 else 4 if e.key == pygame.K_4 else 2)
                elif self.state == "join" and e.key == pygame.K_BACKSPACE:
                    self.address = self.address[:-1]
                elif self.state == "join" and e.key == pygame.K_RETURN and self.address.strip():
                    self.join_game()
                elif self.state == "lobby" and self.mode == "host" and e.key == pygame.K_RETURN:
                    if self.host.clients:
                        self.start_online_match()
                    else:
                        self.message = "Wait for at least one friend to join"
                elif self.state == "match_over" and e.key == pygame.K_RETURN and self.mode != "client":
                    if self.mode == "host":
                        self.start_online_match()
                    else:
                        self.start_match(self.match_size)
                elif e.key == pygame.K_m:
                    self.sounds.muted = not self.sounds.muted

    def update(self, dt, pressed):
        self.time += dt
        self.particles.update(dt)
        self.shake = max(0.0, self.shake - dt)
        if self.mode == "client":
            self.client_update(dt, pressed)
            return
        if self.mode == "host":
            self.host.poll(self)
        self.simulate(dt, pressed)
        if self.mode == "host":
            self.host.broadcast(self)

    def simulate(self, dt, pressed):
        if self.state == "intro":
            self.timer -= dt
            if self.timer <= 0:
                self.state = "play"
                self.sounds.play("go")
            return
        if self.state not in ("play", "outro"):
            return

        self.world.update(dt)
        for p in self.players:
            if p.alive:
                p.update(dt, p.controls.read(pressed), self)
                if not p.alive:
                    self.on_death(p)
        self.update_projectiles(dt)
        self.update_bombs(dt)
        self.drain_broken()
        for beam in self.beams:
            beam["time"] -= dt
        self.beams = [b for b in self.beams if b["time"] > 0]

        if self.state == "play" and sum(p.alive for p in self.players) <= 1:
            self.end_round()
        elif self.state == "outro":
            self.timer -= dt
            if self.timer <= 0:
                best = max(self.players, key=lambda p: p.wins)
                if best.wins >= ROUNDS_TO_WIN:
                    self.state = "match_over"
                    self.message = f"P{best.index + 1} wins the match!"
                else:
                    self.new_round()

    def on_death(self, p):
        x = min(max(p.x + PLAYER_W / 2, 0.5), COLS - 0.5)
        y = min(p.y + PLAYER_H / 2, ROWS - 0.5)
        self.particles.burst(x, y, p.color, 40, 14, life=0.9, size=6, up=6)
        self.particles.burst(x, y, (255, 255, 255), 12, 8, life=0.5, size=3, up=4)
        self.sounds.play("death")
        self.shake = 0.35

    def drain_broken(self):
        crumbled = False
        for x, y, tile, cause in self.world.broken:
            self.particles.debris(x, y, ORE_SPECKS.get(tile, TILE_COLORS[tile]))
            crumbled = crumbled or cause == "crumble"
        self.world.broken.clear()
        if crumbled:
            self.sounds.play("crumble", min_gap=0.06, log=False)   # clients make their own from the tile changes

    def player_in_tile(self, tx, ty):
        return any(p.alive and p.overlaps_tile(tx, ty) for p in self.players)

    # --- items --------------------------------------------------------------------

    def use_item(self, player, key):
        """Run an item's effect. Returns False if it couldn't be used (no charge spent)."""
        cx, cy = player.centre()
        ax, ay = player.aim
        length = math.hypot(ax, ay)
        ux, uy = ax / length, ay / length

        if key == "push":
            d = player.facing
            self.projectiles.append({"x": cx + d * 0.5, "y": cy, "dir": d, "dist": 0.0, "owner": player})
            self.sounds.play("push")
        elif key == "laser":
            for i in range(1, LASER_LENGTH + 1):
                self.world.set(math.floor(cx + ux * i), math.floor(cy + uy * i), EMPTY, cause="laser")
            self.beams.append({"from": (cx, cy), "to": (cx + ux * LASER_LENGTH, cy + uy * LASER_LENGTH),
                               "color": player.color, "owner": player, "time": LASER_SHOW})
            self.sounds.play("laser")
            self.shake = max(self.shake, 0.1)
        elif key == "boost":
            player.grapple = None
            player.vy = -BOOST_SPEED
            for _ in range(3):
                self.particles.burst(cx, player.y + PLAYER_H, (255, 170, 60), 6, 6, life=0.4, size=4)
            self.sounds.play("boost")
        elif key == "platform":
            row = math.floor(player.y + PLAYER_H - 0.01) + 1
            col = math.floor(cx)
            placed = 0
            for x in range(col - PLATFORM_WIDTH // 2, col + PLATFORM_WIDTH // 2 + 1):
                if self.world.in_bounds(x, row) and not self.world.solid(x, row) and not self.player_in_tile(x, row):
                    self.world.set(x, row, PLACED)
                    placed += 1
            if not placed:
                return False
            if player.vy > 0:
                player.vy = 0.0
            self.sounds.play("place")
        elif key == "grapple":
            for i in range(1, GRAPPLE_RANGE * 5 + 1):
                hx, hy = cx + ux * i * 0.2, cy + uy * i * 0.2
                if self.world.solid(math.floor(hx), math.floor(hy)):
                    player.grapple = (hx, hy, GRAPPLE_TIME)
                    self.sounds.play("grapple")
                    return True
            self.sounds.play("nope")
            return False
        elif key == "bomb":
            vx, vy = ux * BOMB_THROW, uy * BOMB_THROW - (4.0 if uy <= 0 else 0.0)
            self.bombs.append({"x": cx, "y": cy, "vx": vx, "vy": vy, "fuse": BOMB_FUSE, "owner": player})
            self.sounds.play("push")
        return True

    def update_projectiles(self, dt):
        keep = []
        for pr in self.projectiles:
            step = PUSH_SPEED * dt
            pr["x"] += pr["dir"] * step
            pr["dist"] += step
            if self.world.solid(math.floor(pr["x"]), math.floor(pr["y"])) or pr["dist"] > PUSH_RANGE:
                self.particles.burst(pr["x"], pr["y"], pr["owner"].color, 6, 4, life=0.3, size=3)
                continue
            hit = next((p for p in self.players if p.alive and p is not pr["owner"]
                        and p.x - 0.2 < pr["x"] < p.x + PLAYER_W + 0.2
                        and p.y - 0.2 < pr["y"] < p.y + PLAYER_H + 0.2), None)
            if hit:
                hit.grapple = None
                hit.kvx = pr["dir"] * PUSH_KNOCK
                hit.vy = -PUSH_LIFT
                self.particles.burst(pr["x"], pr["y"], pr["owner"].color, 14, 9, life=0.4, size=4)
                self.sounds.play("hit")
                self.shake = max(self.shake, 0.12)
                continue
            keep.append(pr)
        self.projectiles = keep

    def update_bombs(self, dt):
        keep = []
        for b in self.bombs:
            b["fuse"] -= dt
            if b["fuse"] <= 0:
                self.explode(b)
                continue
            if b["vx"] or b["vy"]:
                b["vy"] += 30 * dt
                nx, ny = b["x"] + b["vx"] * dt, b["y"] + b["vy"] * dt
                if self.world.solid(math.floor(nx), math.floor(ny)):
                    b["vx"] = b["vy"] = 0.0                       # sticks to whatever it hits
                else:
                    b["x"], b["y"] = nx, ny
            if b["y"] > ROWS + 2:
                continue                                          # fell out of the map: a dud
            keep.append(b)
        self.bombs = keep

    def explode(self, b):
        bx, by = b["x"], b["y"]
        r = math.ceil(BOMB_RADIUS)
        for y in range(math.floor(by) - r, math.floor(by) + r + 1):
            for x in range(math.floor(bx) - r, math.floor(bx) + r + 1):
                if math.hypot(x + 0.5 - bx, y + 0.5 - by) <= BOMB_RADIUS:
                    self.world.set(x, y, EMPTY, cause="bomb")
        for p in self.players:
            if not p.alive:
                continue
            cx, cy = p.centre()
            d = math.hypot(cx - bx, cy - by)
            if d < BOMB_BLAST:
                force = BOMB_KNOCK * (1 - d / BOMB_BLAST)
                ux, uy = ((cx - bx) / d, (cy - by) / d) if d > 0.01 else (0.0, -1.0)
                p.grapple = None
                p.kvx = ux * force
                p.vy = min(p.vy, uy * force - 5)
        self.particles.burst(bx, by, (255, 200, 80), 30, 14, life=0.6, size=5)
        self.particles.burst(bx, by, (255, 255, 255), 12, 8, life=0.3, size=3)
        self.sounds.play("boom")
        self.shake = max(self.shake, 0.3)

    # --- drawing ----------------------------------------------------------------

    def make_background(self):
        surf = pygame.Surface((WIDTH, HEIGHT))
        for y in range(HEIGHT):
            t = y / HEIGHT
            top, mid, bottom = (42, 47, 107), (23, 26, 58), (7, 8, 15)
            color = lerp_color(top, mid, t / 0.7) if t < 0.7 else lerp_color(mid, bottom, (t - 0.7) / 0.3)
            pygame.draw.line(surf, color, (0, y), (WIDTH, y))
        rng = random.Random(7)
        for _ in range(90):
            shade = rng.randint(90, 220)
            surf.fill((shade, shade, shade), (rng.randrange(WIDTH), HUD_H + rng.randrange(ROWS * CELL // 3), 2, 2))
        return surf

    def to_screen(self, x, y):
        return int(x * CELL) + self.offset[0], int(y * CELL) + HUD_H + self.offset[1]

    def draw(self, screen):
        screen.blit(self.background, (0, 0))
        if self.state in ("title", "join", "lobby"):
            pygame.mouse.set_visible(True)
            {"title": self.draw_title, "join": self.draw_join, "lobby": self.draw_lobby}[self.state](screen)
            return
        power = int(10 * self.shake)
        self.offset = (random.randint(-power, power), random.randint(-power, power)) if power else (0, 0)
        self.draw_world(screen)
        for p in self.players:
            if p.alive and p.grapple:
                pygame.draw.line(screen, (220, 220, 230), self.to_screen(*p.centre()), self.to_screen(*p.grapple[:2]), 2)
        for p in self.players:
            if p.alive:
                self.draw_player(screen, p)
        for pr in self.projectiles:
            pos = self.to_screen(pr["x"], pr["y"])
            pygame.draw.circle(screen, pr["owner"].color, pos, 7)
            pygame.draw.circle(screen, (255, 255, 255), pos, 3)
        for b in self.bombs:
            pos = self.to_screen(b["x"], b["y"])
            pygame.draw.circle(screen, (30, 30, 40), pos, 7)
            pygame.draw.circle(screen, b["owner"].color, pos, 7, 2)
            if int(b["fuse"] * (12 if b["fuse"] < 0.5 else 5)) % 2:
                pygame.draw.circle(screen, (255, 220, 90), (pos[0] + 5, pos[1] - 6), 3)
        for b in self.beams:
            a, z = self.to_screen(*b["from"]), self.to_screen(*b["to"])
            pygame.draw.line(screen, b["color"], a, z, 8)
            pygame.draw.line(screen, (255, 255, 255), a, z, 3)
        self.particles.draw(screen, self.to_screen)
        for p in self.players:
            if p.alive and p.crafting:
                self.draw_craft_menu(screen, p)
        self.draw_cursor(screen)
        self.draw_hud(screen)
        if self.state == "intro":
            self.banner(screen, f"Round {self.round}", "Mine ore, hold your craft key to make items, last one standing wins")
        elif self.state in ("outro", "match_over"):
            sub = "Enter = rematch    Esc = menu" if self.state == "match_over" else self.score_line()
            self.banner(screen, self.message, sub)

    def draw_world(self, screen):
        w = self.world
        for y in range(ROWS):
            for x in range(COLS):
                tile = w.grid[y][x]
                if tile == EMPTY:
                    continue
                px, py = self.to_screen(x, y)
                color = TILE_COLORS[tile]
                warn = w.warnings.get((x, y))
                if warn is not None:
                    left = warn / CRUMBLE_WARN                       # 1 -> 0 as it is about to break
                    px += random.randint(-2, 2) if left < 0.6 else random.randint(-1, 1)
                    flash = 0.5 + 0.5 * math.sin(self.time * 30)
                    color = lerp_color(color, DANGER, 0.25 + 0.5 * (1 - left) * flash)
                pygame.draw.rect(screen, color, (px, py, CELL, CELL))
                speck = (x * 73856093 ^ y * 19349663) & 3
                pygame.draw.rect(screen, lerp_color(color, (0, 0, 0), 0.2),
                                 (px + speck * 4 + 2, py + ((speck * 7) % 4) * 4 + 2, 4, 4))
                if tile in ORE_SPECKS:
                    ore = ORE_SPECKS[tile]
                    for ox, oy in ((4, 5), (12, 3), (9, 12), (14, 14)):
                        pygame.draw.rect(screen, ore, (px + ox, py + oy, 4, 4))
                    pygame.draw.rect(screen, lerp_color(ore, (255, 255, 255), 0.5), (px + 12, py + 3, 2, 2))
                elif tile == PLACED:
                    pygame.draw.rect(screen, lerp_color(color, (0, 0, 0), 0.35), (px, py, CELL, CELL), 2)
                    pygame.draw.line(screen, lerp_color(color, (0, 0, 0), 0.35), (px, py + CELL // 2), (px + CELL, py + CELL // 2))
                elif tile == DIRT and not w.solid(x, y - 1):
                    pygame.draw.rect(screen, GRASS, (px, py, CELL, 6))
                    pygame.draw.rect(screen, GRASS_LIGHT, (px, py, CELL, 2))
                if (x, y) in w.cracked:
                    dark = (50, 50, 64)
                    pygame.draw.lines(screen, dark, False, [(px + 4, py + 3), (px + 9, py + 9), (px + 7, py + 14), (px + 13, py + 18)], 2)
                    pygame.draw.line(screen, dark, (px + 9, py + 9), (px + 16, py + 6), 2)
        # Death edges: bottom, left, right.
        pygame.draw.rect(screen, DANGER, (0, HEIGHT - 3, WIDTH, 3))
        pygame.draw.rect(screen, DANGER, (0, HUD_H, 3, ROWS * CELL))
        pygame.draw.rect(screen, DANGER, (WIDTH - 3, HUD_H, 3, ROWS * CELL))

    def draw_player(self, screen, p):
        tx, ty = p.target(self.world, placing=False)
        if self.world.solid(tx, ty) or p.blocks:
            pygame.draw.rect(screen, p.color, (*self.to_screen(tx, ty), CELL, CELL), 2)
        x, y = self.to_screen(p.x, p.y)
        w, h = int(PLAYER_W * CELL), int(PLAYER_H * CELL)
        pygame.draw.rect(screen, lerp_color(p.color, (0, 0, 0), 0.35), (x, y + 3, w, h - 3), border_radius=4)
        pygame.draw.rect(screen, p.color, (x, y, w, h - 4), border_radius=4)
        eye_x = x + w // 2 + p.facing * 3
        for ex in (eye_x - 4, eye_x + 3):
            pygame.draw.rect(screen, (255, 255, 255), (ex - 2, y + 6, 4, 6))
            pygame.draw.rect(screen, (0, 0, 0), (ex - 1 + p.facing, y + 8, 2, 3))
        if not p.crafting:
            tag = self.font_small.render(f"P{p.index + 1}", True, p.color)
            screen.blit(tag, (x + w // 2 - tag.get_width() // 2, y - 16))

    MENU_BOX, MENU_GAP, MENU_W = 30, 5, 300

    def menu_layout(self, p):
        """Screen rects of the crafting menu above player p: (panel, [one rect per recipe])."""
        box, gap = self.MENU_BOX, self.MENU_GAP
        row_w = len(RECIPES) * (box + gap) - gap
        px = int((p.x + PLAYER_W / 2) * CELL)
        py = int(p.y * CELL) + HUD_H
        panel = pygame.Rect(0, 0, self.MENU_W, box + 52)
        panel.midbottom = (px, py - 8)
        panel.clamp_ip(pygame.Rect(4, HUD_H + 4, WIDTH - 8, HEIGHT - HUD_H - 8))
        left = panel.centerx - row_w // 2
        return panel, [pygame.Rect(left + i * (box + gap), panel.top + 8, box, box) for i in range(len(RECIPES))]

    def menu_hover(self, p, mouse_tiles):
        mx, my = mouse_tiles[0] * CELL, mouse_tiles[1] * CELL + HUD_H
        _, rects = self.menu_layout(p)
        return next((i for i, r in enumerate(rects) if r.inflate(4, 8).collidepoint(mx, my)), None)

    def draw_craft_menu(self, screen, p):
        """Row of recipes above the player; the highlighted one shows its cost. Let go to craft."""
        panel, rects = self.menu_layout(p)
        pygame.draw.rect(screen, PANEL, panel, border_radius=6)
        pygame.draw.rect(screen, p.color, panel, 2, border_radius=6)
        for i, (k, rect) in enumerate(zip(RECIPES, rects)):
            pygame.draw.rect(screen, (34, 38, 72), rect, border_radius=4)
            draw_icon(screen, k, rect.inflate(-4, -4), p.color, dim=not p.can_afford(k))
            if i == p.recipe:
                pygame.draw.rect(screen, (255, 255, 255), rect, 2, border_radius=4)
        key = RECIPES[p.recipe]
        ok = p.can_afford(key)
        lines = (f"{ITEMS[key]['name']}: {cost_text(key)}",
                 "let go to craft" if ok else "not enough materials")
        for n, text in enumerate(lines):
            surf = self.font_small.render(text, True, INK if (ok or n == 0) else DANGER)
            screen.blit(surf, (panel.centerx - surf.get_width() // 2, panel.top + self.MENU_BOX + 12 + n * 16))

    def draw_cursor(self, screen):
        """Crosshair in the mouse player's colour while a round is on; normal cursor otherwise."""
        mp = self.mouse_player()
        show = mp is not None and self.state in ("intro", "play", "outro")
        pygame.mouse.set_visible(not show)
        if not show:
            return
        mx, my = pygame.mouse.get_pos()
        pygame.draw.circle(screen, (0, 0, 0), (mx, my), 9, 3)
        pygame.draw.circle(screen, mp.color, (mx, my), 8, 2)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            pygame.draw.line(screen, mp.color, (mx + dx * 4, my + dy * 4), (mx + dx * 12, my + dy * 12), 2)

    def draw_hud(self, screen):
        screen.fill(PANEL, (0, 0, WIDTH, HUD_H))
        slot_w = WIDTH // max(4, len(self.players))
        for i, p in enumerate(self.players):
            x = 10 + i * slot_w
            name = self.font.render(f"P{i + 1}", True, p.color if p.alive else DIM)
            screen.blit(name, (x, 8))
            if not p.alive:
                screen.blit(self.font_small.render("out", True, DIM), (x + 2, 30))
            for r in range(ROUNDS_TO_WIN):
                pygame.draw.circle(screen, p.color, (x + 7 + r * 15, 52), 5, 0 if r < p.wins else 2)

            # Materials: dirt, stone (these two share the carry limit), copper, crystal.
            col = x + 58
            full = p.blocks >= CARRY_LIMIT
            for n, m in enumerate(MATERIALS):
                mx = col + n * 50
                pygame.draw.rect(screen, MATERIAL_COLORS[m], (mx, 9, 12, 12), border_radius=2)
                color = DANGER if full and m in ("dirt", "stone") else INK
                screen.blit(self.font_small.render(str(p.inv[m]), True, color), (mx + 16, 8))

            # Item slots, each labelled with the button that uses it.
            labels = getattr(p.controls, "slot_labels", ("Q", "E", "R"))
            for s in range(SLOTS):
                rect = pygame.Rect(col + s * 36, 28, 32, 32)
                pygame.draw.rect(screen, (34, 38, 72), rect, border_radius=5)
                item = p.slots[s]
                if item:
                    draw_icon(screen, item["item"], rect.inflate(-8, -8).move(2, 2), p.color)
                    count = self.font_small.render(str(item["charges"]), True, INK)
                    screen.blit(count, (rect.right - count.get_width() - 2, rect.bottom - 14))
                    if p.item_cd > 0:
                        cover = pygame.Surface(rect.size, pygame.SRCALPHA)
                        cover.fill((0, 0, 0, 140))
                        screen.blit(cover, rect.topleft)
                    pygame.draw.rect(screen, p.color, rect, 1, border_radius=5)
                screen.blit(self.font_small.render(labels[s], True, DIM), (rect.left + 3, rect.top + 1))
            craft_key = getattr(p.controls, "craft_label", "F")
            hint = "crafting..." if p.crafting else f"hold {craft_key}: craft"
            screen.blit(self.font_small.render(hint, True, p.color if p.crafting else DIM), (col + SLOTS * 36 + 4, 38))

    def score_line(self):
        return "   ".join(f"P{p.index + 1}: {p.wins}" for p in self.players) + f"   (first to {ROUNDS_TO_WIN})"

    def banner(self, screen, title, sub):
        shade = pygame.Surface((WIDTH, 160), pygame.SRCALPHA)
        shade.fill((0, 0, 0, 150))
        screen.blit(shade, (0, HEIGHT // 2 - 80))
        t = self.font_big.render(title, True, INK)
        screen.blit(t, (WIDTH // 2 - t.get_width() // 2, HEIGHT // 2 - 55))
        s = self.font.render(sub, True, DIM)
        screen.blit(s, (WIDTH // 2 - s.get_width() // 2, HEIGHT // 2 + 25))

    def centred(self, screen, lines, y):
        for font, text, color in lines:
            surf = font.render(text, True, color)
            screen.blit(surf, (WIDTH // 2 - surf.get_width() // 2, y))
            y += surf.get_height() + 12
        return y

    def draw_join(self, screen):
        y = self.centred(screen, [
            (self.font_big, "Join a game", INK),
            (self.font, "Type the host's address (their Tailscale IP works best), then press Enter.", DIM),
        ], 160)
        box = pygame.Rect(WIDTH // 2 - 260, y + 20, 520, 56)
        pygame.draw.rect(screen, PANEL, box, border_radius=8)
        pygame.draw.rect(screen, INK, box, 2, border_radius=8)
        caret = "|" if int(self.time * 2) % 2 else " "
        text = self.font.render(self.address + caret, True, INK)
        screen.blit(text, (box.x + 16, box.centery - text.get_height() // 2))
        self.centred(screen, [(self.font_small, f"Example: 100.101.102.103   (port {NET_PORT} is the default)", DIM),
                              (self.font_small, "Esc = back", DIM)], box.bottom + 20)
        if self.message:
            self.centred(screen, [(self.font, self.message, DANGER)], box.bottom + 110)

    def draw_lobby(self, screen):
        if self.mode == "host":
            count = len(self.host.clients) + 1
            addrs = [f"{ip}   ({kind})" for ip, kind in self.host.addresses] or ["(couldn't find your address)"]
            lines = [(self.font_big, "Hosting", INK),
                     (self.font, "Friends press J on the title screen and type one of these:", DIM)]
            lines += [(self.font, a, INK) for a in addrs]
            lines += [(self.font_small, "Use the Tailscale address if you're both on Tailscale; LAN only works on the same network.", DIM)]
        else:
            count = self.client.lobby_size
            lines = [(self.font_big, "Connected", INK),
                     (self.font, f"to {self.client.address}" + (f" as P{self.client.you + 1}" if self.client.lobby_size else ""), DIM)]
        y = self.centred(screen, lines, 120) + 20
        for i in range(max(count, 1)):
            mine = (self.mode == "host" and i == 0) or (self.client and i == self.client.you)
            who = "you" if mine else "host" if i == 0 else "joined"
            rect = pygame.Rect(WIDTH // 2 - 150, y + i * 44, 300, 36)
            pygame.draw.rect(screen, PANEL, rect, border_radius=6)
            pygame.draw.rect(screen, PLAYER_COLORS_UI[i], rect, 2, border_radius=6)
            screen.blit(self.font.render(f"P{i + 1}  {who}", True, PLAYER_COLORS_UI[i]), (rect.x + 14, rect.y + 8))
        y += 4 * 44 + 10
        hint = ("Enter = start   Esc = stop hosting" if self.mode == "host" else "Waiting for the host to start   Esc = leave")
        self.centred(screen, [(self.font, hint, INK)], y)
        if self.message:
            self.centred(screen, [(self.font, self.message, DANGER)], y + 44)

    def draw_title(self, screen):
        lines = [
            (self.font_big, "ARENA (working title)", INK),
            (self.font, "Mine blocks and ore, craft items, and don't fall out of the map.", DIM),
            (self.font, "Blocks shake, then crumble, faster and faster. Last one standing wins.", DIM),
            (self.font, "", DIM),
            (self.font, "H = host an online game     J = join one     2/3/4 = local players on this PC", INK),
            (self.font, f"Controllers connected: {len(self.joysticks)}", DIM),
            (self.font, "", DIM),
        ] + [(self.font_small, f"{who}:  {text}", DIM) for who, text in KEY_HELP[:1]] + [
            (self.font_small, "Online, everyone uses the P1 controls on their own PC. Local mode adds:", DIM),
        ] + [(self.font_small, f"{who}:  {text}", DIM) for who, text in KEY_HELP[1:]] + [
            (self.font_small, "Craft: hold the craft key, pick a recipe (mouse, wheel, or left/right), let go to craft.", DIM),
            (self.font_small, "Controllers are used automatically by P2, P3, P4.   M = mute   Esc = menu", DIM),
        ]
        y = 70
        for font, text, color in lines:
            surf = font.render(text, True, color)
            screen.blit(surf, (WIDTH // 2 - surf.get_width() // 2, y))
            y += surf.get_height() + 10
        for i, key in enumerate(RECIPES):
            item = ITEMS[key]
            rx, ry = WIDTH // 2 - 310, y + i * 30
            pygame.draw.rect(screen, (34, 38, 72), (rx, ry, 26, 26), border_radius=4)
            draw_icon(screen, key, (rx + 2, ry + 2, 22, 22), INK)
            uses = f"{item['charges']} use" + ("s" if item["charges"] != 1 else "")
            screen.blit(self.font_small.render(item["name"], True, INK), (rx + 34, ry + 6))
            screen.blit(self.font_small.render(f"{item['help']} ({uses})", True, DIM), (rx + 150, ry + 6))
            screen.blit(self.font_small.render(cost_text(key), True, DIM), (rx + 445, ry + 6))
        if self.message:
            m = self.font.render(self.message, True, DANGER)
            screen.blit(m, (WIDTH // 2 - m.get_width() // 2, HEIGHT - 50))
