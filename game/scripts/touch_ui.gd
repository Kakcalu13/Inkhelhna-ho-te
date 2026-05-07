extends Control

# On-screen UI:
#   - JoystickBase  — circular touch area (controller.png) on the bottom-left.
#                     Touching anywhere inside drives ui_up/down/left/right.
#                     Diagonals (up-left etc.) come "for free" because both
#                     axes can be active at once: pulling the stick to the
#                     upper-right activates ui_up AND ui_right simultaneously.
#   - BtnBoostLeft / BtnBoostRight — same on-screen Boost panels as before.
#
# Multi-touch: each finger is tracked independently, so you can hold a
# direction on the joystick AND tap boost at the same time.

var _touches: Dictionary = {}     # touch_index -> action string (boost only)
var _entries: Array = []          # [Control, action_name] pairs (boost buttons)

# Joystick state
const _DPAD_ACTIONS: PackedStringArray = ["ui_up", "ui_down", "ui_left", "ui_right"]
var _joystick_active: int = -999  # touch index currently driving the joystick (-1 = mouse)
var _joystick_center: Vector2 = Vector2.ZERO
var _joystick_radius: float = 1.0
@export var deadzone_ratio: float = 0.18   # fraction of radius where no direction fires

# Boost button visuals
var _boost_active_style: StyleBox = null
var _boost_disabled_style: StyleBox = null
var _car: CarController = null
var _last_boost_avail: bool = true

# Boost shake state
var _bl_offsets: Vector4 = Vector4.ZERO
var _br_offsets: Vector4 = Vector4.ZERO
var _was_shaking: bool = false
@export var shake_amount: float = 16.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	if not InputMap.has_action("boost"):
		InputMap.add_action("boost")
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_SPACE
		InputMap.action_add_event("boost", ev)

	# Only the boost buttons go through the rect-tap system now — directional
	# input is handled by the joystick (separate, multi-touch friendly).
	_entries = [
		[$BtnBoostLeft,  "boost"],
		[$BtnBoostRight, "boost"],
	]

	_boost_active_style = $BtnBoostLeft.get_theme_stylebox("panel")

	var grey: StyleBoxFlat = StyleBoxFlat.new()
	grey.bg_color = Color(0.30, 0.30, 0.32, 0.78)
	grey.border_color = Color(0.55, 0.55, 0.58, 1.0)
	grey.border_width_left = 3
	grey.border_width_top = 3
	grey.border_width_right = 3
	grey.border_width_bottom = 3
	grey.corner_radius_top_left = 12
	grey.corner_radius_top_right = 12
	grey.corner_radius_bottom_right = 12
	grey.corner_radius_bottom_left = 12
	_boost_disabled_style = grey

	_bl_offsets = Vector4(
		$BtnBoostLeft.offset_left, $BtnBoostLeft.offset_top,
		$BtnBoostLeft.offset_right, $BtnBoostLeft.offset_bottom)
	_br_offsets = Vector4(
		$BtnBoostRight.offset_left, $BtnBoostRight.offset_top,
		$BtnBoostRight.offset_right, $BtnBoostRight.offset_bottom)

	_car = get_node_or_null("../../Car") as CarController


func _process(_delta: float) -> void:
	# Recompute the joystick's screen-space hit zone every frame in case the
	# UI rescaled (different viewport size, orientation change, etc.).
	_update_joystick_geometry()

	if _car == null:
		return

	var boosting: bool = _car.boost_timer > 0.0
	if boosting:
		_apply_offset(
			$BtnBoostLeft, _bl_offsets,
			randf_range(-shake_amount, shake_amount),
			randf_range(-shake_amount, shake_amount))
		_apply_offset(
			$BtnBoostRight, _br_offsets,
			randf_range(-shake_amount, shake_amount),
			randf_range(-shake_amount, shake_amount))
	elif _was_shaking:
		_apply_offset($BtnBoostLeft,  _bl_offsets, 0.0, 0.0)
		_apply_offset($BtnBoostRight, _br_offsets, 0.0, 0.0)
	_was_shaking = boosting

	var available: bool = _car.cooldown_timer <= 0.0
	if available == _last_boost_avail:
		return
	_last_boost_avail = available
	var style: StyleBox = _boost_active_style if available else _boost_disabled_style
	$BtnBoostLeft.add_theme_stylebox_override("panel", style)
	$BtnBoostRight.add_theme_stylebox_override("panel", style)


func _apply_offset(panel: Control, base: Vector4, dx: float, dy: float) -> void:
	panel.offset_left = base.x + dx
	panel.offset_top = base.y + dy
	panel.offset_right = base.z + dx
	panel.offset_bottom = base.w + dy


# ---------- Joystick ----------
func _update_joystick_geometry() -> void:
	var jb: TextureRect = get_node_or_null("JoystickBase")
	if jb == null:
		return
	var rect: Rect2 = jb.get_global_rect()
	_joystick_center = rect.position + rect.size * 0.5
	_joystick_radius = maxf(1.0, minf(rect.size.x, rect.size.y) * 0.5)


func _is_in_joystick(pos: Vector2) -> bool:
	# Slightly larger hit radius than the visual circle so off-edge taps still
	# register as joystick instead of falling through to the boost rect lookup.
	return pos.distance_to(_joystick_center) <= _joystick_radius * 1.10


func _drive_joystick(pos: Vector2) -> void:
	# Always show + reposition the visual stick whenever this is called.
	_update_stick_visual(pos)

	var offset: Vector2 = pos - _joystick_center
	var distance: float = offset.length()

	if distance < _joystick_radius * deadzone_ratio:
		_release_dpad_actions_only()
		return

	var nx: float = clampf(offset.x / _joystick_radius, -1.0, 1.0)
	var ny: float = clampf(offset.y / _joystick_radius, -1.0, 1.0)

	var t: float = deadzone_ratio

	if nx > t:
		Input.action_press("ui_right", clampf(nx, 0.0, 1.0))
	else:
		Input.action_release("ui_right")

	if nx < -t:
		Input.action_press("ui_left", clampf(-nx, 0.0, 1.0))
	else:
		Input.action_release("ui_left")

	if ny < -t:
		Input.action_press("ui_up", clampf(-ny, 0.0, 1.0))
	else:
		Input.action_release("ui_up")

	if ny > t:
		Input.action_press("ui_down", clampf(ny, 0.0, 1.0))
	else:
		Input.action_release("ui_down")


# Position the small visual "stick" at the finger's location relative to the
# JoystickBase's center, clamped so it never escapes the base circle.
func _update_stick_visual(pos: Vector2) -> void:
	var stick: Control = get_node_or_null("JoystickBase/Stick")
	if stick == null:
		return
	var jb: TextureRect = $JoystickBase
	stick.visible = true
	var offset: Vector2 = pos - _joystick_center
	# Keep the stick fully inside the base circle
	var max_off: float = maxf(0.0, _joystick_radius - stick.size.x * 0.5)
	if offset.length() > max_off:
		offset = offset.normalized() * max_off
	# Convert to JoystickBase-local coords (origin = top-left of base)
	stick.position = jb.size * 0.5 + offset - stick.size * 0.5


func _hide_stick_visual() -> void:
	var stick: Control = get_node_or_null("JoystickBase/Stick")
	if stick != null:
		stick.visible = false


func _release_dpad_actions_only() -> void:
	for action in _DPAD_ACTIONS:
		Input.action_release(action)


func _release_dpad() -> void:
	_release_dpad_actions_only()
	_hide_stick_visual()


# ---------- Boost rect taps ----------
func _action_at(pos: Vector2) -> String:
	for entry in _entries:
		var c: Control = entry[0]
		if c and c.get_global_rect().has_point(pos):
			return entry[1]
	return ""


func _press_action(idx: int, action: String) -> void:
	if action == "":
		return
	if _touches.get(idx, "") == action:
		return
	_release_touch(idx)
	Input.action_press(action)
	_touches[idx] = action


func _release_touch(idx: int) -> void:
	if idx in _touches:
		Input.action_release(_touches[idx])
		_touches.erase(idx)


# ---------- Input dispatch ----------
# Joystick gets first claim on a touch if the touch starts inside its area;
# otherwise the touch falls through to boost-button rect detection.
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t: InputEventScreenTouch = event
		if t.pressed:
			if _is_in_joystick(t.position):
				_joystick_active = t.index
				_drive_joystick(t.position)
			else:
				_press_action(t.index, _action_at(t.position))
		else:
			if t.index == _joystick_active:
				_joystick_active = -999
				_release_dpad()
			else:
				_release_touch(t.index)

	elif event is InputEventScreenDrag:
		var d: InputEventScreenDrag = event
		if d.index == _joystick_active:
			_drive_joystick(d.position)
		else:
			_press_action(d.index, _action_at(d.position))

	elif event is InputEventMouseButton:
		var m: InputEventMouseButton = event
		if m.pressed:
			if _is_in_joystick(m.position):
				_joystick_active = -1
				_drive_joystick(m.position)
			else:
				_press_action(-1, _action_at(m.position))
		else:
			if _joystick_active == -1:
				_joystick_active = -999
				_release_dpad()
			else:
				_release_touch(-1)

	elif event is InputEventMouseMotion:
		if _joystick_active == -1:
			_drive_joystick(event.position)
		elif -1 in _touches:
			_press_action(-1, _action_at(event.position))
