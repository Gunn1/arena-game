## Every tunable number. Distances are in tiles, times in seconds.
class_name Cfg

# Screen
const CELL := 20                  # pixels per tile
const COLS := 60
const ROWS := 34
const HUD_H := 64
const WIDTH := COLS * CELL
const HEIGHT := ROWS * CELL + HUD_H
const DT := 1.0 / 60.0

# Movement
const GRAVITY := 45.0
const JUMP_SPEED := 15.0          # about 2.5 tiles high
const MOVE_SPEED := 8.0
const MAX_FALL := 28.0
const PLAYER_W := 0.8
const PLAYER_H := 1.6
const COYOTE := 0.08              # grace time to jump after walking off a ledge
const WALL_JUMP_SPEED := 13.5
const WALL_KICK := 11.0           # sideways push away from the wall (fades like knockback)
const WALL_SLIDE_SPEED := 4.0     # max fall speed while holding into a wall
const WALL_COYOTE := 0.1
const WALL_LOCK := 0.15           # after a wall jump, walking is ignored this long
const KNOCK_DECAY := 5.0

# Blocks and items
const MINE_COOLDOWN := 0.18
const PLACE_COOLDOWN := 0.12
const CARRY_LIMIT := 15           # dirt + stone; stone and ores take 2 hits
const ORE_LIMIT := 9
const SLOTS := 3

# Map generation
const TOP_ROW := 9
const MIN_FILL := 0.2
const FAIR_SPREAD := 0.15         # reroll until spawns are within 15% of each other on ground nearby
const FAIR_RADIUS := 6
const MIN_NEAR := 35
const ORE_RADIUS := 7             # every spawn gets the same ore within this many tiles...
const ORE_MIN := {"copper": 3, "crystal": 2}   # ...and at least this much

# Crumbling
const CRUMBLE_GRACE := 3.0
const CRUMBLE_WARN := 1.0
const CRUMBLE_START := 0.45
const CRUMBLE_END := 0.05
const CRUMBLE_RAMP := 60.0

# Item strengths (costs, uses and cooldowns are in items.gd)
const PUSH_SPEED := 24.0
const PUSH_RANGE := 12.0
const PUSH_KNOCK := 17.0
const PUSH_LIFT := 7.0
const LASER_LENGTH := 10
const LASER_SHOW := 0.25
const BOOST_SPEED := 17.0
const GRAPPLE_RANGE := 12
const GRAPPLE_SPEED := 24.0
const GRAPPLE_TIME := 0.7
const BOMB_THROW := 13.0
const BOMB_FUSE := 1.3
const BOMB_RADIUS := 2.3
const BOMB_BLAST := 4.0
const BOMB_KNOCK := 18.0
const PLATFORM_WIDTH := 5

# Rounds
const ROUNDS_TO_WIN := 3
const ROUND_INTRO := 1.5
const ROUND_OUTRO := 2.5
const MAX_PLAYERS := 4

# Online
const NET_PORT := 7777

const PLAYER_COLORS := [Color(1.0, 0.42, 0.42), Color(0.31, 0.66, 1.0), Color(1.0, 0.82, 0.25), Color(0.72, 0.48, 1.0)]
