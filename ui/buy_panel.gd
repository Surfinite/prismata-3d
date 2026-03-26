class_name BuyPanel
extends HBoxContainer

## Displays the randomizer set (buy panel) across the top of the screen.
## Reads deckInfo from the first snapshot and shows card sprites with costs.

const CARD_SIZE = 64  # display size for buy panel icons

var _initialized: bool = false

func show_deck(deck_info: Array) -> void:
	if _initialized:
		return
	_initialized = true

	# Clear any existing children
	for child in get_children():
		child.queue_free()

	# Filter to randomizer cards only (non-base-set), sorted alphabetically
	var randomizer: Array = []
	for card in deck_info:
		if card.get("baseSet", false) == false:
			randomizer.append(card)
	randomizer.sort_custom(func(a, b): return str(a.get("displayName", "")) < str(b.get("displayName", "")))

	for card in randomizer:
		var card_id = str(card.get("cardId", ""))
		var display_name = str(card.get("displayName", ""))
		var buy_cost = str(card.get("buyCost", "0"))

		# Container for each card
		var vbox = VBoxContainer.new()
		vbox.alignment = BoxContainer.ALIGNMENT_CENTER

		# Card sprite
		var tex_rect = TextureRect.new()
		tex_rect.custom_minimum_size = Vector2(CARD_SIZE, CARD_SIZE)
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL

		var sprite_path = "res://assets/card_sprites/%s.png" % card_id
		if ResourceLoader.exists(sprite_path):
			tex_rect.texture = load(sprite_path)

		vbox.add_child(tex_rect)

		# Cost label
		var cost_label = Label.new()
		cost_label.text = _format_cost(buy_cost)
		cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost_label.add_theme_font_size_override("font_size", 10)
		vbox.add_child(cost_label)

		add_child(vbox)

## Convert internal cost string to readable format.
## "6BB" → "6BB", "3GG" → "3GG", "15BBB" → "15BBB"
## Mapping: G=green, B=blue, C=red, H=energy, digits=gold
func _format_cost(cost: String) -> String:
	return cost.replace("C", "R").replace("H", "E")
