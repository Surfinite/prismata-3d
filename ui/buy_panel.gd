class_name BuyPanel
extends VBoxContainer

## Vertical buy panel on the left side — base cards, separator, randomizer cards.
## Each row: card art thumbnail + name + cost pips + supply count.

const ROW_HEIGHT = 36
const ART_SIZE = 28
const PIP_SIZE = 9
const PIP_GAP = 1
const FONT_SIZE_NAME = 9
const FONT_SIZE_SUPPLY = 9

# Cost pip colors (matching SWF/PixiJS)
const COLOR_GOLD = Color(1.0, 0.8, 0.0)
const COLOR_GREEN = Color(0.27, 0.8, 0.27)
const COLOR_BLUE = Color(0.27, 0.53, 1.0)
const COLOR_RED = Color(0.8, 0.2, 0.2)
const COLOR_ENERGY = Color(0.6, 0.4, 1.0)

# Base card display order (SWF order)
const BASE_ORDER = ["Drone", "Engineer", "Conduit", "Blastforge", "Animus"]

var _initialized: bool = false

func show_deck(deck_info: Array) -> void:
	if _initialized:
		return
	_initialized = true

	for child in get_children():
		child.queue_free()

	# Split into base and randomizer
	var base_cards: Array = []
	var random_cards: Array = []
	var card_by_name: Dictionary = {}

	for card in deck_info:
		card_by_name[str(card.get("displayName", ""))] = card
		if card.get("baseSet", false):
			base_cards.append(card)
		else:
			random_cards.append(card)

	# Sort base cards in SWF order
	var ordered_base: Array = []
	for name in BASE_ORDER:
		if card_by_name.has(name):
			ordered_base.append(card_by_name[name])

	# Sort randomizer alphabetically
	random_cards.sort_custom(func(a, b): return str(a.get("displayName", "")) < str(b.get("displayName", "")))

	# Add base cards
	for card in ordered_base:
		add_child(_make_card_row(card))

	# Separator
	var sep = HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 4)
	add_child(sep)

	# Add randomizer cards
	for card in random_cards:
		add_child(_make_card_row(card))


func _make_card_row(card: Dictionary) -> Control:
	var card_id = str(card.get("cardId", ""))
	var display_name = str(card.get("displayName", ""))
	var buy_cost = str(card.get("buyCost", "0"))
	var supply = int(card.get("supply", 0))

	# Row panel with dark background
	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(140, ROW_HEIGHT)

	# Style: dark semi-transparent background
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.118, 0.18, 0.85)
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	style.content_margin_left = 3
	style.content_margin_right = 3
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	panel.add_theme_stylebox_override("panel", style)

	# Main layout: left info + right art
	var hbox = HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Left side: name + cost pips stacked
	var left = VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 1)

	# Name label
	var name_lbl = Label.new()
	name_lbl.text = display_name
	name_lbl.add_theme_font_size_override("font_size", FONT_SIZE_NAME)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	left.add_child(name_lbl)

	# Cost pips row
	var pip_row = HBoxContainer.new()
	pip_row.add_theme_constant_override("separation", PIP_GAP)
	var pips = _parse_cost(buy_cost)
	for pip_color in pips:
		var pip = ColorRect.new()
		pip.custom_minimum_size = Vector2(PIP_SIZE, PIP_SIZE)
		pip.color = pip_color
		pip_row.add_child(pip)
	left.add_child(pip_row)

	# Supply label
	var supply_lbl = Label.new()
	supply_lbl.text = "x%d" % supply
	supply_lbl.add_theme_font_size_override("font_size", FONT_SIZE_SUPPLY)
	supply_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	left.add_child(supply_lbl)

	hbox.add_child(left)

	# Right side: card art thumbnail
	var art = TextureRect.new()
	art.custom_minimum_size = Vector2(ART_SIZE, ART_SIZE)
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	var sprite_path = "res://assets/card_sprites/%s.png" % card_id
	if ResourceLoader.exists(sprite_path):
		art.texture = load(sprite_path)
	hbox.add_child(art)

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
