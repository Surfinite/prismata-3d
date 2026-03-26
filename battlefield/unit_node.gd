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

# Variable icon layout
const VAR_ICON_X = -0.38
const VAR_ICON_START_Z = -0.3
const VAR_ICON_SPACING = 0.18
const VAR_ICON_Y = 0.025

# Fixed icon positions
const ATTACK_ICON_POS = Vector3(0.15, 0.025, 0.32)
const DEFENSE_ICON_POS = Vector3(0.35, 0.025, 0.32)
const ICON_LABEL_OFFSET_Z = 0.12  # label below icon


func _ready() -> void:
	# Initialize shared asset cache once
	if assets == null:
		assets = CardVisualAssets.new()

	_setup_fixed_icons()
	_setup_variable_icons()
	_setup_snowflake()
	_setup_build_timer()


func _setup_fixed_icons() -> void:
	# Attack sword icon + number label
	_attack_icon = _make_icon_sprite(ATTACK_ICON_POS, "sword_blue", SWORD_PIXEL_SIZE)
	_attack_label = _make_icon_label(
		ATTACK_ICON_POS + Vector3(0, 0.001, ICON_LABEL_OFFSET_Z),
		Color(1.0, 0.85, 0.2)
	)

	# Defense shield icon + number label
	_defense_icon = _make_icon_sprite(DEFENSE_ICON_POS, "icon_defend", ICON_PIXEL_SIZE)
	_defense_label = _make_icon_label(
		DEFENSE_ICON_POS + Vector3(0, 0.001, ICON_LABEL_OFFSET_Z),
		Color(0.4, 0.9, 1.0)
	)


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
			pos + Vector3(0, 0.001, ICON_LABEL_OFFSET_Z),
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
	_build_timer_label.transform = Transform3D(FLAT_BASIS, Vector3(0, 0.028, 0.05))
	_build_timer_label.visible = false
	add_child(_build_timer_label)


func _setup_snowflake() -> void:
	_snowflake = Sprite3D.new()
	_snowflake.pixel_size = 0.00676  # 148px effect → 1.0 world unit
	_snowflake.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	var tex = assets.get_effect("chill_snowflake")
	if tex:
		_snowflake.texture = tex
	_snowflake.transform = Transform3D(FLAT_BASIS, Vector3(0, 0.02, 0))
	_snowflake.visible = false
	_effect_container.add_child(_snowflake)


func _make_icon_sprite(pos: Vector3, icon_key: String, pix_size: float) -> Sprite3D:
	var spr = Sprite3D.new()
	spr.pixel_size = pix_size
	spr.billboard = BaseMaterial3D.BILLBOARD_DISABLED
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

	# Set card art sprite
	var sprite_path = "res://assets/card_sprites/%s.png" % card_id
	if ResourceLoader.exists(sprite_path):
		_card_skin.texture = load(sprite_path)

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
		var label_pos = icon_pos + Vector3(0, 0.001, ICON_LABEL_OFFSET_Z)

		icon_entry["icon"].transform = Transform3D(FLAT_BASIS, icon_pos)
		icon_entry["icon"].visible = true

		if info["text"] != "":
			icon_entry["label"].transform = Transform3D(FLAT_BASIS, label_pos)
			icon_entry["label"].text = info["text"]
			icon_entry["label"].visible = true
		else:
			icon_entry["label"].visible = false
