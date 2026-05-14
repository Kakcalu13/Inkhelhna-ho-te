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

# Gender — used by ConversationManager to look up which conversation file to
# play when this human meets another. "female" or "male" are the values that
# match the JSON filenames; default is "female".
@export var gender: String = "female"

# When two humans bump, they pause, face each other, play Point, and play
# back a randomly-selected conversation from the matching gender-pair JSON.
# meet_cooldown gates re-triggers so they don't loop while still touching.
@export var meet_duration: float = 2.5
@export var meet_cooldown: float = 5.0
@export var meet_bubble_offset: Vector3 = Vector3(0.0, 2.4, 0.0)
# Each conversation line stays on screen for this many seconds. Total meet
# duration with a conversation = line_duration × line_count.
@export var line_duration: float = 2.5
# A conversation is only abandoned mid-line when the car gets THIS close
# while moving — independent of the normal flee_distance, so people don't
# flinch the moment a car drives by, but they DO scatter if it nearly hits
# them. Keep this smaller than flee_distance for the "let it get closer
# during a chat" feel.
@export var conversation_break_distance: float = 3.5

# Language pool. Regular Human picks RANDOMLY from any bubble in the registry
# whose filename does NOT end with this suffix. New non-_mz images you drop
# in assets/images/ are picked up automatically. Set this to "" if you want
# the regular human to consider every bubble, including Mizo ones.
@export var avoid_bubble_suffix: String = "_mz"

# Specific bubble name per reaction. Leave any of these blank to fall back
# to a random pick from the language pool.
#   FLEE  -> "oh_no!"  (running from car)
#   POINT -> "wow!"    (idle car nearby, facing the human)
@export var flee_bubble_name: String = "oh_no"
@export var point_bubble_name: String = "wow"

var state: State = State.IDLE_WALK
var spawn_position: Vector3
var wander_target: Vector3
var wander_timer: float = 0.0
var bubble_cooldown: float = 0.0

# Meet-other-human (zawnga) state
var meet_timer: float = 0.0
var meet_cooldown_timer: float = 0.0
var meet_target: Node3D = null

# Conversation playback state. Both partners run their own copies of these
# (with the same lines + same line_duration) so they advance in lockstep
# without needing per-frame syncing. _conv_is_initiator marks who started
# the meet — used to decide who speaks the even/odd lines for same-gender
# conversations (where the JSON's "speaker" field can't disambiguate).
var _conv_lines: Array = []
var _conv_index: int = 0
var _conv_line_timer: float = 0.0
var _conv_partner: Node3D = null
var _conv_is_initiator: bool = false

var car: Node3D = null
var is_in_camera: bool = false

@onready var anim_player: AnimationPlayer = find_child("AnimationPlayer", true, false)
@onready var notifier: VisibleOnScreenNotifier3D = $VisibleOnScreenNotifier3D
@onready var hit_area: Area3D = $HitArea
@onready var subtitle: Label3D = $Subtitle


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

	# Meet-another-human takes precedence: stop, face the other, play
	# through any active conversation, and hold Point. EXCEPT: if the car
	# is now barreling toward us, abort the conversation immediately on
	# both sides and fall through to the normal AI loop, which will pick
	# FLEE on the next state decision.
	if meet_timer > 0.0:
		if _car_is_threat():
			if _conv_partner != null and is_instance_valid(_conv_partner) \
					and _conv_partner.has_method("_end_meet"):
				_conv_partner._end_meet()
			_end_meet()
			# Fall through (no return) — normal AI runs below this if-block.
		else:
			velocity.x = 0.0
			velocity.z = 0.0

			if meet_target != null and is_instance_valid(meet_target):
				var to_other: Vector3 = meet_target.global_position - global_position
				to_other.y = 0.0
				if to_other.length() > 0.001:
					_face_direction(to_other.normalized())

			_play("Point")

			# Conversation playback (both partners run their own copies —
			# same line list, same line_duration → lockstep without RPC).
			if not _conv_lines.is_empty():
				_conv_line_timer -= delta
				if _conv_line_timer <= 0.0:
					_conv_index += 1
					if _conv_index >= _conv_lines.size():
						_end_meet()
						move_and_slide()
						return
					_conv_line_timer = line_duration
					_update_subtitle_for_current_line()
			else:
				# No conversation — simple meet timer countdown.
				meet_timer -= delta
				if meet_timer <= 0.0:
					_end_meet()
					move_and_slide()
					return

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
# if so, both sides will independently start the meet/conversation. We skip
# anyone who's already on the ground (FALLEN) — you don't strike up a chat
# with a person who just got smacked by a flying box.
func _check_meet_collisions() -> void:
	if meet_timer > 0.0 or meet_cooldown_timer > 0.0:
		return
	for i in range(get_slide_collision_count()):
		var col: KinematicCollision3D = get_slide_collision(i)
		var other: Object = col.get_collider()
		if other == self or other == null:
			continue
		if other is Human or other is GoldenHuman:
			# Skip if they're already on the ground or already in another
			# conversation. The second check prevents a third human from
			# barging in and stealing one of the current talkers.
			if other.has_method("is_fallen") and other.is_fallen():
				continue
			if other.has_method("is_in_meet") and other.is_in_meet():
				continue
			_on_meet_other(other as Node3D)
			return


func is_fallen() -> bool:
	return state == State.FALLEN


func is_in_meet() -> bool:
	return meet_timer > 0.0


func _on_meet_other(other: Node3D) -> void:
	if meet_timer > 0.0 or meet_cooldown_timer > 0.0:
		return

	# Initiator selection:
	#  - Human ↔ Human   : lower instance_id is initiator (deterministic).
	#  - Human ↔ Golden  : Golden is ALWAYS the initiator. We defer here so
	#    Golden's _check_meet_collisions on the same / next physics tick
	#    drives the conversation. This guarantees the cross-language JSON's
	#    even-indexed lines (Mizo) belong to Golden, odd-indexed (English)
	#    belong to us.
	if other is GoldenHuman:
		return
	var im_initiator: bool = get_instance_id() < other.get_instance_id()
	if not im_initiator:
		return

	var other_gender: String = "female"
	if "gender" in other:
		other_gender = String(other.get("gender"))

	# Pick the language pool by who we're meeting:
	#   Human ↔ Human  -> "english"
	#   Human ↔ Golden -> "mixed"   (cross-language JSON; falls back to
	#                                bubble if no "mixed" pool exists yet)
	var language: String = "mixed" if other is GoldenHuman else "english"

	var lines: Array = []
	var cm: Node = get_node_or_null("/root/ConversationManager")
	if cm != null:
		lines = cm.call("pick_random", gender, other_gender, language)

	# Both sides enter the meet state. If we found a conversation, both
	# play through it. If not, fall back to the simple meet bubble.
	_enter_meet(other, true, lines)
	if other.has_method("_enter_meet"):
		other._enter_meet(self, false, lines)


func _enter_meet(partner: Node3D, is_initiator: bool, lines: Array) -> void:
	meet_target = partner
	_conv_partner = partner
	_conv_is_initiator = is_initiator
	_conv_lines = lines
	_conv_index = 0
	_conv_line_timer = line_duration

	if lines.is_empty():
		# Simple bubble — no conversation registered for this gender pair.
		meet_timer = meet_duration
		var tex: Texture2D = _pick_pool_texture()
		if tex != null:
			var BubbleScript: GDScript = load("res://scripts/bubble.gd")
			BubbleScript.spawn(get_parent(),
					global_position + meet_bubble_offset, tex, bubble_scale)
	else:
		# Conversation drives end-of-meet via line_index reaching the count.
		# meet_timer just needs to be non-zero so the meet branch runs.
		meet_timer = INF
		_update_subtitle_for_current_line()


# Show the current line's subtitle on whichever partner is supposed to be
# speaking it. For mixed-gender conversations the JSON's "speaker" field is
# the gender of the speaker. For same-gender we alternate by line index —
# initiator says even-indexed lines, partner says odd-indexed.
func _update_subtitle_for_current_line() -> void:
	if _conv_lines.is_empty() or _conv_index >= _conv_lines.size():
		_hide_subtitle()
		return

	var line: Dictionary = _conv_lines[_conv_index]
	var line_speaker: String = String(line.get("speaker", ""))

	var partner_gender: String = "female"
	if _conv_partner != null and is_instance_valid(_conv_partner) and "gender" in _conv_partner:
		partner_gender = String(_conv_partner.get("gender"))

	# Normalize the speaker tag in case the JSON has a typo like
	# "femalefemalefemale" instead of "female" (real bug we hit in the
	# Mizo files). begins_with works because "female" doesn't share a
	# prefix with "male".
	var ls_lower: String = line_speaker.to_lower()
	var speaker_norm: String = ls_lower
	if ls_lower.begins_with("female"):
		speaker_norm = "female"
	elif ls_lower.begins_with("male"):
		speaker_norm = "male"

	# In a cross-class meet (Human ↔ Golden) the speaker field can't be
	# trusted (the Mizo cross-language JSON tags all lines "male"), and
	# we want lines to alternate Mizo / English by index. Force the same
	# index-alternation we use for same-gender same-class conversations.
	var cross_class: bool = _conv_partner is GoldenHuman

	var show_for_me: bool = false
	if not cross_class and gender != partner_gender:
		show_for_me = (speaker_norm == gender)
	else:
		var even: bool = (_conv_index % 2 == 0)
		show_for_me = (_conv_is_initiator and even) or (not _conv_is_initiator and not even)

	if show_for_me:
		_show_subtitle(String(line.get("text", "")))
	else:
		_hide_subtitle()


func _show_subtitle(text: String) -> void:
	if subtitle == null:
		return
	subtitle.text = text
	subtitle.modulate = Color(1, 1, 1, 1)


func _hide_subtitle() -> void:
	if subtitle == null:
		return
	subtitle.text = ""
	subtitle.modulate = Color(1, 1, 1, 0)


func _end_meet() -> void:
	_conv_lines = []
	_conv_index = 0
	_conv_partner = null
	_conv_is_initiator = false
	_hide_subtitle()
	meet_timer = 0.0
	meet_cooldown_timer = meet_cooldown
	meet_target = null


# True if the car is close enough AND moving fast enough to break us out
# of an ongoing conversation. Uses conversation_break_distance (tighter
# than flee_distance) so the chat keeps going while the car drives PAST
# at moderate range; only a near-miss / direct approach interrupts.
# After this returns true, _decide_state() in the same physics tick will
# flip the state to FLEE since dist < flee_distance is implied (assuming
# conversation_break_distance < flee_distance, which is the normal case).
func _car_is_threat() -> bool:
	if car == null:
		return false
	var to_car: Vector3 = car.global_position - global_position
	to_car.y = 0.0
	if to_car.length() >= conversation_break_distance:
		return false
	var car_speed: float = 0.0
	if "speed" in car:
		car_speed = absf(car.get("speed"))
	return car_speed > car_idle_speed_threshold


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
	_spawn_bubble_from_pool(point_bubble_offset, point_bubble_name)


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
	# Cancel any in-progress meet/conversation cleanly on both sides.
	if not _conv_lines.is_empty():
		if _conv_partner != null and is_instance_valid(_conv_partner) \
				and _conv_partner.has_method("_end_meet"):
			_conv_partner._end_meet()
	_end_meet()
	_play("Fall")
