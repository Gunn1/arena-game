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
