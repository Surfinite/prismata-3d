extends Node3D

var _replay: ReplayController
var _hooks: VisualHooks
var _buy_hook: BuyHook
var _kill_hook: KillHook
@onready var _battlefield: Battlefield = $Battlefield
@onready var _hud: ReplayHUD = $ReplayHUD

func _ready():
	print("Prismata 3D Viewer loaded")

	var provider = FileProvider.new()
	provider.provider_error.connect(_on_provider_error)

	_replay = ReplayController.new()
	add_child(_replay)
	_replay.snapshot_changed.connect(_on_snapshot_changed)

	# Wire hooks BEFORE loading data (signals are synchronous)
	# Store as member vars to prevent RefCounted GC
	_hooks = VisualHooks.new()
	_buy_hook = BuyHook.new()
	_hooks.register("buy", _buy_hook.handle_event)
	_kill_hook = KillHook.new()
	_hooks.register("kill", _kill_hook.handle_event)
	_hooks.register("sacrifice", _kill_hook.handle_event)
	_hooks.register("breach_kill", _kill_hook.handle_event)
	_battlefield.set_visual_hooks(_hooks)
	_battlefield.set_camera($Camera)

	# Connect HUD BEFORE loading data so it receives the initial snapshot
	_hud.init(_replay)

	# Now connect provider and load — all listeners are ready
	_replay.init(provider)
	# Load current_replay.json if available, otherwise fall back to test fixture
	if FileAccess.file_exists("res://data/current_replay.json"):
		provider.load_file("res://data/current_replay.json")
	else:
		provider.load_file("res://data/test_match.json")

func _on_snapshot_changed(prev: Variant, current: Variant, transition_type: String):
	_battlefield.apply_snapshot(prev, current, transition_type)

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
				var min_seq = _replay.get_min_seq()
				if min_seq >= 0:
					_replay.jump_to_seq(min_seq)
			KEY_END:
				_replay.jump_to_seq(_replay.get_latest_seq())
