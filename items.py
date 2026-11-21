"""Craftable items. Every item moves players or blocks; none of them does damage.

To add an item: add an entry to ITEMS, an icon in draw_icon, and its effect in Game.use_item.
"""
import math

import pygame

MATERIALS = ("dirt", "stone", "copper", "crystal")
MATERIAL_COLORS = {"dirt": (138, 90, 51), "stone": (120, 122, 146), "copper": (230, 140, 60), "crystal": (90, 225, 240)}

ITEMS = {
    "push":     {"name": "Push Wand",    "cost": {"dirt": 3},                               "charges": 3, "cooldown": 0.8,
                 "help": "knocks a player away"},
    "boost":    {"name": "Rocket Boost", "cost": {"stone": 1, "copper": 1},                 "charges": 3, "cooldown": 0.4,
                 "help": "blast upward, works mid-air"},
    "platform": {"name": "Platform",     "cost": {"dirt": 4, "copper": 1},                  "charges": 1, "cooldown": 0.5,
                 "help": "5 blocks under your feet"},
    "grapple":  {"name": "Grapple",      "cost": {"stone": 2, "copper": 1},                 "charges": 3, "cooldown": 0.5,
                 "help": "pulls you to a block"},
    "bomb":     {"name": "Bomb",         "cost": {"stone": 1, "copper": 1, "crystal": 1},   "charges": 2, "cooldown": 1.0,
                 "help": "blows a hole, flings players"},
    "laser":    {"name": "Laser",        "cost": {"stone": 2, "crystal": 1},                "charges": 2, "cooldown": 1.5,
                 "help": "cuts a line of blocks"},
}
RECIPES = list(ITEMS)       # order shown in the crafting menu


def cost_text(key):
    return " ".join(f"{n} {m}" for m, n in ITEMS[key]["cost"].items())


def draw_icon(screen, key, rect, color, dim=False):
    """Small picture for an item, drawn with shapes so there are no image files."""
    r = pygame.Rect(rect)
    cx, cy, s = r.centerx, r.centery, r.width
    ink = (110, 112, 140) if dim else color
    white = (130, 130, 150) if dim else (255, 255, 255)
    if key == "push":
        for i, rad in enumerate((s * 0.18, s * 0.3, s * 0.42)):
            pygame.draw.arc(screen, ink if i else white, (cx - rad - s * 0.1, cy - rad, rad * 2, rad * 2), -0.9, 0.9, 2)
    elif key == "boost":
        pygame.draw.polygon(screen, ink, [(cx, r.top + 3), (cx + s * 0.3, cy + 2), (cx - s * 0.3, cy + 2)])
        pygame.draw.rect(screen, ink, (cx - s * 0.12, cy, s * 0.24, s * 0.22))
        pygame.draw.polygon(screen, (255, 170, 60) if not dim else ink,
                            [(cx - s * 0.12, r.bottom - s * 0.25), (cx + s * 0.12, r.bottom - s * 0.25), (cx, r.bottom - 2)])
    elif key == "platform":
        pygame.draw.rect(screen, ink, (r.left + 3, cy + 2, s - 6, s * 0.2))
        pygame.draw.line(screen, white, (cx, r.top + 4), (cx, cy - 2), 2)
        pygame.draw.polygon(screen, white, [(cx - 4, cy - 5), (cx + 4, cy - 5), (cx, cy)])
    elif key == "grapple":
        pygame.draw.line(screen, white, (r.left + 4, r.bottom - 4), (cx + 3, cy - 3), 2)
        pygame.draw.arc(screen, ink, (cx - 2, r.top + 3, s * 0.4, s * 0.4), 0, math.pi * 1.3, 3)
    elif key == "bomb":
        pygame.draw.circle(screen, ink, (cx - 1, cy + 2), s * 0.3)
        pygame.draw.line(screen, white, (cx + s * 0.12, cy - s * 0.18), (cx + s * 0.3, r.top + 3), 2)
        pygame.draw.circle(screen, (255, 200, 80) if not dim else ink, (int(cx + s * 0.3), r.top + 3), 2)
    elif key == "laser":
        pygame.draw.line(screen, ink, (r.left + 3, r.bottom - 3), (r.right - 3, r.top + 3), 5)
        pygame.draw.line(screen, white, (r.left + 3, r.bottom - 3), (r.right - 3, r.top + 3), 1)
