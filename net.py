"""Online play. The host runs the real game; everyone else sends inputs and draws what the host sends.

Messages are JSON, one per line, over TCP:
  client -> host  {"t": "hello"}                 then every frame {"t": "in", "s": {...inputs}, "w": wheel}
  host -> client  {"t": "lobby", "you": i, "n": players}
                  {"t": "grid", ...}             whole map, at the start of every round
                  {"t": "s", ...}                snapshot, every frame
                  {"t": "bye", "why": "..."}
"""
import json
import socket
import subprocess

from config import NET_PORT, CRUMBLE_WARN, PLAYER_COLORS
from controls import ACTIONS

MAX_BUFFER = 4_000_000          # drop a client that stops reading


class Conn:
    """Non-blocking line-based JSON connection."""

    def __init__(self, sock):
        sock.setblocking(False)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock = sock
        self.inbuf = b""
        self.outbuf = b""
        self.closed = False

    def send(self, obj):
        if self.closed:
            return
        self.outbuf += (json.dumps(obj, separators=(",", ":")) + "\n").encode()
        if len(self.outbuf) > MAX_BUFFER:
            self.close()
            return
        self.flush()

    def flush(self):
        while self.outbuf and not self.closed:
            try:
                sent = self.sock.send(self.outbuf)
            except BlockingIOError:
                return
            except OSError:
                self.close()
                return
            self.outbuf = self.outbuf[sent:]

    def recv(self):
        msgs = []
        while not self.closed:
            try:
                data = self.sock.recv(65536)
            except BlockingIOError:
                break
            except OSError:
                self.close()
                break
            if not data:
                self.close()
                break
            self.inbuf += data
        while b"\n" in self.inbuf:
            line, self.inbuf = self.inbuf.split(b"\n", 1)
            try:
                msgs.append(json.loads(line))
            except ValueError:
                self.close()
                break
        return msgs

    def close(self):
        if not self.closed:
            self.closed = True
            try:
                self.sock.close()
            except OSError:
                pass


class RemoteControls:
    """A remote player's inputs, as received by the host."""
    slot_labels = ("Q", "E", "R")
    craft_label = "F"
    mouse = False

    def __init__(self, conn):
        self.conn = conn
        self.state = {a: False for a in ACTIONS}
        self.pending = []
        self.wheel = 0

    def feed(self, state, wheel):
        self.pending.append(state)
        self.wheel += wheel

    def read(self, pressed):
        if self.pending:
            last = self.pending[-1]
            self.state = {a: bool(last.get(a)) for a in ACTIONS}
            self.state["mouse"] = tuple(last["mouse"]) if last.get("mouse") else None
            out = dict(self.state)
            # Several input frames can arrive between two host frames. Keep any button that was
            # pressed in one of them, so a quick tap isn't lost.
            for s in self.pending[:-1]:
                for a in ACTIONS:
                    if s.get(a):
                        out[a] = True
            self.pending.clear()
        else:
            out = dict(self.state)
        out["wheel"], self.wheel = self.wheel, 0
        return out


def local_addresses():
    """Addresses a friend could use to reach this machine (Tailscale first)."""
    found = []
    try:
        out = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=1).stdout
        found += [(ip.strip(), "Tailscale") for ip in out.split() if ip.strip()]
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.254.254.254", 1))           # no packet is sent; this just picks the LAN interface
            found.append((s.getsockname()[0], "LAN"))
    except OSError:
        pass
    return found


# --- host ---------------------------------------------------------------------------------

class Host:
    def __init__(self, port=NET_PORT):
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("", port))
        self.listener.listen()
        self.listener.setblocking(False)
        self.clients = []                       # Conn, in join order; client i is player i + 1
        self.addresses = local_addresses()
        self.port = port
        self.sent_version = None

    def close(self):
        for c in self.clients:
            c.send({"t": "bye", "why": "host left"})
            c.flush()
            c.close()
        self.listener.close()

    def accept(self, game):
        while True:
            try:
                sock, _ = self.listener.accept()
            except BlockingIOError:
                return
            conn = Conn(sock)
            if game.state != "lobby" or len(self.clients) >= len(PLAYER_COLORS) - 1:
                conn.send({"t": "bye", "why": "game full or already started"})
                conn.flush()
                conn.close()
                continue
            self.clients.append(conn)
            self.send_lobby()

    def send_lobby(self):
        for i, c in enumerate(self.clients):
            c.send({"t": "lobby", "you": i + 1, "n": len(self.clients) + 1})

    def poll(self, game):
        """Accept joins, read inputs, drop dead connections. Call once per frame before updating."""
        self.accept(game)
        for c in self.clients:
            for msg in c.recv():
                if msg.get("t") == "in":
                    player = next((p for p in game.players if getattr(p.controls, "conn", None) is c), None)
                    if player:
                        player.controls.feed(msg.get("s", {}), int(msg.get("w", 0)))
        gone = [c for c in self.clients if c.closed]
        if gone:
            self.clients = [c for c in self.clients if not c.closed]
            for p in game.players:
                if getattr(p.controls, "conn", None) in gone:
                    p.alive = False                     # left mid-match: counts as out
            if game.state == "lobby":
                self.send_lobby()

    def broadcast(self, game):
        """Send this frame's state to everyone. Call once per frame after updating."""
        w = game.world
        if game.state == "lobby":
            for c in self.clients:
                c.flush()
            return
        if self.sent_version != w.version:
            self.sent_version = w.version
            grid_msg = {"t": "grid", "g": w.grid, "cr": [list(t) for t in w.cracked],
                        "wa": [[x, y, round(t, 2)] for (x, y), t in w.warnings.items()]}
            for c in self.clients:
                c.send(grid_msg)
        snap = snapshot(game)
        for c in self.clients:
            c.send(snap)
        w.changes.clear()
        game.events.clear()


def r(v):
    return round(v, 3)


def snapshot(game):
    idx = {id(p): i for i, p in enumerate(game.players)}
    return {
        "t": "s", "st": game.state, "tm": r(game.timer), "rd": game.round, "msg": game.message,
        "sh": r(game.shake),
        "p": [[r(p.x), r(p.y), p.facing, list(p.aim), p.alive, p.crafting, p.recipe,
               p.inv, [[s["item"], s["charges"]] if s else None for s in p.slots], r(p.item_cd), p.wins,
               [r(v) for v in p.grapple[:2]] if p.grapple else None] for p in game.players],
        "ch": game.world.changes,
        "pr": [[r(x["x"]), r(x["y"]), idx[id(x["owner"])]] for x in game.projectiles],
        "bo": [[r(b["x"]), r(b["y"]), r(b["fuse"]), idx[id(b["owner"])]] for b in game.bombs],
        "be": [[*map(r, b["from"]), *map(r, b["to"]), idx.get(id(b.get("owner")), 0), r(b["time"])] for b in game.beams],
        "ev": game.events,
    }


# --- client -------------------------------------------------------------------------------

class Client:
    def __init__(self, address, port=NET_PORT):
        host, _, maybe_port = address.strip().partition(":")
        sock = socket.create_connection((host, int(maybe_port or port)), timeout=4)
        self.conn = Conn(sock)
        self.conn.send({"t": "hello"})
        self.address = address
        self.you = 0
        self.lobby_size = 0
        self.wheel = 0

    def close(self):
        self.conn.close()

    def send_input(self, state):
        self.conn.send({"t": "in", "s": state, "w": self.wheel})
        self.wheel = 0

    def poll(self, game):
        """Apply everything the host sent. Returns a reason string if disconnected."""
        for msg in self.conn.recv():
            kind = msg.get("t")
            if kind == "lobby":
                self.you, self.lobby_size = msg["you"], msg["n"]
            elif kind == "grid":
                apply_grid(game, msg)
            elif kind == "s":
                apply_snapshot(game, msg, self.you)
            elif kind == "bye":
                self.conn.close()
                return msg.get("why", "disconnected")
        if self.conn.closed:
            return "lost connection to host"
        self.conn.flush()
        return None


def apply_grid(game, msg):
    w = game.world
    w.grid = msg["g"]
    w.cracked = {tuple(t) for t in msg["cr"]}
    w.warnings = {(x, y): t for x, y, t in msg["wa"]}
    w.broken.clear()
    game.particles.items.clear()


def apply_snapshot(game, msg, you):
    from player import Player                    # here to avoid an import loop
    from controls import KeyboardControls

    if len(game.players) != len(msg["p"]):
        game.players = [Player(i, KeyboardControls("p1_mouse", mouse=True) if i == you else None)
                        for i in range(len(msg["p"]))]
    game.state, game.timer, game.round, game.message = msg["st"], msg["tm"], msg["rd"], msg["msg"]
    game.shake = max(game.shake, msg["sh"])
    for p, s in zip(game.players, msg["p"]):
        (p.x, p.y, p.facing, aim, p.alive, p.crafting, p.recipe, p.inv, slots, p.item_cd, p.wins, grapple) = s
        p.aim = tuple(aim)
        p.slots = [{"item": a, "charges": b} if a else None for a, b in (sl or (None, None) for sl in slots)]
        p.grapple = (*grapple, 0) if grapple else None
    w = game.world
    for change in msg["ch"]:
        if change[0] == "t":
            _, x, y, tile, cause = change
            w.set(x, y, tile, cause)
        elif change[0] == "c":
            w.cracked.add((change[1], change[2]))
        elif change[0] == "w":
            w.warnings[(change[1], change[2])] = CRUMBLE_WARN
    players = game.players
    game.projectiles = [{"x": x, "y": y, "owner": players[o]} for x, y, o in msg["pr"]]
    game.bombs = [{"x": x, "y": y, "fuse": f, "owner": players[o]} for x, y, f, o in msg["bo"]]
    game.beams = [{"from": (a, b), "to": (c, d), "color": players[o].color, "time": t}
                  for a, b, c, d, o, t in msg["be"]]
    for kind, args in msg["ev"]:
        if kind == "snd":
            game.sounds.play(*args)
        elif kind == "pt":
            game.particles.burst(*args)
