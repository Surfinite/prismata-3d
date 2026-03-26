class_name ReplayHUD
extends CanvasLayer

@onready var turn_label: Label = $TopBar/TurnLabel
@onready var scrubber: HSlider = $BottomPanel/Scrubber
@onready var play_btn: Button = $BottomPanel/Controls/PlayBtn
@onready var step_back_btn: Button = $BottomPanel/Controls/StepBackBtn
@onready var step_fwd_btn: Button = $BottomPanel/Controls/StepFwdBtn
@onready var speed_label: Label = $BottomPanel/Controls/SpeedLabel
@onready var seq_label: Label = $BottomPanel/Controls/SeqLabel
@onready var p0_resources: VBoxContainer = $P0Resources
@onready var p1_resources: VBoxContainer = $P1Resources
@onready var buy_panel: BuyPanel = $BuyPanel

var _replay: ReplayController
var _scrubbing: bool = false
var _speeds: Array = [0.5, 1.0, 2.0, 4.0]
var _speed_index: int = 1

func init(replay: ReplayController) -> void:
	_replay = replay
	_replay.snapshot_changed.connect(_on_snapshot_changed)
	play_btn.pressed.connect(_on_play_pressed)
	step_back_btn.pressed.connect(func(): _replay.step_backward())
	step_fwd_btn.pressed.connect(func(): _replay.step_forward())
	scrubber.drag_started.connect(func(): _scrubbing = true)
	scrubber.drag_ended.connect(_on_scrub_ended)

func _on_snapshot_changed(_prev: Variant, current: Variant, _transition_type: String):
	if current == null:
		return
	var phase = str(current.get("phase", "?"))
	var player = "P" + str(current.get("activePlayer", 0))
	turn_label.text = "Turn %d — %s %s" % [current.get("turn", 0), player, phase.capitalize()]

	if not _scrubbing:
		scrubber.max_value = _replay.get_latest_seq()
		scrubber.value = _replay.get_current_seq()
	seq_label.text = "%d/%d" % [_replay.get_current_seq(), _replay.get_latest_seq()]

	# Update resource bars
	_update_resources(p0_resources, current["players"][0]["resources"])
	_update_resources(p1_resources, current["players"][1]["resources"])

	# Show buy panel on first snapshot with deck info
	if current.has("deckInfo") and current["deckInfo"] is Array:
		buy_panel.show_deck(current["deckInfo"])

func _update_resources(container: VBoxContainer, resources: Dictionary) -> void:
	var labels = container.get_children()
	if labels.size() >= 6:
		labels[0].text = "Gold: %d" % resources.get("gold", 0)
		labels[1].text = "Green: %d" % resources.get("green", 0)
		labels[2].text = "Blue: %d" % resources.get("blue", 0)
		labels[3].text = "Red: %d" % resources.get("red", 0)
		labels[4].text = "Energy: %d" % resources.get("energy", 0)
		labels[5].text = "Attack: %d" % resources.get("attack", 0)

func _on_play_pressed():
	_replay.toggle_play()
	play_btn.text = "⏸" if _replay.is_playing() else "▶"

func _on_scrub_ended(_value_changed: bool):
	_scrubbing = false
	_replay.jump_to_seq(int(scrubber.value))

func _input(event: InputEvent):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_BRACKETRIGHT:
			_speed_index = mini(_speed_index + 1, _speeds.size() - 1)
			_replay.set_speed(_speeds[_speed_index])
			speed_label.text = str(_speeds[_speed_index]) + "x"
		elif event.keycode == KEY_BRACKETLEFT:
			_speed_index = maxi(_speed_index - 1, 0)
			_replay.set_speed(_speeds[_speed_index])
			speed_label.text = str(_speeds[_speed_index]) + "x"
