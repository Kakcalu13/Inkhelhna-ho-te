extends RigidBody3D

# Per-box state machine:
#   ""      → original spawn color, untouched
#   "pulse" → cycling random hues with a soft glow (speed scales with pulse_speed)
#   "black" → solid matte black, terminal state (set when this box collides
#             with another box / RigidBody3D).
#
# Public API:
#   on_hit(pulse_speed: float = 1.0)
#     Called by the car_controller when the car runs into the box. Starts the
#     color pulse (or upgrades the speed if already pulsing — e.g. a boosted
#     hit on an already-pulsing box bumps it up to fast-pulse).
#   turn_black()
#     Lock the material to matte black. Triggered automatically by
#     body_entered when another RigidBody3D (i.e., another box) hits us.

@export var transition_duration: float = 1.6   # base seconds per color change at pulse_speed = 1

var hit_type: String = ""
var pulse_speed: float = 1.0
var material: StandardMaterial3D = null

var current_color: Color = Color.WHITE
var target_color: Color = Color.WHITE
var t: float = 0.0
var rng: RandomNumberGenerator


func _ready() -> void:
	rng = RandomNumberGenerator.new()
	rng.randomize()

	# Find our visual material (set by boxes_spawner.gd via material_override)
	for child in get_children():
		if child is MeshInstance3D:
			material = child.material_override
			break

	if material:
		current_color = material.albedo_color
		target_color = current_color

	# Required for body_entered to fire on RigidBody3D
	contact_monitor = true
	max_contacts_reported = 6
	body_entered.connect(_on_body_entered)


func on_hit(speed: float = 1.0) -> void:
	# Already pulsing? Upgrade the speed (e.g. boost ramming an already-hit
	# box should switch it from gentle pulse to fast pulse).
	if hit_type == "pulse":
		pulse_speed = maxf(pulse_speed, speed)
		return
	# Untouched or black — (re)start the pulse. A black box being run over
	# by the car will fade back from black into a fresh random color and
	# resume cycling at the requested speed (fast if the car is boosting).
	hit_type = "pulse"
	pulse_speed = speed
	if material:
		material.emission_enabled = true
		current_color = material.albedo_color
	target_color = _random_pulse_color()
	t = 0.0


func turn_black() -> void:
	hit_type = "black"
	if material:
		material.albedo_color = Color(0.04, 0.04, 0.04, 1.0)
		material.emission_enabled = false
		material.emission = Color(0, 0, 0)
		material.metallic = 0.0
		material.roughness = 0.95


# Chain reactions:
#  - StaticBody3D (the ground)  → ignore (settling shouldn't trigger anything)
#  - RigidBody3D  (another box) → BOTH boxes turn black (each side of the
#                                  collision fires its own body_entered)
#  - CharacterBody3D (the car)  → don't react here; the car_controller calls
#                                  on_hit() directly with the right speed.
func _on_body_entered(body: Node) -> void:
	if body is StaticBody3D:
		return
	if body is RigidBody3D:
		turn_black()


func _process(delta: float) -> void:
	if hit_type != "pulse" or material == null:
		return
	var dur: float = maxf(0.05, transition_duration / maxf(0.01, pulse_speed))
	t += delta
	var u: float = t / dur
	if u >= 1.0:
		current_color = target_color
		target_color = _random_pulse_color()
		t = 0.0
		u = 0.0
	var eased: float = smoothstep(0.0, 1.0, u)
	var c: Color = current_color.lerp(target_color, eased)
	material.albedo_color = c
	material.emission = c * 0.45


func _random_pulse_color() -> Color:
	# Random saturated, brightish hue
	return Color.from_hsv(rng.randf(), 0.65, 0.95)
