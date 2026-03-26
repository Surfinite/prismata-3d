extends Node3D

func _ready():
	print("Prismata 3D Viewer loaded")

	var provider = FileProvider.new()
	provider.provider_error.connect(_on_provider_error)
	provider.load_file("res://data/test_match.json")
	print("Latest seq: ", provider.get_latest_seq())
	print("Total seqs: ", provider.get_total_seqs())
	var snap = provider.get_snapshot(0)
	if snap:
		print("First snapshot turn: ", snap.get("turn"))
		print("P0 units: ", snap["players"][0]["units"].size())
		print("P1 units: ", snap["players"][1]["units"].size())

func _on_provider_error(msg: String):
	push_error("Provider error: " + msg)
