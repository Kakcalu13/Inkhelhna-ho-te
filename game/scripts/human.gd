class_name Human
extends CharacterBody3D

# Basic Human AI — runs in a straight line away from the car when threatened,
# walks around when idle, points if the parked car is facing them, falls when
# hit by a flying box. No path planning, no jumping over obstacles. For the
# upgraded version see GoldenHuman (golden_human.gd / scenes/golden_human.tscn).
#
# States:
#   IDLE_WALK  — wander casually around the spawn point. Plays "Walk".
#   FLEE       — run directly away from the car. Plays "Run".
#   POINT      — face the parked car and point. Plays "Point".
#   FALLEN     — knocked down by a fast box. Plays "Fall" and stays still.
#
# `is_in_camera` is updated by VisibleOnScreenNotifier3D so other code can
# read it (e.g. only spawn humans you can see, trigger events on visibility).

enum State { IDLE_WALK, FLEE, POINT, FALLEN }

@export var walk_speed: float = 1.4
@export var run_speed: float = 5.5
@export var flee_distance: float = 9.0       # car within this AND moving → flee
@export var safe_distance: float = 15.0      # car beyond this → calm down
@export var point_distance: float = 7.0      # car within this AND idle+facing → point
@export var car_idle_speed_threshold: float = 1.0
@export var car_facing_dot_threshold: float = 0.65   # cos(~50°)
@export var wander_radius: float = 8.0
@export var wander_change_interval: float = 3.0
@export var bubble_cooldown_seconds: float = 4.0
@export var flee_bubble_offset: Vector3 = Vector3(0.0, 5.0, 0.0)
@export var point_bubble_offset: Vector3 = Vector3(0.0, 2.4, 0.0)
@export var bubble_scale: Vector3 = Vector3(0.20, 0.20, 0.20)
@export var gravity: float = 25.0
@export var hit_velocity_threshold: float = 1.5

# When two humans bump, they pause, face each other, play Point, and pop a
# greeting bubble.
@export var meet_duration: float = 2.5
@export var meet_cooldown: float = 5.0
@export var meet_bubble_offset: Vector3 = Vector3(0.0, 2.4, 0.0)

# Language pool. Regular Human picks RANDOMLY from any bubble in the registry
# whose filename does NOT end with this suffix. New non-_mz images you drop
# in assets/images/ are picked up automatically. Set this to "" if you want
# the regular human to consider every bubble, including Mizo ones.
@export var avoid_bubble_suffix: String = "_mz"

# Specific bubble name for the FLEE state — the human always shouts the same
# thing when running from the car. Leave blank to fall back to a random pick
# from the language pool. Other states (point/meet) still pick from the pool.
@export var flee_bubble_name: String = "oh_no"

var state: State = State.IDLE_WALK
var spawn_position: Vector3
var wander_target: Vector3
var wander_timer: float = 0.0
var bubble_cooldown: float = 0.0

# Meet-other-human (zawnga) state
var meet_timer: float = 0.0
var meet_cooldown_timer: float = 0.0
var meet_target: Node3D = null

var car: Node3D = null
var is_in_camera: bool = false

@onready var anim_player: AnimationPlayer = find_child("AnimationPlayer", true, false)
@onready var notifier: VisibleOnScreenNotifier3D = $VisibleOnScreenNotifier3D
@onready var hit_area: Area3D = $HitArea


func _ready() -> void:
	add_to_group("humans")
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


func _physics_process(delta: float) -> void:
	bubble_cooldown = maxf(0.0, bubble_cooldown - delta)
	meet_cooldown_timer = maxf(0.0, meet_cooldown_timer - delta)

	# Gravity
	if is_on_floor() and velocity.y <= 0.0:
		velocity.y = -2.0
	else:
		velocity.y -= gravity * delta

	if state == State.FALLEN:
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	# Meet-another-human takes precedence: stop, face the other, hold Point.
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
		move_and_slide()
		return

	_decide_state()

	match state:
		State.FLEE:
			_do_flee()
		State.POINT:
			_do_point()
		State.IDLE_WALK:
			_do_wander(delta)

	move_and_slide()
	_check_meet_collisions()


# After move_and_slide, see if any of our slide collisions was another human;
# if so, both sides will independently start the zawnga reaction.
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
	var away: Vector3 = global_position - car.global_position
	away.y = 0.0
	if away.length() < 0.001:
		away = Vector3.RIGHT
	away = away.normalized() * run_speed
	velocity.x = away.x
	velocity.z = away.z
	_face_direction(Vector3(away.x, 0, away.z))
	_play("Run")
	_spawn_bubble_from_pool(flee_bubble_offset, flee_bubble_name)


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


# Spawn a bubble. If `specific_name` is non-empty, look that up exactly; if
# the registry has no bubble by that name, fall back to a random pick from
# this character's language pool (every registered bubble whose filename
# does NOT end in avoid_bubble_suffix). Pass "" to always use the pool.
func _spawn_bubble_from_pool(offset: Vector3 = Vector3(0.0, 2.4, 0.0),
		specific_name: String = "") -> void:
	if bubble_cooldown > 0.0:
		return
	var tex: Texture2D = null
	if specific_name != "":
		var registry: Node = get_node_or_null("/root/BubbleRegistry")
		if registry != null:
			tex = registry.call("get_texture", specific_name)
	if tex == null:
		tex = _pick_pool_texture()
	if tex == null:
		return
	var BubbleScript: GDScript = load("res://scripts/bubble.gd")
	BubbleScript.spawn(get_parent(), global_position + offset, tex, bubble_scale)
	bubble_cooldown = bubble_cooldown_seconds


func _pick_pool_texture() -> Texture2D:
	var registry: Node = get_node_or_null("/root/BubbleRegistry")
	if registry == null:
		return null
	if avoid_bubble_suffix == "":
		return registry.call("random_texture")
	return registry.call("random_without_suffix", avoid_bubble_suffix)


# ---------- Hit detection ----------
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
