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
const JUMP_SPEED := 17.7          # about 3.5 tiles high (v^2 / 2g)
const MOVE_SPEED := 8.0
const MAX_FALL := 28.0
const PLAYER_W := 0.8
const PLAYER_H := 1.6
const COYOTE := 0.08              # grace time to jump after walking off a ledge
const WALL_JUMP_SPEED := 15.5     # about 2.7 tiles
const WALL_KICK := 11.0           # sideways push away from the wall (fades like knockback)
const WALL_SLIDE_SPEED := 4.0     # max fall speed while holding into a wall
const WALL_COYOTE := 0.1
const WALL_LOCK := 0.12           # after a wall jump, walking back into that wall is ignored this long
const WALL_GROUND_GAP := 0.6      # falling this close above ground, jump waits to land instead of wall jumping
const KNOCK_DECAY := 5.0
const ACCEL_GROUND := 70.0        # tiles/s^2 toward the walk speed (MOVE_SPEED * input)
const ACCEL_AIR := 40.0
const FRICTION := 80.0            # slowing down on the ground with no input (ACCEL_AIR * 0.5 in the air)
const JUMP_BUFFER := 0.1          # a jump pressed this long before landing still happens
const JUMP_CUT := 0.45            # letting go of jump while rising multiplies upward speed by this
const FALL_GRAVITY := 1.5         # gravity multiplier while falling
const LAND_SPEED := 12.0          # landing faster than this plays "land"

# Blocks and items
const REACH := 2.5                # mouse targeting: tiles from player centre to tile centre
const BLOCK_REACH := 4.5          # placing special blocks reaches further
# Seconds of holding "mine" to break a tile. Int keys match World's enum (config can't use
# World's names): DIRT=1, STONE=2, PLACED=3, COPPER=4, CRYSTAL=5, SAND=6, ICE=7, SLIME=8,
# LAVA=9 (can't be mined), TNT=10, STEEL=11, FAN_L=12, FAN_R=13, MAGNET=14, TURRET=15.
const MINE_TIME := {1: 0.22, 2: 0.45, 3: 0.18, 4: 0.55, 5: 0.65, 6: 0.12, 7: 0.35, 8: 0.25, 10: 0.3,
	11: 1.6, 12: 0.4, 13: 0.4, 14: 0.4, 15: 0.5}
const PLACE_COOLDOWN := 0.12
const CARRY_LIMIT := 15           # dirt + stone
const ORE_LIMIT := 9
const SLOTS := 3

# Map generation
const TOP_ROW := 9
const MIN_FILL := 0.2
const FAIR_SPREAD := 0.15         # reroll until spawns are within 15% of each other on ground nearby
const FAIR_RADIUS := 6
const MIN_NEAR := 35
# Per ore: every spawn gets the same amount within this many tiles (a square), and at least min
const ORE_NEAR := {"copper": {"radius": 4, "min": 2}, "crystal": {"radius": 6, "min": 1}}

# Biomes and arena shapes: each round the host picks one of each at random
const BIOMES := ["meadow", "desert", "tundra", "volcano", "mushroom"]
const SHAPES := ["islands", "mountain", "towers", "caves"]
const SAND_FALL := 0.12           # unsupported sand drops one tile this often
const ICE_GRIP := 0.25            # on ice, walking speeds up and slows down at this fraction of normal
const SLIME_MIN := 6.0            # landing on slime faster than this bounces you...
const SLIME_BOUNCE := 0.75        # ...back up at this fraction of the landing speed  # < ~0.8 so bounces die out (falling gravity is 1.5x)
const LAVA_LAUNCH := 16.0         # touching lava throws you up at this speed...
const LAVA_DAMAGE := 12.0         # ...and burns this much damage %...
const LAVA_COOLDOWN := 0.5        # ...at most this often
const LAVA_SAFE := 6              # no lava within this many tiles of a spawn (a square), nor below one
const TNT_FUSE := 1.0             # mined or blasted TNT explodes this long later, like a bomb
const TNT_SAFE := 5               # no TNT within this many tiles of a spawn

# Arena: 40 tiles wide for 2 players, +10 per extra player (60 = full screen for 4)
const ARENA_BASE := 20
const ARENA_PER_PLAYER := 10

# The zone: the map crumbles from both edges toward the middle
const ZONE_GRACE := 10.0          # seconds after "go" before the edges start closing
const ZONE_CLOSE_TIME := 90.0     # seconds for the edges to meet in the middle (speeds up as it goes)
const CRUMBLE_WARN := 1.0         # a block shakes this long before it breaks

# Fighting (Smash-style): hits add damage %, and knockback grows with damage %
const SWING_COOLDOWN := 0.35
const SWING_DAMAGE := 8.0
const SWING_KNOCK := 9.0          # knockback speed at 0%
const SWING_REACH := 1.1          # hit box sits this far in front of you (along the exact aim)...
const SWING_BOX := Vector2(1.8, 1.9)   # ...and is this big
const KNOCK_GROWTH := 60.0        # knockback = base * (1 + damage / KNOCK_GROWTH): 2x at 60%, 3x at 120%
const MAX_DAMAGE := 300.0
const STUN_BASE := 0.1            # after a hit you can't walk for STUN_BASE + knock * STUN_PER_KNOCK seconds
const STUN_PER_KNOCK := 0.015
const STUN_DECAY := 1.2           # knockback fades this slowly while stunned (KNOCK_DECAY otherwise)
const KILL_CREDIT := 4.0          # fall within this many seconds of a hit and the hitter gets the KO
const HITSTOP_BASE := 0.04        # the whole game freezes briefly on a hit: base + knock * per, capped
const HITSTOP_PER_KNOCK := 0.003
const HITSTOP_MAX := 0.14

# Special blocks (costs and counts are in items.gd)
const BLOCK_COOLDOWN := 0.25      # between placing two special blocks
const BOUNCE_LAUNCH := 22.0       # a placed bounce pad throws anyone landing on it at least this fast
const FAN_RANGE := 8              # a fan blows along its row this many tiles, stopped by blocks
const FAN_SPEED := 14.0           # ...pushing players toward this sideways speed (weaker far away)
const FAN_ACCEL := 60.0
const MAGNET_RANGE := 6.0         # a magnet pulls everyone within this many tiles toward it
const MAGNET_PULL := 28.0         # tiles/s^2 at the magnet, fading to 0 at the edge
const TURRET_RANGE := 12.0        # a turret shoots at the nearest enemy within this range, in about its row
const TURRET_ROWS := 3.0          # ...up to this many tiles above or below it
const TURRET_RELOAD := 1.4
const MINE_TRIGGER := 1.6         # placed TNT goes off when an enemy gets this close to it...
const MINE_FUSE := 0.35           # ...this long later
const PUSH_SPEED := 22.0          # turret shots
const PUSH_RANGE := 12.0
const PUSH_KNOCK := 13.0
const PUSH_DAMAGE := 9.0
const BOMB_RADIUS := 2.3
const BOMB_BLAST := 4.0
const BOMB_KNOCK := 16.0
const BOMB_DAMAGE := 18.0

# Rounds
const ROUNDS_TO_WIN := 3
const ROUND_INTRO := 1.5
const ROUND_OUTRO := 2.5
const MAX_PLAYERS := 4

# Online
const NET_PORT := 7777
const PUBLIC_SERVER := "arena.tylergunn.me"   # "Play online" on the title screen connects here
# Game version. Online, the host and every player must match exactly: it's sent as the
# WebSocket subprotocol, so a different version can't even connect (no silent breakage).
# The release workflow checks that the git tag (vX.Y.Z) matches this.
const GAME_VERSION := "0.7.0"
const NET_PROTOCOL := "arena-" + GAME_VERSION

const PLAYER_COLORS := [Color(1.0, 0.42, 0.42), Color(0.31, 0.66, 1.0), Color(1.0, 0.82, 0.25), Color(0.72, 0.48, 1.0)]
