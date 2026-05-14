extends Node3D

# Spawns N regular Human instances at random positions on the ground. For
# each one:
#   - Picks a random .glb from assets/humans/
#   - Derives `gender` from the filename — "female*" -> female, "male*" -> male
#   - Swaps the human's "Model" child for the chosen GLB
#
# Uses Godot's group / ConversationManager wiring already on Human, so the
# new spawns talk to each other automatically when they bump.
#
# Doesn't touch GoldenHuman (which has its own scene).

@export var human_count: int = 6
@export var area_radius: float = 35.0       # half-extent of the spawn square (m)
@export var car_clear_radius: float = 10.0  # don't spawn within this radius of (0,0)
@export var min_spacing: float = 3.0        # min distance between two spawned humans
@export var random_seed: int = 314

const HUMAN_SCENE: PackedScene = preload("res://scenes/human.tscn")
const HUMAN_GLB_DIR: String = "res://assets/humans/"


func _ready() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = random_seed

	var glbs: Array = _list_human_glbs()
	if glbs.is_empty():
		push_warning("HumansSpawner: no GLBs found in %s" % HUMAN_GLB_DIR)
		return

	var placed: Array = []   # Vector2 (xz) of spawned humans
	var spawned: int = 0
	var attempts: int = 0

	while spawned < human_count and attempts < human_count * 20:
		attempts += 1
		var x: float = rng.randf_range(-area_radius, area_radius)
		var z: float = rng.randf_range(-area_radius, area_radius)

		# Keep clear of the car spawn at world origin
		if Vector2(x, z).length() < car_clear_radius:
			continue

		# Keep some breathing room between humans we just placed
		var p: Vector2 = Vector2(x, z)
		var too_close: bool = false
		for q in placed:
			if p.distance_to(q) < min_spacing:
				too_close = true
				break
		if too_close:
			continue

		var glb_path: String = glbs[rng.randi() % glbs.size()]
		_spawn_human(Vector3(x, 0.0, z), glb_path)
		placed.append(p)
		spawned += 1


func _spawn_human(world_pos: Vector3, glb_path: String) -> void:
	var human: CharacterBody3D = HUMAN_SCENE.instantiate()

	# Derive gender from the GLB filename. "female_3.glb" -> "female",
	# "male.glb" / "male_2.glb" -> "male".
	var fname: String = glb_path.get_file().get_basename()
	var gender_value: String = "male"
	if fname.to_lower().begins_with("female"):
		gender_value = "female"
	human.set("gender", gender_value)
	human.name = "%s_%d" % [fname, get_child_count()]

	# Swap the default Model child for the randomly-picked GLB BEFORE adding
	# to the tree so _ready (which calls find_child("AnimationPlayer")) sees
	# the right model.
	var old_model: Node = human.get_node_or_null("Model")
	if old_model != null:
		human.remove_child(old_model)
		old_model.queue_free()

	var packed: PackedScene = load(glb_path) as PackedScene
	if packed != null:
		var new_model: Node = packed.instantiate()
		new_model.name = "Model"
		human.add_child(new_model)

	add_child(human)
	human.global_position = world_pos


func _list_human_glbs() -> Array:
	var paths: Array = []
	var dir: DirAccess = DirAccess.open(HUMAN_GLB_DIR)
	if dir == null:
		return paths
	dir.list_dir_begin()
	var f: String = dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.to_lower().ends_with(".glb"):
			paths.append(HUMAN_GLB_DIR + f)
		f = dir.get_next()
	dir.list_dir_end()
	paths.sort()  # deterministic ordering for the seeded RNG
	return paths
