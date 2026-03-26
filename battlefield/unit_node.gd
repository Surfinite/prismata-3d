class_name UnitNode
extends Node3D

## Layered Sprite3D card renderer.
## Uses CardVisualState (pure decisions) + CardVisualAssets (texture cache).

# Scene nodes
@onready var _bg_frame: Sprite3D = $BackgroundFrame
@onready var _card_skin: Sprite3D = $CardSkin
@onready var _cover_overlay: Sprite3D = $CoverOverlay
@onready var _shading_overlay: Sprite3D = $ShadingOverlay
@onready var _status_overlay: Node3D = $StatusOverlay
@onready var _name_label: Label3D = $NameLabel
@onready var _effect_container: Node3D = $EffectContainer
@onready var _damage_label: Label3D = $DamageLabel

# Identity
var unit_id: int = -1
var card_id: String = ""
var unit_owner: int = 0

# Rotation to lie flat facing up
const FLAT_BASIS = Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))

# Shared texture cache — created once across all UnitNodes
static var assets: CardVisualAssets = null

# Fixed status icons (attack sword, defense shield)
var _attack_icon: Sprite3D
var _attack_label: Label3D
var _defense_icon: Sprite3D
var _defense_label: Label3D

# Variable status icons (created dynamically, repositioned per visible set)
# Each entry: { "icon": Sprite3D, "label": Label3D, "key": String }
var _var_icons: Array = []  # order: hp, frontline, delay, doom, charge, chill

# 3D model override (replaces 2D card layers for specific units)
var _model_instance: MeshInstance3D

# Snowflake effect sprite
var _snowflake: Sprite3D

# Construction timer label (large centered countdown)
var _build_timer_label: Label3D

# Icon sizing
const ICON_PIXEL_SIZE = 0.00688       # 32px icons → ~0.22 world units
const SWORD_PIXEL_SIZE = 0.000477     # 461px sword_blue → ~0.22 world units
const ICON_LABEL_PIXEL_SIZE = 0.004
const ICON_LABEL_FONT_SIZE = 12
const ICON_LABEL_OUTLINE = 6

# Auto-generated from tools/generate_godot_positions.js
# Source: PixiJS constants.ts + StatusOverlay.ts + UnitCard.ts
# Card: 82px = 1.0 world unit. Icon: 18px. Center-anchored.
# Camera screen-up = world -Z, so SWF top (y=0) → negative Z, SWF bottom (y=82) → positive Z.
# Formula: Z = (py / 82) - 0.5

# Fixed icon positions (center of 18px icon)
const ATTACK_ICON_POS = Vector3(-0.0976, 0.025, 0.3537)
const DEFENSE_ICON_POS = Vector3(0.3415, 0.025, 0.3537)
# Fixed icon number positions
const ATTACK_NUM_POS = Vector3(-0.2927, 0.026, 0.2927)
const DEFENSE_NUM_POS = Vector3(0.1463, 0.026, 0.2927)

# Variable icon layout (center of 18px icon, left side of card)
const VAR_ICON_X = -0.3537
const VAR_ICON_START_Z = -0.1341
const VAR_ICON_SPACING = 0.2439  # positive: stacks downward on screen (toward +Z)
const VAR_ICON_Y = 0.025
# Variable number offset from icon center
const VAR_NUM_OFFSET = Vector3(-0.1341, 0.001, -0.0244)


func _ready() -> void:
	# Initialize shared asset cache once
	if assets == null:
		assets = CardVisualAssets.new()

	_setup_fixed_icons()
	_setup_variable_icons()
	_setup_snowflake()
	_setup_build_timer()


func _setup_fixed_icons() -> void:
	# Attack sword icon + number label (SWF: bottom-left area)
	_attack_icon = _make_icon_sprite(ATTACK_ICON_POS, "sword_blue", SWORD_PIXEL_SIZE)
	_attack_label = _make_icon_label(ATTACK_NUM_POS, Color(1.0, 0.85, 0.2))

	# Defense shield icon + number label (SWF: bottom-right area)
	_defense_icon = _make_icon_sprite(DEFENSE_ICON_POS, "icon_defend", ICON_PIXEL_SIZE)
	_defense_label = _make_icon_label(DEFENSE_NUM_POS, Color(0.4, 0.9, 1.0))


func _setup_variable_icons() -> void:
	# Variable icons: hp, frontline, delay, doom, charge, chill
	var var_icon_defs = [
		{"key": "icon_hp", "color": Color(1.0, 0.35, 0.4)},        # HP (red)
		{"key": "icon_undefendable", "color": Color(1.0, 0.6, 0.2)}, # Frontline (orange)
		{"key": "icon_delay", "color": Color(0.8, 0.8, 0.2)},       # Delay (yellow)
		{"key": "icon_doom", "color": Color(0.9, 0.2, 0.9)},        # Doom/lifespan (purple)
		{"key": "icon_charge0", "color": Color(0.3, 0.9, 0.3)},     # Charge (green)
		{"key": "icon_tap", "color": Color(0.5, 0.75, 0.95)},       # Chill (ice blue)
	]

	for i in range(var_icon_defs.size()):
		var def = var_icon_defs[i]
		# Initial position — will be repositioned dynamically
		var pos = Vector3(VAR_ICON_X, VAR_ICON_Y, VAR_ICON_START_Z + i * VAR_ICON_SPACING)
		var icon = _make_icon_sprite(pos, def["key"], ICON_PIXEL_SIZE)
		var lbl = _make_icon_label(
			pos + VAR_NUM_OFFSET,
			def["color"]
		)
		_var_icons.append({"icon": icon, "label": lbl, "key": def["key"]})


func _setup_build_timer() -> void:
	_build_timer_label = Label3D.new()
	_build_timer_label.pixel_size = 0.005
	_build_timer_label.font_size = 28
	_build_timer_label.modulate = Color.WHITE
	_build_timer_label.outline_size = 6
	_build_timer_label.outline_modulate = Color(0, 0, 0, 1)
	_build_timer_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_build_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_build_timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_build_timer_label.transform = Transform3D(FLAT_BASIS, Vector3(-0.4878, 0.028, -0.4634))  # SWF pixel (1, 3)
	_build_timer_label.visible = false
	add_child(_build_timer_label)


func _setup_snowflake() -> void:
	_snowflake = Sprite3D.new()
	_snowflake.pixel_size = 0.00676  # 148px effect → 1.0 world unit
	_snowflake.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	var tex = assets.get_effect("chill_snowflake")
	if tex:
		_snowflake.texture = tex
	_snowflake.transform = Transform3D(FLAT_BASIS, Vector3(0.0, 0.02, 0.0244))  # SWF center (41, 43)
	_snowflake.visible = false
	_effect_container.add_child(_snowflake)


func _make_icon_sprite(pos: Vector3, icon_key: String, pix_size: float) -> Sprite3D:
	var spr = Sprite3D.new()
	spr.pixel_size = pix_size
	spr.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	spr.flip_v = true  # Match CardSkin flip_v orientation
	var tex = assets.get_icon(icon_key)
	if tex:
		spr.texture = tex
	spr.transform = Transform3D(FLAT_BASIS, pos)
	spr.visible = false
	_status_overlay.add_child(spr)
	return spr


func _make_icon_label(pos: Vector3, color: Color) -> Label3D:
	var lbl = Label3D.new()
	lbl.pixel_size = ICON_LABEL_PIXEL_SIZE
	lbl.font_size = ICON_LABEL_FONT_SIZE
	lbl.modulate = color
	lbl.outline_size = ICON_LABEL_OUTLINE
	lbl.outline_modulate = Color(0, 0, 0, 1)
	lbl.transform = Transform3D(FLAT_BASIS, pos)
	lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.visible = false
	_status_overlay.add_child(lbl)
	return lbl


func setup(unit_data: Dictionary, p_owner: int) -> void:
	unit_id = int(unit_data["id"])
	card_id = unit_data["cardId"]
	unit_owner = p_owner

	# Set card art sprite — scale to fit inside background frame (0.878 of 1.0 world unit)
	var sprite_path = "res://assets/card_sprites/%s.png" % card_id
	if ResourceLoader.exists(sprite_path):
		var tex = load(sprite_path)
		_card_skin.texture = tex
		# Cards are mixed sizes (128×128, 300×300). Set pixel_size so art
		# renders at 0.878 world units regardless of source dimensions.
		var tex_width = tex.get_width()
		if tex_width > 0:
			_card_skin.pixel_size = 0.878 / float(tex_width)

	# 3D model override for drone
	if card_id == "drone":
		_try_load_3d_model("res://assets/models/blossom.obj")

	# Optional name label (hidden by default)
	_name_label.text = unit_data.get("displayName", card_id)


func update_state(unit_data: Dictionary, p_owner: int) -> void:
	unit_owner = p_owner
	var state = unit_data.get("state", {})
	var stats = unit_data.get("stats", {})

	# Compute visual state (pure decision logic)
	var vs = CardVisualState.compute(state, stats, unit_owner)

	_apply_layers(vs)
	_apply_status_icons(vs)


func _apply_layers(vs: Dictionary) -> void:
	# Background frame
	var bg_tex = assets.get_background(vs["back_frame"])
	if bg_tex:
		_bg_frame.texture = bg_tex
		_bg_frame.visible = true
	else:
		_bg_frame.visible = false

	# Card skin alpha (construction transparency)
	_card_skin.modulate = Color(1, 1, 1, vs["card_alpha"])

	# Cover overlay
	var cover_idx = int(vs["cover_frame"])
	if cover_idx > 0:
		var cover_tex = assets.get_cover(cover_idx)
		if cover_tex:
			_cover_overlay.texture = cover_tex
			_cover_overlay.visible = true
		else:
			_cover_overlay.visible = false
	else:
		_cover_overlay.visible = false

	# Shading overlay
	var shading_idx = int(vs["shading_frame"])
	if shading_idx > 0:
		var shading_tex = assets.get_shading(shading_idx)
		if shading_tex:
			_shading_overlay.texture = shading_tex
			_shading_overlay.visible = true
		else:
			_shading_overlay.visible = false
	else:
		_shading_overlay.visible = false

	# Snowflake effect
	_snowflake.visible = vs["show_snowflake"]

	# Damage label
	var dmg = int(vs["damage_counter"])
	if dmg > 0:
		_damage_label.text = str(dmg)
		_damage_label.modulate = Color(1.0, 0.2, 0.2)
		_damage_label.visible = true
	else:
		_damage_label.visible = false

	# Construction timer (large centered number)
	var build_turns = int(vs["build_turns"])
	if build_turns > 0:
		_build_timer_label.text = str(build_turns)
		_build_timer_label.visible = true
	else:
		_build_timer_label.visible = false


func _apply_status_icons(vs: Dictionary) -> void:
	var is_dead = vs["is_dead"]

	# --- Fixed icons: attack sword + defense shield ---

	# Attack
	var attack_val = int(vs["attack"])
	if attack_val > 0 and not is_dead:
		_attack_icon.visible = true
		_attack_label.text = str(attack_val)
		_attack_label.visible = true
	else:
		_attack_icon.visible = false
		_attack_label.visible = false

	# Defense (non-fragile: show maxHp as toughness)
	var max_hp = int(vs["max_hp"])
	var fragile = vs["fragile"]
	if not fragile and max_hp > 0 and not is_dead:
		_defense_icon.visible = true
		_defense_label.text = str(max_hp)
		_defense_label.visible = true
	else:
		_defense_icon.visible = false
		_defense_label.visible = false

	# --- Variable icons: show only relevant ones, stacked on left ---

	var hp = int(vs["hp"])
	var chilled = int(vs["chilled"])
	var delay_val = int(vs["delay"])
	var lifespan = int(vs["lifespan"])
	var charge = int(vs["charge"])
	var frontline = vs["frontline"]
	var build_turns = int(vs["build_turns"])

	# Build list of (icon_index, value_text) for visible variable icons
	var visible_vars: Array = []

	# HP (fragile units, or damaged non-fragile)
	if fragile and hp > 0 and not is_dead:
		visible_vars.append({"idx": 0, "text": str(hp)})

	# Frontline
	if frontline and not is_dead:
		visible_vars.append({"idx": 1, "text": ""})

	# Delay (under construction)
	if build_turns > 0:
		visible_vars.append({"idx": 2, "text": str(build_turns)})
	elif delay_val > 0 and not is_dead:
		visible_vars.append({"idx": 2, "text": str(delay_val)})

	# Doom / lifespan
	if lifespan >= 0 and not is_dead:
		visible_vars.append({"idx": 3, "text": str(lifespan)})

	# Charge
	if charge > 0 and not is_dead:
		# Pick charge icon variant (0-3)
		var charge_variant = mini(charge, 3)
		var charge_key = "icon_charge%d" % charge_variant
		var charge_tex = assets.get_icon(charge_key)
		if charge_tex:
			_var_icons[4]["icon"].texture = charge_tex
		visible_vars.append({"idx": 4, "text": str(charge)})

	# Chill
	if chilled > 0 and not is_dead:
		visible_vars.append({"idx": 5, "text": str(chilled)})

	# Hide all variable icons first
	for entry in _var_icons:
		entry["icon"].visible = false
		entry["label"].visible = false

	# Position and show visible ones
	for slot_idx in range(visible_vars.size()):
		var info = visible_vars[slot_idx]
		var icon_entry = _var_icons[info["idx"]]
		var z_pos = VAR_ICON_START_Z + slot_idx * VAR_ICON_SPACING
		var icon_pos = Vector3(VAR_ICON_X, VAR_ICON_Y, z_pos)
		var label_pos = icon_pos + VAR_NUM_OFFSET

		icon_entry["icon"].transform = Transform3D(FLAT_BASIS, icon_pos)
		icon_entry["icon"].visible = true

		if info["text"] != "":
			icon_entry["label"].transform = Transform3D(FLAT_BASIS, label_pos)
			icon_entry["label"].text = info["text"]
			icon_entry["label"].visible = true
		else:
			icon_entry["label"].visible = false


func _try_load_3d_model(path: String) -> void:
	print("DEBUG: trying to load model at ", path)
	print("DEBUG: exists=", ResourceLoader.exists(path))
	if not ResourceLoader.exists(path):
		return
	var mesh = load(path)
	print("DEBUG: loaded=", mesh, " type=", type_string(typeof(mesh)))
	if not mesh is Mesh:
		return
	_model_instance = MeshInstance3D.new()
	_model_instance.mesh = mesh
	# Scale to fit roughly one card width (1.0 world unit)
	_model_instance.scale = Vector3(0.01, 0.01, 0.01)
	_model_instance.position = Vector3(0, 0.05, 0)
	_model_instance.rotation_degrees = Vector3(-90, 0, 0)
	add_child(_model_instance)
	# Hide the 2D card layers
	_bg_frame.visible = false
	_card_skin.visible = false
	_cover_overlay.visible = false
	_shading_overlay.visible = false
