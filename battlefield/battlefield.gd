class_name Battlefield
extends Node3D

const UNIT_NODE_SCENE = preload("res://battlefield/unit_node.tscn")

# Row Z positions (distance from center line)
const ROW_Z = {
	"front": 1.5,
	"middle": 3.5,
	"back": 5.5
}
# Total width available for each row in world units
const ROW_WIDTH = 20.0

var _unit_registry: Dictionary = {}   # unitId (int) -> UnitNode
var _prev_positions: Dictionary = {}  # unitId (int) -> Vector3
var _visual_hooks: VisualHooks = null
var _camera: Camera3D = null

func set_visual_hooks(hooks: VisualHooks) -> void:
	_visual_hooks = hooks

func set_camera(camera: Camera3D) -> void:
	_camera = camera

func apply_snapshot(prev_snapshot: Variant, current_snapshot: Variant, transition_type: String) -> void:
	# Cache positions BEFORE reconciliation (for death effect positioning)
	_prev_positions.clear()
	for unit_id in _unit_registry:
		_prev_positions[unit_id] = _unit_registry[unit_id].global_position

	# Reconcile nodes to match snapshot
	_reconcile(current_snapshot)

	# Dispatch hooks only on forward transitions
	if transition_type == "forward" and current_snapshot and _visual_hooks:
		var context = _build_visual_context(prev_snapshot, current_snapshot)
		_visual_hooks.dispatch(current_snapshot.get("events", []), context)

func _build_visual_context(prev_snapshot: Variant, current_snapshot: Variant) -> VisualContext:
	var ctx = VisualContext.new()
	ctx.prev_snapshot = prev_snapshot
	ctx.current_snapshot = current_snapshot
	ctx._unit_registry = _unit_registry
	ctx._prev_positions = _prev_positions
	ctx.battlefield_root = self
	ctx.camera = _camera
	return ctx

func _reconcile(snapshot: Variant) -> void:
	if snapshot == null:
		return

	# Build set of ALL current unit IDs with their data, tagged with owner
	var current_units: Dictionary = {}  # unitId -> {data, owner}
	for p in range(snapshot["players"].size()):
		var player = snapshot["players"][p]
		for unit in player["units"]:
			var uid = int(unit["id"])
			current_units[uid] = {"data": unit, "owner": p}

	# Remove units no longer present
	var to_remove: Array = []
	for unit_id in _unit_registry:
		if not current_units.has(unit_id):
			to_remove.append(unit_id)
	for unit_id in to_remove:
		_unit_registry[unit_id].queue_free()
		_unit_registry.erase(unit_id)

	# === SWF-faithful layout pipeline ===
	# 1. Group units by (owner, row) → then by cardId into "piles"
	# 2. Sort piles by slot position (left-to-right)
	# 3. Run cramming algorithm to compute pile X positions
	# 4. Within each pile, space cards by the computed gap

	for owner in range(2):
		# Collect this player's units, grouped by row
		var row_units: Dictionary = {"front": [], "middle": [], "back": []}
		for unit_id in current_units:
			var info = current_units[unit_id]
			if info["owner"] != owner:
				continue
			var unit_data = info["data"]
			var render = unit_data.get("render", {})
			var row = str(render.get("row", "middle"))
			if not row_units.has(row):
				row_units[row] = []
			row_units[row].append({"unit_id": unit_id, "data": unit_data})

		for row in row_units:
			var units_in_row = row_units[row]
			if units_in_row.is_empty():
				continue

			# Group by cardId into piles
			var piles: Dictionary = {}  # cardId -> array of {unit_id, data}
			var pile_slots: Dictionary = {}  # cardId -> slot (for sorting)
			for entry in units_in_row:
				var card_id = str(entry["data"].get("cardId", "unknown"))
				if not piles.has(card_id):
					piles[card_id] = []
					var render = entry["data"].get("render", {})
					pile_slots[card_id] = int(render.get("slot", 15))
				piles[card_id].append(entry)

			# Sort pile keys by slot position (left-to-right)
			var sorted_pile_keys = piles.keys()
			sorted_pile_keys.sort_custom(func(a, b): return pile_slots[a] < pile_slots[b])

			# Build pile counts for layout engine
			var pile_counts: Array = []
			for key in sorted_pile_keys:
				pile_counts.append(piles[key].size())

			# Run cramming algorithm
			var layouts = LayoutEngine.compute_row_layout(pile_counts, ROW_WIDTH)

			# Position each unit
			var z_offset = ROW_Z.get(row, 3.5)
			if owner == 1:
				z_offset = -z_offset

			for pile_idx in range(sorted_pile_keys.size()):
				var card_id = sorted_pile_keys[pile_idx]
				var pile_units = piles[card_id]
				var layout = layouts[pile_idx]
				var gap = layout.gap

				# Sort within pile: under_construction first (left), then ready (right)
				pile_units.sort_custom(func(a, b):
					var a_bt = int(a["data"].get("state", {}).get("buildTurnsRemaining", 0))
					var b_bt = int(b["data"].get("state", {}).get("buildTurnsRemaining", 0))
					return a_bt > b_bt  # higher buildTurns = more left
				)

				for card_idx in range(pile_units.size()):
					var entry = pile_units[card_idx]
					var unit_id = entry["unit_id"]
					var unit_data = entry["data"]

					# X position: pile start + card offset within pile
					var x_pos = layout.x + card_idx * gap
					# Center the row around X=0 (layout gives positions from 0)
					var centered_x = x_pos - ROW_WIDTH / 2.0

					var pos = Vector3(centered_x, 0.5, z_offset)

					if _unit_registry.has(unit_id):
						var node = _unit_registry[unit_id]
						node.update_state(unit_data)
						node.position = pos
					else:
						var node = UNIT_NODE_SCENE.instantiate() as UnitNode
						add_child(node)
						node.setup(unit_data)
						node.update_state(unit_data)
						node.position = pos
						_unit_registry[unit_id] = node

func get_unit_node(unit_id: int) -> UnitNode:
	return _unit_registry.get(unit_id)

func get_prev_position(unit_id: int) -> Vector3:
	return _prev_positions.get(unit_id, Vector3.ZERO)
