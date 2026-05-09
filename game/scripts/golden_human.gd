class_name GoldenHuman
extends CharacterBody3D

# The "smart" / "premium" variant of Human:
#   - Smart flee — samples N directions, scores each by (predicted distance
#     from car) − (penalty for boxes in the way), picks the best
#   - Box-jump — if a RigidBody3D blocks the chosen path, briefly squats then
#     vertically launches and sails over the box on the way down
#   - Gold material override on every visible mesh, so you can tell them apart
#     from a regular Human at a glance
#
# Same state machine (IDLE_WALK / FLEE / POINT / FALLEN) as Human, same bubble
# system, same camera-visibility flag.

enum State { IDLE_WALK, FLEE, POINT, FALLEN }

@export var walk_speed: float = 1.4
@export var run_speed: float = 5.5
@export var flee_distance: float = 9.0
@export var safe_distance: float = 15.0
@export var point_distance: float = 7.0
@export var car_idle_speed_threshold: float = 1.0
@export var car_facing_dot_threshold: float = 0.65
@export var wander_radius: float = 8.0
@export var wander_change_interval: float = 3.0
@export var bubble_cooldown_seconds: float = 4.0
@export var flee_bubble_offset: Vector3 = Vector3(0.0, 5.0, 0.0)
@export var point_bubble_offset: Vector3 = Vector3(0.0, 2.4, 0.0)
@export var bubble_scale: Vector3 = Vector3(0.20, 0.20, 0.20)
@export var gravity: float = 25.0
@export var hit_velocity_threshold: float = 1.5

# Meet-another-human reaction. Triggered by collision with any Human or
# GoldenHuman.
@export var meet_duration: float = 2.5
@export var meet_cooldown: float = 5.0
@export var meet_bubble_offset: Vector3 = Vector3(0.0, 2.4, 0.0)

# Language pool. GoldenHuman picks RANDOMLY from any registered bubble whose
# filename ends with this suffix. Drop new "_mz" images into assets/images/
# and they auto-join the pool — no code or scene edits needed.
@export var require_bubble_suffix: String = "_mz"

# Box-jump tunables
@export var box_jump_squat_duration: float = 0.18
@export var box_jump_velocity: float = 11.0

# Smart-flee tunables
@export var flee_sample_count: int = 12
@export var flee_lookahead: float = 1.2
@export var flee_obstacle_penalty: float = 100.0
@export var flee_recompute_interval: float = 0.4

# Gold tinting
@export var gold_albedo: Color = Color(1.0, 0.78, 0.05, 1.0)
@export var gold_metallic: float = 0.95
@export var gold_roughness: float = 0.18
@export var gold_emission_strength: float = 0.0   # 0 = no glow, bump for radiant gold

var state: State = State.IDLE_WALK
var spawn_position: Vector3
var wander_target: Vector3
var wander_timer: float = 0.0
var bubble_cooldown: float = 0.0

var jump_phase: int = 0
var jump_timer: float = 0.0

var _flee_direction: Vector3 = Vector3.ZERO
var _flee_recompute_timer: float = 0.0

# Meet-other-human (zawnga) state
var meet_timer: float = 0.0
var meet_cooldown_timer: float = 0.0
var meet_target: Node3D = null

var car: Node3D = null
var is_in_camera: bool = false

@onready var anim_player: AnimationPlayer = find_child("AnimationPlayer", true, false)
@onready var notifier: VisibleOnScreenNotifier3D = $VisibleOnScreenNotifier3D
@onready var hit_area: Area3D = $HitArea
@onready var forward_ray: RayCast3D = $ForwardRay


func _ready() -> void:
	add_to_group("humans")
	add_to_group("golden_humans")
	spawn_position = global_position
	wander_target = _pick_wander_target()

	if notifier != null:
		notifier.screen_entered.connect(func(): is_in_camera = true)
		notifier.screen_exited.connect(func(): is_in_camera = false)

	if hit_area != null:
		hit_area.body_entered.connect(_on_hit_area_body_entered)

	var cars: Array = get_tree().get_nodes_in_group("player_vehicles")
	if not cars.is_empty():
		car = cars[0] as Node3D

	if anim_player != null:
		_play("Walk")

	_apply_gold_skin()


func _physics_process(delta: float) -> void:
	bubble_cooldown = maxf(0.0, bubble_cooldown - delta)
	meet_cooldown_timer = maxf(0.0, meet_cooldown_timer - delta)

	if state == State.FALLEN:
		velocity.x = 0.0
		velocity.z = 0.0
		_apply_gravity(delta)
		move_and_slide()
		return

	# Meet-another-human takes precedence over jump / smart flee / wander.
	if meet_timer > 0.0:
		meet_timer -= delta
		velocity.x = 0.0
		velocity.z = 0.0
		if meet_target != null and is_instance_valid(meet_target):
			var to_other: Vector3 = meet_target.global_position - global_position
			to_other.y = 0.0
			if to_other.length() > 0.001:
				_face_direction(to_other.normalized())
		_play("Point")
		if meet_timer <= 0.0:
			meet_cooldown_timer = meet_cooldown
			meet_target = null
		_apply_gravity(delta)
		move_and_slide()
		return

	if jump_phase != 0:
		_do_jump(delta)
		_apply_gravity(delta)
		move_and_slide()
		if jump_phase == 2 and is_on_floor() and velocity.y <= 0.0:
			jump_phase = 0
		return

	_decide_state()

	match state:
		State.FLEE:
			_do_flee()
			if forward_ray and forward_ray.is_colliding():
				var hit := forward_ray.get_collider()
				if hit is RigidBody3D:
					_start_jump_over_box()
		State.POINT:
			_do_point()
		State.IDLE_WALK:
			_do_wander(delta)

	_apply_gravity(delta)
	move_and_slide()
	_check_meet_collisions()


func _check_meet_collisions() -> void:
	if meet_timer > 0.0 or meet_cooldown_timer > 0.0:
		return
	for i in range(get_slide_collision_count()):
		var col: KinematicCollision3D = get_slide_collision(i)
		var other: Object = col.get_collider()
		if other == self or other == null:
			continue
		if other is Human or other is GoldenHuman:
			_on_meet_other(other as Node3D)
			return


func _on_meet_other(other: Node3D) -> void:
	meet_timer = meet_duration
	meet_target = other
	# Bypass the normal bubble cooldown — this is a one-off event bubble.
	var tex: Texture2D = _pick_pool_texture()
	if tex == null:
		return
	var BubbleScript: GDScript = load("res://scripts/bubble.gd")
	BubbleScript.spawn(get_parent(),
			global_position + meet_bubble_offset, tex, bubble_scale)


func _apply_gravity(delta: float) -> void:
	if is_on_floor() and velocity.y <= 0.0:
		velocity.y = -2.0
	else:
		velocity.y -= gravity * delta


# ---------- Box jump ----------
func _start_jump_over_box() -> void:
	jump_phase = 1
	jump_timer = box_jump_squat_duration
	velocity.x = 0.0
	velocity.z = 0.0
	_play("Squat")


func _do_jump(delta: float) -> void:
	if jump_phase == 1:
		jump_timer -= delta
		if jump_timer <= 0.0:
			jump_phase = 2
			velocity.y = box_jump_velocity
			if car != null:
				var away: Vector3 = global_position - car.global_position
				away.y = 0.0
				if away.length() > 0.001:
					away = away.normalized() * run_speed
					velocity.x = away.x
					velocity.z = away.z
			_play("JumpAngry")


# ---------- State decision ----------
func _decide_state() -> void:
	if car == null:
		state = State.IDLE_WALK
		return

	var to_car: Vector3 = car.global_position - global_position
	to_car.y = 0.0
	var dist: float = to_car.length()

	var car_speed: float = 0.0
	if "speed" in car:
		car_speed = absf(car.get("speed"))

	if dist < flee_distance and car_speed > car_idle_speed_threshold:
		state = State.FLEE
		return

	if state == State.FLEE and dist < safe_distance:
		return

	if dist < point_distance and car_speed <= car_idle_speed_threshold:
		var car_forward: Vector3 = -car.global_transform.basis.z
		car_forward.y = 0.0
		car_forward = car_forward.normalized()
		var to_self_dir: Vector3 = -to_car.normalized()
		if car_forward.dot(to_self_dir) > car_facing_dot_threshold:
			state = State.POINT
			return

	state = State.IDLE_WALK


# ---------- Per-state behavior ----------
func _do_flee() -> void:
	_flee_recompute_timer -= get_physics_process_delta_time()
	if _flee_recompute_timer <= 0.0 or _flee_direction == Vector3.ZERO:
		_flee_direction = _smart_flee_direction()
		_flee_recompute_timer = flee_recompute_interval

	var dir: Vector3 = _flee_direction
	if dir.length() < 0.001:
		dir = (global_position - car.global_position)
		dir.y = 0.0
		if dir.length() < 0.001:
			dir = Vector3.RIGHT
		dir = dir.normalized()

	velocity.x = dir.x * run_speed
	velocity.z = dir.z * run_speed
	_face_direction(dir)
	_play("Run")
	_spawn_bubble_from_pool(flee_bubble_offset)


func _smart_flee_direction() -> Vector3:
	if car == null:
		return Vector3.ZERO

	var car_pos: Vector3 = car.global_position
	var car_velocity: Vector3 = Vector3.ZERO
	if "speed" in car:
		var car_forward: Vector3 = -car.global_transform.basis.z
		car_forward.y = 0.0
		car_velocity = car_forward.normalized() * absf(car.get("speed"))

	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var origin: Vector3 = global_position + Vector3.UP * 0.6

	# Offset of human from car at t=0 — used in the analytical closest-approach
	# calculation below. With both moving in straight lines:
	#   R(t) = R0 + Rv * t          where Rv = human_velocity - car_velocity
	#   |R(t)|² is minimized at t* = -R0·Rv / |Rv|²
	# Clamping t* to [0, lookahead] gives the closest distance over the window.
	var R0: Vector3 = global_position - car_pos

	var best_dir: Vector3 = Vector3.ZERO
	var best_score: float = -INF

	for i in flee_sample_count:
		var angle: float = float(i) * TAU / float(flee_sample_count)
		var dir: Vector3 = Vector3(cos(angle), 0.0, sin(angle))

		# Closest approach between human (running this direction) and the car
		# anywhere in the [0, flee_lookahead] window — i.e. the worst-case
		# distance during the window. Maximize this across directions.
		var hv: Vector3 = dir * run_speed
		var rv: Vector3 = hv - car_velocity
		var t_closest: float = 0.0
		var rv_lensq: float = rv.length_squared()
		if rv_lensq > 0.0001:
			t_closest = clamp(-R0.dot(rv) / rv_lensq, 0.0, flee_lookahead)
		var r_at: Vector3 = R0 + rv * t_closest
		var score: float = r_at.length()

		# Penalize directions blocked by a physics body (box / car itself)
		var ray_target: Vector3 = origin + dir * (run_speed * 0.4)
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				origin, ray_target, 1)
		query.exclude = [self]
		var hit: Dictionary = space_state.intersect_ray(query)
		if not hit.is_empty():
			var collider: Object = hit.collider
			if collider is RigidBody3D or collider == car:
				score -= flee_obstacle_penalty

		if score > best_score:
			best_score = score
			best_dir = dir

	return best_dir


func _do_point() -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	var to_car: Vector3 = car.global_position - global_position
	to_car.y = 0.0
	if to_car.length() > 0.001:
		_face_direction(to_car.normalized())
	_play("Point")
	_spawn_bubble_from_pool(point_bubble_offset)


func _do_wander(delta: float) -> void:
	wander_timer -= delta
	var to_target: Vector3 = wander_target - global_position
	to_target.y = 0.0
	if wander_timer <= 0.0 or to_target.length() < 0.6:
		wander_target = _pick_wander_target()
		wander_timer = wander_change_interval
		to_target = wander_target - global_position
		to_target.y = 0.0

	var dir: Vector3 = to_target.normalized()
	velocity.x = dir.x * walk_speed
	velocity.z = dir.z * walk_speed
	_face_direction(dir)
	_play("Walk")


# ---------- Helpers ----------
func _pick_wander_target() -> Vector3:
	var angle: float = randf() * TAU
	var dist: float = randf_range(2.0, wander_radius)
	return spawn_position + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)


func _face_direction(dir: Vector3) -> void:
	if dir.length_squared() < 0.0001:
		return
	var target: Vector3 = global_position + Vector3(dir.x, 0, dir.z)
	look_at(target, Vector3.UP)


func _play(anim_name: String) -> void:
	if anim_player == null:
		return
	if anim_player.current_animation != anim_name and anim_player.has_animation(anim_name):
		anim_player.play(anim_name)


# Pick a random bubble from the Mizo pool ("any bubble whose filename ends
# in require_bubble_suffix") and spawn it. Add a new _mz image to
# assets/images/ and it's automatically eligible.
func _spawn_bubble_from_pool(offset: Vector3 = Vector3(0.0, 2.4, 0.0)) -> void:
	if bubble_cooldown > 0.0:
		return
	var tex: Texture2D = _pick_pool_texture()
	if tex == null:
		return
	var BubbleScript: GDScript = load("res://scripts/bubble.gd")
	BubbleScript.spawn(get_parent(), global_position + offset, tex, bubble_scale)
	bubble_cooldown = bubble_cooldown_seconds


func _pick_pool_texture() -> Texture2D:
	var registry: Node = get_node_or_null("/root/BubbleRegistry")
	if registry == null:
		return null
	if require_bubble_suffix == "":
		return registry.call("random_texture")
	return registry.call("random_with_suffix", require_bubble_suffix)


func _on_hit_area_body_entered(body: Node) -> void:
	if state == State.FALLEN:
		return
	if body is RigidBody3D:
		var rb: RigidBody3D = body as RigidBody3D
		if rb.linear_velocity.length() > hit_velocity_threshold:
			_fall()


func _fall() -> void:
	state = State.FALLEN
	# Cancel any in-progress meet so the fallen pose isn't fighting with Point
	meet_timer = 0.0
	meet_target = null
	_play("Fall")


# ---------- Gold skin ----------
# Override every MeshInstance3D's material with a shiny gold StandardMaterial3D
# so the golden human reads as visually distinct from the regular Human.
func _apply_gold_skin() -> void:
	var gold: StandardMaterial3D = StandardMaterial3D.new()
	gold.albedo_color = gold_albedo
	gold.metallic = gold_metallic
	gold.roughness = gold_roughness
	if gold_emission_strength > 0.0:
		gold.emission_enabled = true
		gold.emission = gold_albedo
		gold.emission_energy_multiplier = gold_emission_strength

	var stack: Array = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			(n as MeshInstance3D).material_override = gold
		for child in n.get_children():
			stack.append(child)
