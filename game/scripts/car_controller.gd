class_name CarController
extends CharacterBody3D

# Simple arcade car controller using CharacterBody3D so it collides with the
# random boxes (and any other StaticBody3D / RigidBody3D in the world).
#
# Reads ui_up / ui_down / ui_left / ui_right (keyboard arrows OR touch buttons).
# The car_glb is rotated +90° around Y in the scene so its forward axis aligns
# with this CharacterBody3D's local -Z (Godot's standard forward direction).

@export var max_speed: float = 18.0          # m/s, top speed
@export var acceleration: float = 10.0       # m/s² when holding accelerator
@export var brake_force: float = 16.0        # m/s² when braking from forward
@export var deceleration: float = 6.0        # m/s² when no input
@export var max_steer: float = 0.8           # max steering radians (~46°)
@export var steer_lerp: float = 4.0          # how fast steering settles
@export var turn_speed: float = 1.6          # turn rate scalar
@export var wheel_anim_scale: float = 3.0    # how fast wheel anim plays at top speed

# Boost — fires once per "boost" press, lasts boost_duration seconds.
# After boosting ends, the player cannot re-trigger until boost_cooldown
# seconds have elapsed. While boosting: top speed ×= boost_speed_mult and
# push_factor (impulse on hit RigidBodies) jumps from normal_ to boost_.
@export var boost_duration: float = 2.0
@export var boost_cooldown: float = 10.0
@export var boost_speed_mult: float = 2.5
@export var normal_push_factor: float = 0.60
@export var boost_push_factor: float = 2.0

# Gravity so the car falls back down whenever a box pushes it up an inclined
# surface. Higher value = snappier "snap to ground" after any contact bump.
@export var gravity: float = 80.0

var speed: float = 0.0
var steer_angle: float = 0.0
var boost_timer: float = 0.0          # > 0 while currently boosting
var cooldown_timer: float = 0.0       # > 0 while waiting before next boost is allowed

@onready var car_model: Node3D = $CarModel
var anim_player: AnimationPlayer = null


func _ready() -> void:
	anim_player = car_model.find_child("AnimationPlayer", true, false)
	if anim_player and anim_player.has_animation("Drive"):
		anim_player.play("Drive")
		anim_player.speed_scale = 0.0

	# Treat any surface steeper than ~15° as a wall instead of a climbable slope.
	# Box edges / tilted boxes are well above 15°, so the car stops and slides
	# along them instead of riding up onto them like a ramp.
	floor_max_angle = deg_to_rad(15.0)
	# When pressed against a wall, slide along it — don't try to climb.
	floor_block_on_wall = true


func _physics_process(delta: float) -> void:
	# --- Boost trigger / timer / cooldown --------------------------------------
	# Tick the active-boost timer. When it expires, start the cooldown.
	if boost_timer > 0.0:
		boost_timer = maxf(0.0, boost_timer - delta)
		if boost_timer <= 0.0:
			cooldown_timer = boost_cooldown
	elif cooldown_timer > 0.0:
		cooldown_timer = maxf(0.0, cooldown_timer - delta)

	var can_boost: bool = boost_timer <= 0.0 and cooldown_timer <= 0.0
	if Input.is_action_just_pressed("boost") and can_boost:
		boost_timer = boost_duration

	var boosting: bool = boost_timer > 0.0
	var effective_max_speed: float = max_speed * (boost_speed_mult if boosting else 1.0)
	# ---------------------------------------------------------------------------

	var accel_in := Input.get_action_strength("ui_up") - Input.get_action_strength("ui_down")
	var steer_in := Input.get_action_strength("ui_left") - Input.get_action_strength("ui_right")

	# While boosting, force forward acceleration regardless of input
	if boosting:
		accel_in = 1.0

	# Acceleration / braking / coast
	if accel_in > 0.0:
		speed = move_toward(speed, effective_max_speed, acceleration * (3.0 if boosting else 1.0) * delta)
	elif accel_in < 0.0:
		if speed > 0.5:
			speed = move_toward(speed, 0.0, brake_force * delta)
		else:
			speed = move_toward(speed, -max_speed * 0.5, acceleration * delta)
	else:
		speed = move_toward(speed, 0.0, deceleration * delta)

	# Smoothed steering
	var target_steer := steer_in * max_steer
	steer_angle = lerp(steer_angle, target_steer, clamp(steer_lerp * delta, 0.0, 1.0))

	# Steer the chassis
	if absf(speed) > 0.05:
		rotate_y(steer_angle * (speed / max_speed) * turn_speed * delta)

	# Drive forward (Car's local -Z) and let CharacterBody3D resolve collisions.
	# Force the horizontal motion to stay strictly in the XZ plane (forward.y
	# could pick up a tiny non-zero from accumulated rotation drift), then let
	# gravity drive Y. Without this, sliding up a tilted box surface keeps the
	# car suspended in mid-air after the impact.
	var forward := -global_transform.basis.z
	var prev_y_velocity: float = velocity.y
	velocity.x = forward.x * speed
	velocity.z = forward.z * speed
	if is_on_floor():
		# Small constant downward velocity keeps is_on_floor() true on flat ground
		velocity.y = -2.0
	else:
		velocity.y = prev_y_velocity - gravity * delta
	# Don't let collisions launch us upward — clamp positive Y motion before
	# the slide so the algorithm can never give us a free kick into the air.
	velocity.y = minf(velocity.y, 0.0)
	move_and_slide()
	# Same clamp after the slide: if a tilted-box impact rotated our velocity
	# upward, kill it so it can't carry into the next physics tick.
	if velocity.y > 0.0:
		velocity.y = 0.0

	# Push any RigidBody3D we hit. Apply impulse at the contact point so the
	# box gets both linear push and a torque (so it tumbles when hit at a corner).
	# push_factor scales transferred velocity per contact frame: higher = boxes
	# fly further; the formula impulse = speed * mass * factor means a box
	# gains roughly `speed * factor` m/s per frame of contact regardless of its
	# own mass (heavier boxes need more impulse for the same delta-v).
	var push_factor: float = boost_push_factor if boosting else normal_push_factor
	for i in range(get_slide_collision_count()):
		var col: KinematicCollision3D = get_slide_collision(i)
		var rb: RigidBody3D = col.get_collider() as RigidBody3D
		if rb == null:
			continue
		var push_dir: Vector3 = -col.get_normal()
		var contact_offset: Vector3 = col.get_position() - rb.global_position
		var impulse_mag: float = absf(speed) * rb.mass * push_factor
		rb.apply_impulse(push_dir * impulse_mag, contact_offset)
		# Tell the box it was hit so it starts pulsing colors. While the car is
		# in boost mode, boxes pulse much faster (4× the normal cycle rate).
		if rb.has_method("on_hit"):
			var pulse_speed: float = 4.0 if boosting else 1.0
			rb.call("on_hit", pulse_speed)
		# Tiny speed scrub on contact (3% per frame) so we still feel the
		# impact without slamming to a stop on every box.
		speed *= 0.97

	# After collision resolution, sync our scalar speed with the actual forward
	# component of velocity so that ramming a wall scrubs off speed instead of
	# leaving the car pinned and "trying" to push through.
	speed = velocity.dot(forward)

	# Drive the wheel-spin animation proportional to ground speed
	if anim_player:
		anim_player.speed_scale = (speed / max_speed) * wheel_anim_scale
