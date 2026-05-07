extends Node

# Autoload singleton — at game start, walks res://assets/images/ and registers
# every PNG (except *_original.png backups) as a named bubble texture.
# Drop a new image into that folder, restart, and it's instantly available
# via BubbleRegistry.get_texture("yourname").

const IMAGE_DIR: String = "res://assets/images/"

var bubbles: Dictionary = {}   # String basename (e.g. "wow") -> Texture2D


func _ready() -> void:
	refresh()


func refresh() -> void:
	bubbles.clear()
	var dir := DirAccess.open(IMAGE_DIR)
	if dir == null:
		push_warning("BubbleRegistry: cannot open %s" % IMAGE_DIR)
		return
	dir.list_dir_begin()
	var f: String = dir.get_next()
	while f != "":
		if not dir.current_is_dir() \
				and f.to_lower().ends_with(".png") \
				and not f.to_lower().ends_with("_original.png"):
			var key: String = f.get_basename()
			var path: String = IMAGE_DIR + f
			var tex: Texture2D = load(path) as Texture2D
			if tex != null:
				bubbles[key] = tex
		f = dir.get_next()
	dir.list_dir_end()
	print("BubbleRegistry: %d bubbles registered: %s" %
			[bubbles.size(), str(bubbles.keys())])


func has_bubble(bubble_name: String) -> bool:
	return bubbles.has(bubble_name)


func get_texture(bubble_name: String) -> Texture2D:
	return bubbles.get(bubble_name)


func random_texture() -> Texture2D:
	if bubbles.is_empty():
		return null
	var keys: Array = bubbles.keys()
	return bubbles[keys[randi() % keys.size()]]


func random_name() -> String:
	if bubbles.is_empty():
		return ""
	var keys: Array = bubbles.keys()
	return keys[randi() % keys.size()]


# Language-tagged bubble pools. Convention: any filename ending in "_mz" (e.g.
# zawnga_mz.png) is in the Mizo pool; everything else is the default pool.
# Use these so Human (regular) can pull from non-Mizo only and GoldenHuman can
# pull from Mizo only.

func random_with_suffix(suffix: String) -> Texture2D:
	if suffix == "":
		return random_texture()
	var pool: Array = []
	for key in bubbles.keys():
		if key.ends_with(suffix):
			pool.append(bubbles[key])
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]


func random_without_suffix(suffix: String) -> Texture2D:
	if suffix == "":
		return random_texture()
	var pool: Array = []
	for key in bubbles.keys():
		if not key.ends_with(suffix):
			pool.append(bubbles[key])
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]
