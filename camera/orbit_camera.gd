class_name OrbitCamera
extends Camera3D

## SWF-faithful locked top-down orthographic camera.
## Matches the Prismata client's 2D view exactly.
## Pan with middle/right-drag, zoom with scroll wheel.
## Press T to toggle into free 3D orbit mode (future).

@export var focus_point: Vector3 = Vector3.ZERO

# Orthographic size = visible half-height in world units.
# SWF board: rows span from -2.518 to +2.518 (5.036 total) + card half-height (0.494).
# Total needed: ~6.03 world-units. Add padding → ~3.5 half-height.
@export var ortho_size: float = 3.8
@export var min_ortho_size: float = 1.5
@export var max_ortho_size: float = 8.0
@export var zoom_speed: float = 0.3
@export var pan_speed: float = 0.005

# 3D orbit mode (T key toggle, for future use)
var _3d_mode: bool = false
var _orbit_distance: float = 8.0
var _orbit_pitch: float = -45.0
var _orbit_yaw: float = 0.0
var _orbit_speed: float = 0.3

var _dragging_pan: bool = false
var _dragging_orbit: bool = false

# Cinematic focus (for hooks)
var _focus_start: Vector3 = Vector3.ZERO
var _focus_target: Vector3 = Vector3.ZERO
var _focus_active: bool = false
var _focus_timer: float = 0.0
var _focus_duration: float = 1.0

# Shake (for hooks)
var _shake_intensity: float = 0.0
var _shake_timer: float = 0.0

func _ready():
	# Start in orthographic top-down
	projection = Camera3D.PROJECTION_ORTHOGONAL
	size = ortho_size
	_update_transform()

func _input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE or event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging_pan = event.pressed
			if event.pressed:
				_focus_active = false
		elif event.button_index == MOUSE_BUTTON_LEFT and _3d_mode:
			_dragging_orbit = event.pressed
			if event.pressed:
				_focus_active = false
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if _3d_mode:
				_orbit_distance = clampf(_orbit_distance - zoom_speed * 2, 3.0, 20.0)
			else:
				ortho_size = clampf(ortho_size - zoom_speed, min_ortho_size, max_ortho_size)
				size = ortho_size
			_update_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if _3d_mode:
				_orbit_distance = clampf(_orbit_distance + zoom_speed * 2, 3.0, 20.0)
			else:
				ortho_size = clampf(ortho_size + zoom_speed, min_ortho_size, max_ortho_size)
				size = ortho_size
			_update_transform()

	elif event is InputEventMouseMotion:
		if _dragging_pan:
			# Pan: move focus_point in screen-space
			var scale_factor = ortho_size if not _3d_mode else _orbit_distance * 0.1
			focus_point.x -= event.relative.x * pan_speed * scale_factor
			focus_point.z += event.relative.y * pan_speed * scale_factor
			_update_transform()
		elif _dragging_orbit and _3d_mode:
			_orbit_yaw -= event.relative.x * _orbit_speed
			_orbit_pitch = clampf(_orbit_pitch - event.relative.y * _orbit_speed, -89.0, -10.0)
			_update_transform()

	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_T:
			_toggle_3d_mode()

func _toggle_3d_mode():
	_3d_mode = not _3d_mode
	if _3d_mode:
		projection = Camera3D.PROJECTION_PERSPECTIVE
		fov = 75.0
	else:
		projection = Camera3D.PROJECTION_ORTHOGONAL
		size = ortho_size
	_update_transform()

func _update_transform():
	var shake_offset = Vector3.ZERO
	if _shake_intensity > 0:
		shake_offset = Vector3(
			randf_range(-1, 1) * _shake_intensity,
			0,
			randf_range(-1, 1) * _shake_intensity
		)

	if _3d_mode:
		# 3D orbit mode
		var pitch_rad = deg_to_rad(_orbit_pitch)
		var yaw_rad = deg_to_rad(_orbit_yaw)
		var offset = Vector3(
			sin(yaw_rad) * cos(pitch_rad) * _orbit_distance,
			-sin(pitch_rad) * _orbit_distance,
			cos(yaw_rad) * cos(pitch_rad) * _orbit_distance
		)
		global_position = focus_point + offset + shake_offset
		look_at(focus_point)
	else:
		# Orthographic top-down: camera straight above, looking down
		global_position = focus_point + Vector3(0, 20, 0) + shake_offset
		global_rotation = Vector3(deg_to_rad(-90), 0, 0)

func _process(delta):
	if _shake_timer > 0:
		_shake_timer -= delta
		if _shake_timer <= 0:
			_shake_intensity = 0.0
		_update_transform()

	if _focus_active:
		_focus_timer += delta
		var t = clampf(_focus_timer / _focus_duration, 0.0, 1.0)
		t = t * t * (3.0 - 2.0 * t)  # smoothstep
		focus_point = _focus_start.lerp(_focus_target, t)
		_update_transform()
		if t >= 1.0:
			_focus_active = false

# Camera API for visual hooks
func request_focus(target: Vector3, duration: float = 1.0) -> void:
	_focus_start = focus_point
	_focus_target = target
	_focus_duration = duration
	_focus_timer = 0.0
	_focus_active = true

func shake(intensity: float = 0.3, duration: float = 0.2) -> void:
	_shake_intensity = intensity
	_shake_timer = duration

func is_user_active() -> bool:
	return _dragging_pan or _dragging_orbit
