# providers/file_provider.gd
class_name FileProvider
extends BaseProvider

var _snapshots: Dictionary = {}  # seq -> snapshot dict
var _latest_seq: int = -1

func load_file(file_path: String) -> void:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		provider_error.emit("Failed to open: " + file_path)
		return

	var json = JSON.new()
	var err = json.parse(file.get_as_text())
	file.close()

	if err != OK:
		provider_error.emit("JSON parse error: " + json.get_error_message())
		return

	var data = json.get_data()
	if not data is Array:
		provider_error.emit("Expected array of snapshots")
		return

	_snapshots.clear()
	_latest_seq = -1

	for snapshot in data:
		if not snapshot is Dictionary or not snapshot.has("seq"):
			continue
		if snapshot.get("schemaVersion", 0) != 1:
			provider_error.emit("Unsupported schema version: " + str(snapshot.get("schemaVersion")))
			return
		var seq = int(snapshot["seq"])
		_snapshots[seq] = snapshot
		if seq > _latest_seq:
			_latest_seq = seq

	print("FileProvider: loaded %d snapshots (seq 0-%d)" % [_snapshots.size(), _latest_seq])

	# Emit availability AFTER all snapshots are cached
	for seq in _snapshots:
		snapshot_available.emit(seq)

func get_snapshot(seq: int) -> Variant:
	return _snapshots.get(seq)

func has_snapshot(seq: int) -> bool:
	return _snapshots.has(seq)

func get_latest_seq() -> int:
	return _latest_seq

func request_snapshot(seq: int) -> void:
	if has_snapshot(seq):
		snapshot_available.emit(seq)

func is_live() -> bool:
	return false

func can_seek() -> bool:
	return true

func get_total_seqs() -> int:
	return _snapshots.size()
