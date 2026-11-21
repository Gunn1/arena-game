# All tunable numbers live here. Distances are in tiles, times in seconds.

# Screen
CELL = 20                 # pixels per tile
COLS, ROWS = 60, 34       # map size in tiles
HUD_H = 64                # pixels of HUD above the map
WIDTH, HEIGHT = COLS * CELL, ROWS * CELL + HUD_H
FPS = 60

# Movement
GRAVITY = 45.0
JUMP_SPEED = 15.0         # about 2.5 tiles high
MOVE_SPEED = 8.0
MAX_FALL = 28.0
PLAYER_W, PLAYER_H = 0.8, 1.6
COYOTE = 0.08             # grace time to jump after walking off a ledge
WALL_JUMP_SPEED = 13.5    # upward speed of a wall jump
WALL_KICK = 11.0          # sideways push away from the wall (fades like knockback)
WALL_SLIDE_SPEED = 4.0    # max fall speed while holding into a wall
WALL_COYOTE = 0.1         # grace time to wall jump after leaving a wall
WALL_LOCK = 0.15          # after a wall jump, walking input is ignored this long so the kick carries you

# Blocks
MINE_COOLDOWN = 0.18
PLACE_COOLDOWN = 0.12
CARRY_LIMIT = 15          # dirt + stone you can carry; stone and ores take 2 hits
ORE_LIMIT = 9             # max copper and max crystal each
SLOTS = 3                 # crafted items a player can hold

# Map generation
TOP_ROW = 9               # no terrain above this row
MIN_FILL = 0.2            # a map must be at least this full of blocks
MAP_MODE = "random"       # "random" = one random map; "mirrored" = identical copied segment per player
FAIR_SPREAD = 0.15        # random maps reroll until spawns are within 15% of each other on ground nearby
FAIR_RADIUS = 6           # "ground nearby" = blocks within this many tiles of the spawn
MIN_NEAR = 35             # never spawn on a spot with fewer blocks than this nearby
ORE_RADIUS = 7            # every spawn gets the same copper and crystal within this many tiles...
ORE_MIN = {"copper": 3, "crystal": 2}   # ...and at least this much

# Crumbling
CRUMBLE_GRACE = 3.0       # seconds before the first block starts to crumble
CRUMBLE_WARN = 1.0        # how long a block shakes before it breaks
CRUMBLE_START = 0.45      # seconds between new crumbles at round start
CRUMBLE_END = 0.05        # ...and after CRUMBLE_RAMP seconds
CRUMBLE_RAMP = 60.0

# Items (costs, charges and cooldowns are in items.py)
PUSH_SPEED = 24.0
PUSH_RANGE = 12
PUSH_KNOCK = 17.0         # sideways speed given to the player hit
PUSH_LIFT = 7.0
KNOCK_DECAY = 5.0         # how fast knockback fades
LASER_LENGTH = 10
LASER_SHOW = 0.25         # how long the beam stays on screen
BOOST_SPEED = 17.0        # Rocket Boost upward speed
GRAPPLE_RANGE = 12
GRAPPLE_SPEED = 24.0
GRAPPLE_TIME = 0.7        # max time being pulled
BOMB_THROW = 13.0
BOMB_FUSE = 1.3
BOMB_RADIUS = 2.3         # blocks destroyed
BOMB_BLAST = 4.0          # players within this are flung
BOMB_KNOCK = 18.0
PLATFORM_WIDTH = 5

# Mouse: this player aims with the mouse (8 directions, same reach as everyone) and
# mines/places with left/right click. Set to None to turn mouse aiming off.
MOUSE_PLAYER = 0

# Online play: TCP port the host listens on
NET_PORT = 7777

# Rounds
ROUNDS_TO_WIN = 3
ROUND_INTRO = 1.5
ROUND_OUTRO = 2.5

PLAYER_COLORS = [(255, 107, 107), (79, 168, 255), (255, 210, 63), (183, 123, 255)]
