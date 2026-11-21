"""Particles and synthesized sound effects (no asset files needed)."""
import array
import math
import random

import pygame


class Particles:
    def __init__(self):
        self.items = []
        self.log = None          # host: list to record bursts in, so clients can replay them

    def burst(self, x, y, color, count, speed, life=0.6, size=4, up=0.0):
        if self.log is not None:
            self.log.append(["pt", [round(x, 2), round(y, 2), list(color), count, speed, life, size, up]])
        color = tuple(color)
        for _ in range(count):
            angle = random.uniform(0, math.tau)
            s = random.uniform(0.3, 1.0) * speed
            self.items.append([x, y, math.cos(angle) * s, math.sin(angle) * s - up,
                               random.uniform(0.5, 1.0) * life, color, size])

    def debris(self, tx, ty, color):
        """A block breaking: small chunks thrown up and out of the tile."""
        for _ in range(5):
            self.items.append([tx + random.uniform(0.2, 0.8), ty + random.uniform(0.2, 0.8),
                               random.uniform(-3, 3), random.uniform(-7, -2),
                               random.uniform(0.3, 0.6), color, random.choice((3, 4, 5))])

    def update(self, dt):
        for p in self.items:
            p[0] += p[2] * dt
            p[1] += p[3] * dt
            p[3] += 30 * dt
            p[4] -= dt
        self.items = [p for p in self.items if p[4] > 0]

    def draw(self, screen, to_screen):
        for x, y, _, _, _, color, size in self.items:
            px, py = to_screen(x, y)
            screen.fill(color, (px - size // 2, py - size // 2, size, size))


class Sounds:
    def __init__(self):
        self.enabled = False
        self.muted = False
        self.sounds = {}
        self.last_played = {}
        self.log = None          # host: list to record plays in, so clients hear them too
        try:
            if not pygame.mixer.get_init():
                pygame.mixer.init(22050, -16, 1, 256)
            self.rate, _, self.channels = pygame.mixer.get_init()
        except pygame.error:
            return                              # no audio device: run silently
        self.enabled = True
        self.sounds = {
            "jump": self.tone(300, 620, 0.08, 0.12),
            "mine": self.tone(180, 110, 0.06, 0.25, "tri", noise=0.6),
            "crack": self.tone(420, 300, 0.05, 0.2, "tri", noise=0.5),
            "place": self.tone(170, 110, 0.07, 0.35, "sine"),
            "push": self.tone(520, 180, 0.18, 0.3, "sine", noise=0.7),
            "hit": self.tone(220, 90, 0.12, 0.3, noise=0.4),
            "laser": self.tone(1300, 180, 0.25, 0.16),
            "crumble": self.tone(120, 60, 0.12, 0.12, "tri", noise=0.9),
            "death": self.tone(640, 70, 0.5, 0.22),
            "round": self.chain([(523, 0.09), (659, 0.09), (784, 0.09), (1047, 0.2)], 0.18),
            "go": self.tone(880, 880, 0.12, 0.15, "tri"),
            "craft": self.chain([(660, 0.06), (990, 0.1)], 0.15),
            "nope": self.tone(140, 120, 0.12, 0.15),
            "boost": self.tone(200, 700, 0.2, 0.18, "sine", noise=0.5),
            "grapple": self.tone(900, 1500, 0.1, 0.12, "tri"),
            "boom": self.tone(110, 35, 0.6, 0.4, "tri", noise=0.8),
        }

    def tone(self, f0, f1, dur, vol, wave="square", noise=0.0):
        return pygame.mixer.Sound(buffer=self.samples(f0, f1, dur, vol, wave, noise).tobytes())

    def chain(self, notes, vol):
        buf = array.array("h")
        for freq, dur in notes:
            buf.extend(self.samples(freq, freq, dur, vol, "square", 0.0))
        return pygame.mixer.Sound(buffer=buf.tobytes())

    def samples(self, f0, f1, dur, vol, wave, noise):
        n = int(self.rate * dur)
        buf = array.array("h")
        phase = 0.0
        for i in range(n):
            t = i / n
            phase += (f0 + (f1 - f0) * t) / self.rate
            frac = phase % 1
            if wave == "square":
                v = 1.0 if frac < 0.5 else -1.0
            elif wave == "tri":
                v = 4 * abs(frac - 0.5) - 1
            else:
                v = math.sin(math.tau * phase)
            if noise:
                v = v * (1 - noise) + random.uniform(-1, 1) * noise
            env = min(1.0, i / (self.rate * 0.004)) * (1 - t) ** 2     # tiny attack, quick decay
            sample = int(v * env * vol * 32767)
            for _ in range(self.channels):
                buf.append(sample)
        return buf

    def play(self, name, min_gap=0.0, log=True):
        if log and self.log is not None:
            self.log.append(["snd", [name, min_gap]])
        if not self.enabled or self.muted:
            return
        now = pygame.time.get_ticks() / 1000
        if now - self.last_played.get(name, -1) < min_gap:
            return
        self.last_played[name] = now
        self.sounds[name].play()

