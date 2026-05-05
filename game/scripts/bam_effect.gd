extends Sprite3D

# Per-impact "BAM!" sprite.
# Spawned by car_controller at the contact point of a car↔box collision.
# Pinned to world space (parented to the World node, NOT the box or the car),
# so even if the box flies away or the car drives off, the sprite hangs in
# the air at the impact location for its lifetime, then removes itself.
#
# Animation:
#   1. starts at scale 0
#   2. pops up to `normal_scale` with a Back-out ease for a satisfying punch
#   3. holds
#   4. fades alpha to 0 in the last fade_out_duration seconds
#   5. queue_free() at the end
#
# Tunables (visible in the inspector on bam_effect.tscn):
#   - normal_scale       Vector3  — final size; the user is going to tweak this
#   - lifetime           float    — total seconds before the node disappears
#   - pop_in_duration    float    — how long the shrink→normal animation takes
#   - fade_out_duration  float    — fade-out tail before queue_free

@export var normal_scale: Vector3 = Vector3.ONE
@export var lifetime: float = 2.0
@export var pop_in_duration: float = 0.18
@export var fade_out_duration: float = 0.20
# Pop-in flair — runs only during the pop_in_duration window.
@export var shake_amount: float = 0.08      # world-space jitter radius (m)
@export var spin_amplitude: float = 0.7     # max wobble angle in radians (~40°)
@export var spin_speed: float = 75.0        # how fast the wobble cycles

var _rest_position: Vector3
var _rest_captured: bool = false
var _elapsed: float = 0.0
var _shake_done: bool = false


func _ready() -> void:
	scale = Vector3.ZERO
	# IMPORTANT: don't capture _rest_position here. _ready runs during the
	# parent's add_child() call, which happens BEFORE the spawner has had a
	# chance to assign global_position. Capturing now would lock us to the
	# parent's origin and the shake would jitter around (0,0,0). We capture
	# lazily on the first _process tick instead.

	var hold: float = maxf(0.0, lifetime - pop_in_duration - fade_out_duration)

	var tween: Tween = create_tween()
	# Pop in with overshoot for a "punch" feel
	tween.tween_property(self, "scale", normal_scale, pop_in_duration)\
		.set_ease(Tween.EASE_OUT)\
		.set_trans(Tween.TRANS_BACK)
	# Hold at normal size
	if hold > 0.0:
		tween.tween_interval(hold)
	# Fade alpha to 0
	tween.tween_property(self, "modulate:a", 0.0, fade_out_duration)
	# Remove from scene
	tween.tween_callback(queue_free)


func _process(delta: float) -> void:
	# Lazy-capture: first _process call happens AFTER the spawner has set our
	# global_position, so this is when we know the real impact-point coords.
	if not _rest_captured:
		_rest_position = position
		_rest_captured = true

	_elapsed += delta
	if _elapsed < pop_in_duration:
		# Rapid random jitter — reads as a vibrating shake on top of the
		# scale-up tween. Z is left at 0 since the sprite is billboarded;
		# x/y in world space appear as horizontal/vertical jitter on screen.
		position = _rest_position + Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0),
			0.0
		) * shake_amount
		# Rapid sine wobble around the camera-facing axis = in-screen-plane spin
		rotation.z = sin(_elapsed * spin_speed) * spin_amplitude
	elif not _shake_done:
		# Pop-in just ended — lock everything to rest pose so the held sprite
		# isn't off-center or tilted.
		_shake_done = true
		position = _rest_position
		rotation.z = 0.0
