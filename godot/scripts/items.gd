## Craftable items. Every item moves players or blocks; none of them does damage.
## To add one: an entry in ITEMS, an icon in draw_icon, and its effect in GameSim.use_item.
class_name Items

const MATERIALS := ["dirt", "stone", "copper", "crystal"]
const MATERIAL_COLORS := {"dirt": Color(0.54, 0.35, 0.2), "stone": Color(0.47, 0.48, 0.57),
	"copper": Color(0.9, 0.55, 0.24), "crystal": Color(0.35, 0.88, 0.94)}

const ITEMS := {
	"push": {"name": "Push Wand", "cost": {"dirt": 3}, "charges": 3, "cooldown": 0.8,
		"help": "knocks a player away"},
	"boost": {"name": "Rocket Boost", "cost": {"stone": 1, "copper": 1}, "charges": 3, "cooldown": 0.4,
		"help": "blast upward, works mid-air"},
	"platform": {"name": "Platform", "cost": {"dirt": 4, "copper": 1}, "charges": 1, "cooldown": 0.5,
		"help": "5 blocks under your feet"},
	"grapple": {"name": "Grapple", "cost": {"stone": 2, "copper": 1}, "charges": 3, "cooldown": 0.5,
		"help": "pulls you to a block"},
	"bomb": {"name": "Bomb", "cost": {"stone": 1, "copper": 1, "crystal": 1}, "charges": 2, "cooldown": 1.0,
		"help": "blows a hole, flings players"},
	"laser": {"name": "Laser", "cost": {"stone": 2, "crystal": 1}, "charges": 2, "cooldown": 1.5,
		"help": "cuts a line of blocks"},
}
const RECIPES := ["push", "boost", "platform", "grapple", "bomb", "laser"]
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


## Small picture of an item, drawn with shapes so there are no image files.
static func draw_icon(ci: CanvasItem, key: String, r: Rect2, color: Color, dim := false) -> void:
	var c := r.get_center()
	var s := r.size.x
	var ink := Color(0.43, 0.44, 0.55) if dim else color
	var white := Color(0.51, 0.51, 0.59) if dim else Color.WHITE
	match key:
		"push":
			for i in 3:
				var rad := s * (0.18 + 0.12 * i)
				ci.draw_arc(c - Vector2(s * 0.1, 0), rad, -0.9, 0.9, 8, ink if i else white, 2.0)
		"boost":
			ci.draw_colored_polygon(PackedVector2Array([Vector2(c.x, r.position.y + 3), Vector2(c.x + s * 0.3, c.y + 2), Vector2(c.x - s * 0.3, c.y + 2)]), ink)
			ci.draw_rect(Rect2(c.x - s * 0.12, c.y, s * 0.24, s * 0.22), ink)
			ci.draw_colored_polygon(PackedVector2Array([Vector2(c.x - s * 0.12, r.end.y - s * 0.25), Vector2(c.x + s * 0.12, r.end.y - s * 0.25), Vector2(c.x, r.end.y - 2)]),
				ink if dim else Color(1.0, 0.67, 0.24))
		"platform":
			ci.draw_rect(Rect2(r.position.x + 3, c.y + 2, s - 6, s * 0.2), ink)
			ci.draw_line(Vector2(c.x, r.position.y + 4), Vector2(c.x, c.y - 2), white, 2.0)
			ci.draw_colored_polygon(PackedVector2Array([Vector2(c.x - 4, c.y - 5), Vector2(c.x + 4, c.y - 5), Vector2(c.x, c.y)]), white)
		"grapple":
			ci.draw_line(Vector2(r.position.x + 4, r.end.y - 4), Vector2(c.x + 3, c.y - 3), white, 2.0)
			ci.draw_arc(Vector2(c.x + s * 0.18, r.position.y + s * 0.3), s * 0.2, PI, TAU * 0.95, 10, ink, 3.0)
		"bomb":
			ci.draw_circle(Vector2(c.x - 1, c.y + 2), s * 0.3, ink)
			ci.draw_line(Vector2(c.x + s * 0.12, c.y - s * 0.18), Vector2(c.x + s * 0.3, r.position.y + 3), white, 2.0)
			ci.draw_circle(Vector2(c.x + s * 0.3, r.position.y + 3), 2.0, ink if dim else Color(1.0, 0.78, 0.31))
		"laser":
			ci.draw_line(Vector2(r.position.x + 3, r.end.y - 3), Vector2(r.end.x - 3, r.position.y + 3), ink, 5.0)
			ci.draw_line(Vector2(r.position.x + 3, r.end.y - 3), Vector2(r.end.x - 3, r.position.y + 3), white, 1.0)
