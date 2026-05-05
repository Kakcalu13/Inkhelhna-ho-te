extends Control

# Map on-screen rectangles to input actions.
# Multi-touch: each finger that goes down inside a rect presses that action;
# when the SAME finger lifts (or drags out), the action is released. So you
# can hold gas + steer at the same time, or tap boost while still steering.
#
# Also visually toggles the BOOST buttons between their "ready" (orange)
# StyleBox and a "disabled" (grey) StyleBox while a boost is active or its
# cooldown is still ticking. The grey is applied the moment boost is pressed
# and reverts the moment the cooldown ends.

var _touches: Dictionary = {}  # touch_index -> action string
var _entries: Array = []        # [Control, action_name] pairs

# Boost button visuals
var _boost_active_style: StyleBox = null
var _boost_disabled_style: StyleBox = null
var _car: CarController = null
var _last_boost_avail: bool = true

# Shake state (active during the 2-second boost only)
var _bl_offsets: Vector4 = Vector4.ZERO   # BtnBoostLeft  resting offsets
var _br_offsets: Vector4 = Vector4.ZERO   # BtnBoostRight resting offsets
var _was_shaking: bool = false
@export var shake_amount: float = 16.0    # pixels of jitter per frame


func _ready() -> void:
	# Make sure mouse clicks on PC also count as touch events on this Control
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Register the custom "boost" action so Input.action_press("boost") works
	# and so Space on the keyboard fires it during desktop testing.
	if not InputMap.has_action("boost"):
		InputMap.add_action("boost")
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_SPACE
		InputMap.action_add_event("boost", ev)

	_entries = [
		[$BtnUp,         "ui_up"],
		[$BtnDown,       "ui_down"],
		[$BtnLeft,       "ui_left"],
		[$BtnRight,      "ui_right"],
		[$BtnBoostLeft,  "boost"],
		[$BtnBoostRight, "boost"],
	]

	# Cache the boost buttons' current StyleBox as the "ready" look,
	# and build a grey "disabled" StyleBox to swap in during boost+cooldown.
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

	# Cache the resting offsets of both boost buttons so we can shake them by
	# random pixel deltas during the active boost without losing their layout.
	_bl_offsets = Vector4(
		$BtnBoostLeft.offset_left, $BtnBoostLeft.offset_top,
		$BtnBoostLeft.offset_right, $BtnBoostLeft.offset_bottom)
	_br_offsets = Vector4(
		$BtnBoostRight.offset_left, $BtnBoostRight.offset_top,
		$BtnBoostRight.offset_right, $BtnBoostRight.offset_bottom)

	_car = get_node_or_null("../../Car") as CarController


func _process(_delta: float) -> void:
	if _car == null:
		return

	# --- Shake the boost buttons during the active 2-second boost --------------
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
		# Boost just ended — snap both panels back to their resting position
		_apply_offset($BtnBoostLeft,  _bl_offsets, 0.0, 0.0)
		_apply_offset($BtnBoostRight, _br_offsets, 0.0, 0.0)
	_was_shaking = boosting
	# ---------------------------------------------------------------------------

	# Active (orange) vs. disabled (grey) StyleBox swap.
	# The buttons stay orange during the active 2-s boost (while shaking) so
	# they look "fired up". They only turn grey AFTER the boost ends, while
	# the cooldown timer is ticking — which is the period you actually can't
	# re-trigger.
	var available: bool = _car.cooldown_timer <= 0.0
	if available == _last_boost_avail:
		return
	_last_boost_avail = available
	var style: StyleBox = _boost_active_style if available else _boost_disabled_style
	$BtnBoostLeft.add_theme_stylebox_override("panel", style)
	$BtnBoostRight.add_theme_stylebox_override("panel", style)


# Shift all 4 anchor offsets of a panel by the same (dx, dy) so the panel
# moves without changing size or anchors.
func _apply_offset(panel: Control, base: Vector4, dx: float, dy: float) -> void:
	panel.offset_left = base.x + dx
	panel.offset_top = base.y + dy
	panel.offset_right = base.z + dx
	panel.offset_bottom = base.w + dy


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


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t: InputEventScreenTouch = event
		if t.pressed:
			_press_action(t.index, _action_at(t.position))
		else:
			_release_touch(t.index)
	elif event is InputEventScreenDrag:
		var d: InputEventScreenDrag = event
		_press_action(d.index, _action_at(d.position))
	elif event is InputEventMouseButton:
		var m: InputEventMouseButton = event
		if m.pressed:
			_press_action(-1, _action_at(m.position))
		else:
			_release_touch(-1)
	elif event is InputEventMouseMotion:
		# Only update while the mouse button is pressed (tracked as idx -1)
		if -1 in _touches:
			_press_action(-1, _action_at(event.position))
