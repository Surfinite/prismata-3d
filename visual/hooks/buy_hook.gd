class_name BuyHook
extends RefCounted

func handle_event(event: Dictionary, context: VisualContext) -> void:
	var unit_id = int(event.get("unitId", -1))
	var node = context.get_unit_node(unit_id)
	if node:
		var tween = node.create_tween()
		tween.tween_property(node, "scale", Vector3(1.3, 1.3, 1.3), 0.1)
		tween.tween_property(node, "scale", Vector3.ONE, 0.2)
