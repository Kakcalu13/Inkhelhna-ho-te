extends Sprite3D

# Generic emoji-style bubble. Same pop-in / shake / spin / fade behavior as
# bam_effect.gd, but the texture is set per-spawn (so it can show wow / oh_no
# / any newly-added image registered by BubbleRegistry).
#
# Usage from script:
#     Bubble.spawn(parent_node, world_position, BubbleRegistry.get_texture("wow"))

@export var normal_scale: Vector3 = Vector3(0.35, 0.35, 0.35)
@export var lifetime: float = 2.0
@export var pop_in_duration: float = 0.4
@export var fade_out_duration: float = 0.20
@export var shake_amount: float = 0.06
@export var spin_amplitude: float = 0.7
@export var spin_speed: float = 75.0

var _rest_position: Vector3
var _rest_captured: bool = false
var _elapsed: float = 0.0
var _shake_done: bool = false


func _ready() -> void:
	scale = Vector3.ZERO
	# Don't capture _rest_position here — _ready runs during add_child, BEFORE
	# the spawner has set our global_position. Capture lazily in _process.

	var hold: float = maxf(0.0, lifetime - pop_in_duration - fade_out_duration)

	var tween: Tween = create_tween()
	tween.tween_property(self, "scale", normal_scale, pop_in_duration)\
		.set_ease(Tween.EASE_OUT)\
		.set_trans(Tween.TRANS_BACK)
	if hold > 0.0:
		tween.tween_interval(hold)
	tween.tween_property(self, "modulate:a", 0.0, fade_out_duration)
	tween.tween_callback(queue_free)


func _process(delta: float) -> void:
	if not _rest_captured:
		_rest_position = position
		_rest_captured = true

	_elapsed += delta
	if _elapsed < pop_in_duration:
		position = _rest_position + Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0),
			0.0
		) * shake_amount
		rotation.z = sin(_elapsed * spin_speed) * spin_amplitude
	elif not _shake_done:
		_shake_done = true
		position = _rest_position
		rotation.z = 0.0


# Convenience spawner. Optional scale_override lets a caller (e.g. human.gd)
# pop the bubble at a custom size without affecting the default bubble.tscn.
# Pass Vector3.ZERO (the default) to keep the scene/script's own normal_scale.
# Returns the new node (or null if texture is missing).
static func spawn(parent_node: Node, world_pos: Vector3, tex: Texture2D,
		scale_override: Vector3 = Vector3.ZERO) -> Sprite3D:
	if tex == null or parent_node == null:
		return null
	var packed: PackedScene = load("res://scenes/bubble.tscn")
	var b: Sprite3D = packed.instantiate()
	b.texture = tex
	# Set normal_scale BEFORE add_child so _ready's tween animates toward the
	# overridden size rather than the default.
	if scale_override != Vector3.ZERO:
		b.normal_scale = scale_override
	parent_node.add_child(b)
	b.global_position = world_pos
	return b
