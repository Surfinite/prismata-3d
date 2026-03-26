extends Node3D

var _replay: ReplayController

func _ready():
	print("Prismata 3D Viewer loaded")

	var provider = FileProvider.new()
	provider.provider_error.connect(_on_provider_error)

	_replay = ReplayController.new()
	add_child(_replay)
	_replay.snapshot_changed.connect(_on_snapshot_changed)
	_replay.init(provider)

	provider.load_file("res://data/test_match.json")

func _on_snapshot_changed(prev: Variant, current: Variant, transition_type: String):
	var phase = current.get("phase", "?")
	var player = "P" + str(current.get("activePlayer", 0))
	var p0u = current["players"][0]["units"].size()
	var p1u = current["players"][1]["units"].size()
	print("Seq %d | Turn %d | %s %s | P0:%d P1:%d | %s" % [
		current["seq"], current["turn"], player, phase, p0u, p1u, transition_type
	])

func _on_provider_error(msg: String):
	push_error("Provider error: " + msg)

func _input(event: InputEvent):
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_RIGHT:
				_replay.step_forward()
			KEY_LEFT:
				_replay.step_backward()
			KEY_SPACE:
				_replay.toggle_play()
			KEY_HOME:
				_replay.jump_to_seq(0)
			KEY_END:
				_replay.jump_to_seq(_replay.get_latest_seq())
