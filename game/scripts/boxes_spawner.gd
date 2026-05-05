extends Node3D

# Spawns N random RigidBody3D boxes with mass + gravity around the world, so
# the car can knock them over with realistic physics. Each box also gets the
# box.gd script attached, which makes the box pulse colors continuously the
# first time it's hit (until scene reload).
# Boxes never spawn within `car_clear_radius` of the world origin (where the
# car starts), and we do a simple bounding-circle check so two boxes don't
# overlap when picked.

const BOX_SCRIPT: Script = preload("res://scripts/box.gd")

@export var box_count: int = 35
@export var area_radius: float = 50.0       # max distance from origin
@export var car_clear_radius: float = 7.0   # keep this radius around the car spawn empty
@export var min_size: float = 0.7
@export var max_size: float = 1.8
@export var density: float = 0.5            # mass per cubic meter
@export var random_seed: int = 7331


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed

	var placed: Array[Vector3] = []      # x, z, half-diagonal radius
	var spawned: int = 0
	var attempts: int = 0

	while spawned < box_count and attempts < box_count * 20:
		attempts += 1
		var pos := Vector3(
			rng.randf_range(-area_radius, area_radius),
			0.0,
			rng.randf_range(-area_radius, area_radius)
		)
		# Skip spawn area
		if Vector2(pos.x, pos.z).length() < car_clear_radius:
			continue

		var size := Vector3(
			rng.randf_range(min_size, max_size),
			rng.randf_range(min_size, max_size),
			rng.randf_range(min_size, max_size)
		)
		var half_diag := Vector2(size.x, size.z).length() * 0.5

		# Avoid overlap with previously placed boxes
		var overlap := false
		for p in placed:
			var d := Vector2(pos.x - p.x, pos.z - p.y).length()
			if d < half_diag + p.z + 0.4:  # 0.4m breathing room
				overlap = true
				break
		if overlap:
			continue

		_spawn_box(pos, size, rng)
		placed.append(Vector3(pos.x, pos.z, half_diag))
		spawned += 1


func _spawn_box(pos: Vector3, size: Vector3, rng: RandomNumberGenerator) -> void:
	var body := RigidBody3D.new()
	# Sit the box on the ground collision plane (top at y = 0) so its
	# collision overlaps the car's vertical range.
	body.position = pos + Vector3(0, size.y * 0.5, 0)
	body.rotate_y(rng.randf_range(0.0, TAU))
	body.mass = maxf(0.15, size.x * size.y * size.z * density)
	body.linear_damp = 0.15
	body.angular_damp = 0.4
	body.name = "Box%d" % get_child_count()

	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_inst.mesh = box_mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(
		rng.randf_range(0.30, 0.95),
		rng.randf_range(0.30, 0.95),
		rng.randf_range(0.30, 0.95)
	)
	mat.roughness = 0.7
	mat.metallic = rng.randf_range(0.0, 0.3)
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	# Attach the per-box script AFTER children are added so its _ready can
	# find the MeshInstance3D and grab the material reference
	body.set_script(BOX_SCRIPT)
	add_child(body)
