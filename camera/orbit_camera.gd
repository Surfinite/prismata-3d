class_name OrbitCamera
extends Camera3D

@export var focus_point: Vector3 = Vector3.ZERO
@export var distance: float = 15.0
@export var pitch: float = -45.0  # degrees, negative = looking down
@export var yaw: float = 0.0

@export var min_distance: float = 5.0
@export var max_distance: float = 40.0
@export var zoom_speed: float = 2.0
@export var orbit_speed: float = 0.3
@export var pan_speed: float = 0.02

var _dragging_orbit: bool = false
var _dragging_pan: bool = false
var _user_active: bool = false
var _top_down: bool = false
var _stored_pitch: float = -45.0

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
	_update_transform()

func _input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging_orbit = event.pressed
			_user_active = event.pressed
			if event.pressed:
				_focus_active = false
		elif event.button_index == MOUSE_BUTTON_MIDDLE or event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging_pan = event.pressed
			_user_active = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clampf(distance - zoom_speed, min_distance, max_distance)
			_update_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clampf(distance + zoom_speed, min_distance, max_distance)
			_update_transform()

	elif event is InputEventMouseMotion:
		if _dragging_orbit and not _top_down:
			yaw -= event.relative.x * orbit_speed
			pitch = clampf(pitch - event.relative.y * orbit_speed, -89.0, -10.0)
			_update_transform()
		elif _dragging_pan:
			var right = global_transform.basis.x
			var forward = Vector3(global_transform.basis.z.x, 0, global_transform.basis.z.z).normalized()
			focus_point -= right * event.relative.x * pan_speed * distance * 0.01
			focus_point += forward * event.relative.y * pan_speed * distance * 0.01
			_update_transform()

	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_T:
			toggle_top_down()

func toggle_top_down():
	_top_down = not _top_down
	if _top_down:
		_stored_pitch = pitch
		pitch = -89.0
	else:
		pitch = _stored_pitch
	_update_transform()

func _update_transform():
	var pitch_rad = deg_to_rad(pitch)
	var yaw_rad = deg_to_rad(yaw)

	var offset = Vector3(
		sin(yaw_rad) * cos(pitch_rad) * distance,
		-sin(pitch_rad) * distance,
		cos(yaw_rad) * cos(pitch_rad) * distance
	)

	var shake_offset = Vector3.ZERO
	if _shake_intensity > 0:
		shake_offset = Vector3(
			randf_range(-1, 1) * _shake_intensity,
			randf_range(-1, 1) * _shake_intensity * 0.5,
			randf_range(-1, 1) * _shake_intensity
		)

	global_position = focus_point + offset + shake_offset
	look_at(focus_point)

func _process(delta):
	if _shake_timer > 0:
		_shake_timer -= delta
		if _shake_timer <= 0:
			_shake_intensity = 0.0
		_update_transform()

	if _focus_active and not _user_active:
		_focus_timer += delta
		var t = clampf(_focus_timer / _focus_duration, 0.0, 1.0)
		t = t * t * (3.0 - 2.0 * t)  # smoothstep
		focus_point = _focus_start.lerp(_focus_target, t)
		_update_transform()
		if t >= 1.0:
			_focus_active = false

# Camera API for visual hooks
func request_focus(target: Vector3, duration: float = 1.0) -> void:
	if _user_active:
		return
	_focus_start = focus_point
	_focus_target = target
	_focus_duration = duration
	_focus_timer = 0.0
	_focus_active = true

func shake(intensity: float = 0.5, duration: float = 0.3) -> void:
	_shake_intensity = intensity
	_shake_timer = duration

func is_user_active() -> bool:
	return _user_active
