# replay/replay_controller.gd
class_name ReplayController
extends Node

signal snapshot_changed(prev_snapshot: Variant, current_snapshot: Variant, transition_type: String)

var _provider: BaseProvider
var _cache: Dictionary = {}       # seq -> snapshot
var _turn_index: Dictionary = {}  # turn -> first seq for that turn
var _current_seq: int = -1
var _min_seq: int = 999999
var _latest_seq: int = -1
var _playing: bool = false
var _play_speed: float = 1.0
var _play_timer: float = 0.0
var _base_interval: float = 0.5   # seconds per seq at 1x speed

func init(provider: BaseProvider) -> void:
	_provider = provider
	_provider.snapshot_available.connect(_on_snapshot_available)
	_provider.provider_reset.connect(_on_provider_reset)

func _on_snapshot_available(seq: int) -> void:
	var snapshot = _provider.get_snapshot(seq)
	if snapshot == null:
		return
	_cache[seq] = snapshot
	if seq > _latest_seq:
		_latest_seq = seq
	if seq < _min_seq:
		_min_seq = seq
	# Build turn index
	var turn = int(snapshot.get("turn", 0))
	if not _turn_index.has(turn) or seq < _turn_index[turn]:
		_turn_index[turn] = seq
	# Auto-navigate to min available seq on first load
	if _current_seq == -1:
		_navigate_to(_min_seq, "forward")

func _on_provider_reset() -> void:
	_cache.clear()
	_turn_index.clear()
	_current_seq = -1
	_min_seq = 999999
	_latest_seq = -1
	_playing = false

func _navigate_to(seq: int, transition_type: String) -> void:
	if not _cache.has(seq):
		return
	var prev = _cache.get(_current_seq)
	var current = _cache[seq]
	_current_seq = seq
	snapshot_changed.emit(prev, current, transition_type)

func step_forward() -> void:
	var next_seq = _current_seq + 1
	while next_seq <= _latest_seq:
		if _cache.has(next_seq):
			_navigate_to(next_seq, "forward")
			return
		next_seq += 1

func step_backward() -> void:
	var prev_seq = _current_seq - 1
	while prev_seq >= _min_seq:
		if _cache.has(prev_seq):
			_navigate_to(prev_seq, "backward")
			return
		prev_seq -= 1

func jump_to_seq(seq: int) -> void:
	var target = clampi(seq, _min_seq, _latest_seq)
	# Find closest available seq
	if _cache.has(target):
		_navigate_to(target, "jump")
	else:
		# Search forward then backward
		for offset in range(1, _latest_seq - _min_seq + 1):
			if _cache.has(target + offset):
				_navigate_to(target + offset, "jump")
				return
			if _cache.has(target - offset):
				_navigate_to(target - offset, "jump")
				return

func jump_to_turn(turn: int) -> void:
	if _turn_index.has(turn):
		_navigate_to(_turn_index[turn], "jump")

func toggle_play() -> void:
	_playing = not _playing
	_play_timer = 0.0

func set_speed(speed: float) -> void:
	_play_speed = speed

func get_current_seq() -> int:
	return _current_seq

func get_latest_seq() -> int:
	return _latest_seq

func get_min_seq() -> int:
	return _min_seq if _min_seq != 999999 else -1

func is_playing() -> bool:
	return _playing

func _process(delta: float) -> void:
	if not _playing:
		return
	_play_timer += delta * _play_speed
	if _play_timer >= _base_interval:
		_play_timer -= _base_interval
		var next_seq = _current_seq + 1
		while next_seq <= _latest_seq:
			if _cache.has(next_seq):
				_navigate_to(next_seq, "forward")
				return
			next_seq += 1
		_playing = false  # End of replay
