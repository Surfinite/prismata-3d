class_name KillHook
extends RefCounted

func handle_event(event: Dictionary, context: VisualContext) -> void:
	var unit_id = int(event.get("unitId", -1))
	var pos = context.get_prev_unit_world_position(unit_id)
	if pos == Vector3.ZERO:
		return
	_spawn_death_flash(context.battlefield_root, pos)

func _spawn_death_flash(parent: Node3D, pos: Vector3) -> void:
	var mesh = MeshInstance3D.new()
	mesh.mesh = SphereMesh.new()
	mesh.mesh.radius = 0.3
	mesh.mesh.height = 0.6
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.3, 0.3, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material_override = mat
	parent.add_child(mesh)
	mesh.global_position = pos

	var tween = mesh.create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.5)
	tween.tween_callback(mesh.queue_free)
