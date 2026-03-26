class_name BuyPanel
extends VBoxContainer

## Two-column buy panel — base cards (left), randomizer cards (right).
## Each row: card art thumbnail (left) + name + cost pips + supply (right).
## Matches SWF layout: two side-by-side columns.

const ROW_HEIGHT = 32
const ART_SIZE = 26
const PIP_SIZE = 8
const PIP_GAP = 1
const FONT_SIZE_NAME = 9
const FONT_SIZE_SUPPLY = 8

# Cost pip colors (matching SWF/PixiJS)
const COLOR_GOLD = Color(1.0, 0.8, 0.0)
const COLOR_GREEN = Color(0.27, 0.8, 0.27)
const COLOR_BLUE = Color(0.27, 0.53, 1.0)
const COLOR_RED = Color(0.8, 0.2, 0.2)
const COLOR_ENERGY = Color(0.6, 0.4, 1.0)

# Base card identification uses the baseSet flag from deck data.
# Display order preserved from mergedDeck (SWF internal card ID order).

var _initialized: bool = false

func show_deck(deck_info: Array) -> void:
	if _initialized:
		return
	_initialized = true

	for child in get_children():
		child.queue_free()

	# Split into base and randomizer, preserving mergedDeck order (SWF internal card ID order)
	# Non-buyable cards (spawned tokens) are already filtered out by replay_to_snapshots.js
	var base_cards: Array = []
	var random_cards: Array = []

	for card in deck_info:
		if card.get("baseSet", false):
			base_cards.append(card)
		else:
			random_cards.append(card)

	# Two-column layout: 11 base cards (left), randomizer cards (right)
	var columns = HBoxContainer.new()
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 4)

	var left_col = VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.add_theme_constant_override("separation", 2)

	var right_col = VBoxContainer.new()
	right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_col.add_theme_constant_override("separation", 2)

	# Left column: base cards in mergedDeck order
	for card in base_cards:
		left_col.add_child(_make_card_row(card))

	# Right column: randomizer cards
	for card in random_cards:
		right_col.add_child(_make_card_row(card))

	columns.add_child(left_col)
	columns.add_child(right_col)
	add_child(columns)


func _make_card_row(card: Dictionary) -> Control:
	var card_id = str(card.get("cardId", ""))
	var display_name = str(card.get("displayName", ""))
	var buy_cost = str(card.get("buyCost", "0"))
	var supply = int(card.get("supply", 0))

	# Row panel with dark background
	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, ROW_HEIGHT)

	# Style: dark semi-transparent background
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.118, 0.18, 0.85)
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	style.content_margin_left = 2
	style.content_margin_right = 2
	style.content_margin_top = 1
	style.content_margin_bottom = 1
	panel.add_theme_stylebox_override("panel", style)

	# Main layout: art (left) + info (right)
	var hbox = HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_theme_constant_override("separation", 3)

	# Left side: card art thumbnail
	var art = TextureRect.new()
	art.custom_minimum_size = Vector2(ART_SIZE, ART_SIZE)
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	var sprite_path = "res://assets/card_sprites/%s.png" % card_id
	if ResourceLoader.exists(sprite_path):
		art.texture = load(sprite_path)
	hbox.add_child(art)

	# Right side: name + cost pips stacked
	var right = VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 0)

	# Name label
	var name_lbl = Label.new()
	name_lbl.text = display_name
	name_lbl.add_theme_font_size_override("font_size", FONT_SIZE_NAME)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	right.add_child(name_lbl)

	# Cost pips row + supply count on same line
	var cost_row = HBoxContainer.new()
	cost_row.add_theme_constant_override("separation", PIP_GAP)
	var pips = _parse_cost(buy_cost)
	for pip_color in pips:
		var pip = ColorRect.new()
		pip.custom_minimum_size = Vector2(PIP_SIZE, PIP_SIZE)
		pip.color = pip_color
		cost_row.add_child(pip)

	# Supply count after pips
	var supply_lbl = Label.new()
	supply_lbl.text = "x%d" % supply
	supply_lbl.add_theme_font_size_override("font_size", FONT_SIZE_SUPPLY)
	supply_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	cost_row.add_child(supply_lbl)

	right.add_child(cost_row)

	hbox.add_child(right)
	panel.add_child(hbox)
	return panel


func _parse_cost(cost: String) -> Array:
	var pips: Array = []
	var gold_str = ""

	for ch in cost:
		if ch.is_valid_int():
			gold_str += ch
		elif ch == "G":
			pips.append(COLOR_GREEN)
		elif ch == "B":
			pips.append(COLOR_BLUE)
		elif ch == "C":
			pips.append(COLOR_RED)
		elif ch == "H":
			pips.append(COLOR_ENERGY)

	# Gold pips first
	var gold_count = int(gold_str) if gold_str != "" else 0
	var result: Array = []
	for i in range(gold_count):
		result.append(COLOR_GOLD)
	result.append_array(pips)
	return result
