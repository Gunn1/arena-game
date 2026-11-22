## Craftable special blocks. You place them like blocks (further away), and each one does
## something to players around it. To add one: an entry in ITEMS (with its World tile), a look in
## main.gd's tile painting, and its effect in Player._fields (movement) or GameSim (host-only).
class_name Items

const MATERIALS := ["dirt", "stone", "copper", "crystal"]
const MATERIAL_COLORS := {"dirt": Color(0.54, 0.35, 0.2), "stone": Color(0.47, 0.48, 0.57),
	"copper": Color(0.9, 0.55, 0.24), "crystal": Color(0.35, 0.88, 0.94)}

# "tile" is what gets placed (a fan picks left, right or up from where you aim it).
const ITEMS := {
	"ladder": {"name": "Ladder", "cost": {"dirt": 2}, "charges": 4, "tile": World.LADDER,
		"help": "climb it: up/jump climbs, down slides"},
	"ice": {"name": "Ice", "cost": {"dirt": 1, "stone": 1}, "charges": 2, "tile": World.ICE,
		"help": "slippery: hard to stop on"},
	"fake": {"name": "Fake Block", "cost": {"dirt": 2, "stone": 1}, "charges": 3, "tile": World.FAKE,
		"help": "looks like dirt, you fall right through"},
	"fan": {"name": "Fan", "cost": {"dirt": 3}, "charges": 2, "tile": World.FAN_R,
		"help": "blows players away (aim it sideways or up)"},
	"glue": {"name": "Glue", "cost": {"dirt": 2, "copper": 1}, "charges": 3, "tile": World.GLUE,
		"help": "slows anyone walking on it, weak jumps"},
	"bounce": {"name": "Bounce Pad", "cost": {"dirt": 2, "copper": 1}, "charges": 3, "tile": World.BOUNCE,
		"help": "launches anyone who steps on it"},
	"trapdoor": {"name": "Trapdoor", "cost": {"stone": 2, "copper": 1}, "charges": 3, "tile": World.TRAPDOOR,
		"help": "drops away under enemies"},
	"steel": {"name": "Steel", "cost": {"stone": 3, "copper": 1}, "charges": 4, "tile": World.STEEL,
		"help": "slow to mine, bombproof"},
	"magnet": {"name": "Magnet", "cost": {"stone": 1, "copper": 2}, "charges": 2, "tile": World.MAGNET,
		"help": "pulls everyone nearby toward it"},
	"spikes": {"name": "Spikes", "cost": {"stone": 2, "crystal": 1}, "charges": 3, "tile": World.SPIKES,
		"help": "hurts and throws anyone who touches it"},
	"bumper": {"name": "Bumper", "cost": {"stone": 2, "copper": 2}, "charges": 2, "tile": World.BUMPER,
		"help": "flings back anyone who runs into it"},
	"heal": {"name": "Healing Spring", "cost": {"copper": 1, "crystal": 1}, "charges": 1, "tile": World.HEAL,
		"help": "stand by it to heal (anyone can)"},
	"mine": {"name": "Mine", "cost": {"stone": 1, "copper": 1, "crystal": 1}, "charges": 2, "tile": World.TNT,
		"help": "TNT that blows when an enemy gets close"},
	"turret": {"name": "Turret", "cost": {"stone": 2, "copper": 1, "crystal": 1}, "charges": 1, "tile": World.TURRET,
		"help": "shoots at enemies in range"},
}
const RECIPES := ["ladder", "ice", "fake", "fan", "glue", "bounce", "trapdoor", "steel", "magnet",
	"spikes", "bumper", "heal", "mine", "turret"]
const MATERIAL_VALUE := {"dirt": 1, "stone": 1, "copper": 3, "crystal": 5}


## How valuable an item is: what its materials are worth.
static func item_value(key: String) -> int:
	var cost: Dictionary = ITEMS[key]["cost"]
	var total := 0
	for m: String in cost:
		var amount: int = cost[m]
		var worth: int = MATERIAL_VALUE[m]
		total += amount * worth
	return total


static func can_afford(key: String, inv: Dictionary) -> bool:
	var cost: Dictionary = ITEMS[key]["cost"]
	for m: String in cost:
		var have: int = inv.get(m, 0)
		var need: int = cost[m]
		if have < need:
			return false
	return true


## The most valuable recipe you can pay for (ties: the later one), or "" if none.
static func best_affordable(inv: Dictionary) -> String:
	var best := ""
	var best_value := -1
	for key: String in RECIPES:
		if can_afford(key, inv) and item_value(key) >= best_value:
			best = key
			best_value = item_value(key)
	return best


## Material units still missing for a recipe.
static func _missing_units(key: String, inv: Dictionary) -> int:
	var cost: Dictionary = ITEMS[key]["cost"]
	var total := 0
	for m: String in cost:
		var have: int = inv.get(m, 0)
		var need: int = cost[m]
		total += maxi(0, need - have)
	return total


## e.g. "need 2 stone, 1 copper", or "" if affordable.
static func missing_text(key: String, inv: Dictionary) -> String:
	var cost: Dictionary = ITEMS[key]["cost"]
	var parts := PackedStringArray()
	for m: String in MATERIALS:
		if not cost.has(m):
			continue
		var have: int = inv.get(m, 0)
		var need: int = cost[m]
		if have < need:
			parts.append("%d %s" % [need - have, m])
	if parts.is_empty():
		return ""
	return "need " + ", ".join(parts)


## The recipe closest to affordable: fewest missing units (ties: cheaper, then earlier).
static func next_goal(inv: Dictionary) -> String:
	var best := ""
	var best_missing := 0
	var best_value := 0
	for key: String in RECIPES:
		var missing := _missing_units(key, inv)
		var value := item_value(key)
		if best == "" or missing < best_missing or (missing == best_missing and value < best_value):
			best = key
			best_missing = missing
			best_value = value
	return best


static func cost_text(key: String) -> String:
	var parts := []
	var cost: Dictionary = ITEMS[key]["cost"]
	for m in cost:
		parts.append("%d %s" % [cost[m], m])
	return " ".join(parts)


## Small picture of an item: its block, drawn with shapes so there are no image files.
static func draw_icon(ci: CanvasItem, key: String, r: Rect2, color: Color, dim := false) -> void:
	var tile: int = ITEMS[key]["tile"]
	draw_block(ci, tile, r.grow(-2), dim)


## A special block's look, for icons and for the map (main.gd paints the same shapes into its atlas).
static func block_color(tile: int) -> Color:
	match tile:
		World.STEEL: return Color(0.62, 0.66, 0.72)
		World.FAN_L, World.FAN_R: return Color(0.36, 0.62, 0.78)
		World.MAGNET: return Color(0.78, 0.22, 0.26)
		World.TURRET: return Color(0.34, 0.36, 0.42)
		World.BOUNCE: return Color(0.98, 0.7, 0.2)
		World.TNT: return Color(0.8, 0.16, 0.14)
		World.FAN_U: return Color(0.36, 0.62, 0.78)
		World.SPIKES: return Color(0.3, 0.3, 0.36)
		World.TRAPDOOR: return Color(0.6, 0.42, 0.24)
		World.LADDER: return Color(0.72, 0.52, 0.3)
		World.BUMPER: return Color(0.95, 0.35, 0.65)
		World.GLUE: return Color(0.9, 0.86, 0.55)
		World.HEAL: return Color(0.3, 0.75, 0.45)
		World.ICE: return Color(0.6, 0.84, 0.97)
		World.FAKE: return Color(0.54, 0.35, 0.2)
	return Color.WHITE


static func draw_block(ci: CanvasItem, tile: int, r: Rect2, dim := false) -> void:
	var base := block_color(tile)
	if dim:
		base = base.lerp(Color(0.4, 0.41, 0.5), 0.6)
	var white := Color(0.85, 0.85, 0.9) if dim else Color.WHITE
	var c := r.get_center()
	var s := r.size.x
	if tile == World.LADDER:
		# Not a block: two rails and rungs on a see-through tile.
		ci.draw_line(Vector2(r.position.x + s * 0.2, r.position.y), Vector2(r.position.x + s * 0.2, r.end.y), base, maxf(2.0, s * 0.12))
		ci.draw_line(Vector2(r.end.x - s * 0.2, r.position.y), Vector2(r.end.x - s * 0.2, r.end.y), base, maxf(2.0, s * 0.12))
		for i in 3:
			var y := r.position.y + s * (0.2 + 0.3 * i)
			ci.draw_line(Vector2(r.position.x + s * 0.2, y), Vector2(r.end.x - s * 0.2, y), base.lightened(0.15), maxf(1.5, s * 0.1))
		return
	if tile == World.SPIKES:
		ci.draw_rect(Rect2(r.position.x, c.y, s, s * 0.5), base)
		for i in 3:
			var x0 := r.position.x + s * i / 3.0
			ci.draw_colored_polygon(PackedVector2Array([Vector2(x0, c.y + 1), Vector2(x0 + s / 6.0, r.position.y + 1),
				Vector2(x0 + s / 3.0, c.y + 1)]), Color(0.82, 0.84, 0.9) if not dim else white)
		return
	ci.draw_rect(r, base)
	ci.draw_rect(r, base.darkened(0.4), false, 1.0)
	match tile:
		World.STEEL:
			for d: Vector2 in [Vector2(0.22, 0.22), Vector2(0.78, 0.22), Vector2(0.22, 0.78), Vector2(0.78, 0.78)]:
				ci.draw_circle(r.position + d * s, maxf(1.0, s * 0.07), base.darkened(0.45))
		World.FAN_L, World.FAN_R, World.FAN_U:
			var d := Vector2(-1, 0) if tile == World.FAN_L else (Vector2(0, -1) if tile == World.FAN_U else Vector2(1, 0))
			var n := Vector2(-d.y, d.x)
			for i in 3:
				var o := n * s * (0.25 * i - 0.25)
				ci.draw_line(c + o - d * s * 0.3, c + o + d * s * 0.3, white, 1.5)
			ci.draw_colored_polygon(PackedVector2Array([c + d * s * 0.42, c + d * s * 0.18 + n * s * 0.2,
				c + d * s * 0.18 - n * s * 0.2]), white)
		World.MAGNET:
			ci.draw_arc(Vector2(c.x, c.y - s * 0.05), s * 0.26, 0.0, PI, 10, white, maxf(2.0, s * 0.14))
			ci.draw_rect(Rect2(c.x - s * 0.33, c.y - s * 0.3, s * 0.14, s * 0.24), white)
			ci.draw_rect(Rect2(c.x + s * 0.19, c.y - s * 0.3, s * 0.14, s * 0.24), white)
		World.TURRET:
			ci.draw_circle(c, s * 0.26, base.lightened(0.25))
			ci.draw_circle(c, s * 0.12, Color(1.0, 0.35, 0.3) if not dim else white)
		World.BOUNCE:
			for i in 3:
				var y := r.position.y + s * (0.3 + 0.2 * i)
				ci.draw_polyline(PackedVector2Array([Vector2(r.position.x + s * 0.15, y), Vector2(c.x - s * 0.15, y - s * 0.1),
					Vector2(c.x + s * 0.15, y), Vector2(r.end.x - s * 0.15, y - s * 0.1)]), white, 1.5)
		World.TNT:
			ci.draw_rect(Rect2(r.position.x, c.y - s * 0.12, s, s * 0.24), Color(0.95, 0.9, 0.8))
			ci.draw_circle(Vector2(c.x, r.position.y + s * 0.15), maxf(1.5, s * 0.08), Color(1.0, 0.8, 0.3))
		World.TRAPDOOR:
			for i in 3:
				var x := r.position.x + s * (0.17 + 0.33 * i)
				ci.draw_line(Vector2(x, r.position.y + 2), Vector2(x, r.end.y - 2), base.darkened(0.35), 1.5)
			ci.draw_line(Vector2(r.position.x + 2, c.y), Vector2(r.end.x - 2, c.y), Color(0.25, 0.25, 0.3), 2.0)
			ci.draw_circle(Vector2(r.position.x + s * 0.2, c.y), maxf(1.0, s * 0.08), Color(0.7, 0.7, 0.75))
		World.BUMPER:
			ci.draw_circle(c, s * 0.34, base.lightened(0.3))
			ci.draw_circle(c, s * 0.2, white)
			ci.draw_circle(c, s * 0.1, base)
		World.GLUE:
			for i in 3:
				var x := r.position.x + s * (0.2 + 0.3 * i)
				ci.draw_line(Vector2(x, r.position.y), Vector2(x, r.position.y + s * (0.3 + 0.15 * (i % 2))), base.darkened(0.25), maxf(2.0, s * 0.12))
		World.HEAL:
			ci.draw_rect(Rect2(c.x - s * 0.1, c.y - s * 0.3, s * 0.2, s * 0.6), white)
			ci.draw_rect(Rect2(c.x - s * 0.3, c.y - s * 0.1, s * 0.6, s * 0.2), white)
		World.ICE:
			ci.draw_line(r.position + Vector2(s * 0.2, s * 0.7), r.position + Vector2(s * 0.6, s * 0.3), white, 1.5)
		World.FAKE:
			ci.draw_rect(Rect2(r.position.x, r.position.y, s, s * 0.25), Color(0.45, 0.75, 0.3))
			ci.draw_string(ThemeDB.fallback_font, Vector2(c.x - s * 0.12, r.end.y - s * 0.12), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, int(s * 0.55), white)
