class_name LayoutEngine
extends RefCounted

## Faithful port of AS3 UIPile.as + UIRow.as layout logic.
## Computes X positions for groups of same-type units within a row,
## applying cramming when the row is too wide to fit naturally.

# Layout constants (from AS3/PixiJS constants.ts, converted to world-space)
# Original pixel values: CARD_WIDTH=83, DEFAULTCARDSPACING=16, DEFAULTMARGIN=20
# We convert to world-space by dividing by CARD_WIDTH (1 card = 1.0 world unit)
const CARD_UNIT = 1.0
const CARDSPACING = [0.0, 0.217, 0.217, 0.217, 0.205, 0.205, 0.205, 0.193]
const DEFAULTCARDSPACING = 0.193  # 16/83
const DEFAULTMARGIN = 0.241  # 20/83
const CRAMMEDMARGIN = -0.482  # -40/83
const MIN_CRAM_PERCENT = 0.8
const GAP_SIZE = 2.5

## Stretch factor for card i in a pile of len cards at given cram factor.
## Port of UIPile.as lines 998-1034.
static func stretch_factor(i: int, len: int, cram_factor: float) -> float:
	var cf = cram_factor
	if len > 28 and cf > 0:
		cf = maxf(cf, 1.0 + (len - 28) / 45.0)

	var fully_cramped: float
	if len < 5:
		fully_cramped = 1.0
	elif i < len - 10:
		fully_cramped = 0.58
	elif i < len - 3:
		fully_cramped = 1.0 - 0.06 * (len - 3 - i)
	else:
		fully_cramped = 1.0

	if cf < 1.0:
		return 1.0

	if cf >= 1.5:
		if i < len - 10:
			var cram_index = clampi(len - 10 - i, 0, 10)
			var cram_amount = clampf(cf, 1.5, 2.5) - 1.5
			return fully_cramped - 0.03 * cram_index * cram_amount
		return fully_cramped

	# Linear interpolation between cf=1 and cf=1.5
	return 2.0 * (cf - 1.0) * fully_cramped + 2.0 * (1.5 - cf)

## Desired spacing between cards in a pile of num_cards.
static func desired_spacing(num_cards: int) -> float:
	if num_cards <= 0:
		return 0.0
	if num_cards > CARDSPACING.size():
		return DEFAULTCARDSPACING
	return CARDSPACING[num_cards - 1]

## Pixel width of a pile at given cram factor.
static func pile_width(card_count: int, cram_factor: float) -> float:
	if card_count <= 0:
		return 0.0
	var spacing = desired_spacing(card_count)
	var w = CARD_UNIT
	for i in range(card_count - 1):
		w += stretch_factor(i, card_count, cram_factor) * spacing
	return w

## Average per-card gap within a pile at given cram factor.
static func pile_gap(card_count: int, cram_factor: float) -> float:
	if card_count <= 1:
		return 0.0
	var spacing = desired_spacing(card_count)
	var sum_sf = 0.0
	for i in range(card_count - 1):
		sum_sf += stretch_factor(i, card_count, cram_factor)
	return (sum_sf / (card_count - 1)) * spacing


## Result of layout computation for one pile.
class PileLayout:
	var x: float = 0.0
	var gap: float = 0.0


## Compute layout for an array of piles within a row.
## pile_counts: array of int (number of cards per pile)
## row_width: total available world-space width for the row
## Returns: array of PileLayout (same length as pile_counts)
static func compute_row_layout(pile_counts: Array, row_width: float) -> Array:
	var n = pile_counts.size()
	if n == 0:
		return []

	var num_gaps = n - 1

	# Step 1: Preliminary total width at cram_factor=0
	var prelim_width = 0.0
	for p in range(n):
		prelim_width += pile_width(pile_counts[p], 0.0)
		if p < n - 1:
			prelim_width += DEFAULTMARGIN

	# Step 2: Compute cram factor
	var cram_factor = prelim_width / (MIN_CRAM_PERCENT * row_width)

	# Step 3: Recompute pile widths at actual cram factor
	var widths: Array = []
	var total_pile_area = 0.0
	for p in range(n):
		var w = pile_width(pile_counts[p], cram_factor)
		widths.append(w)
		total_pile_area += w

	var results: Array = []

	if cram_factor <= 1.0:
		# No cramming — natural spacing, centered
		var total_w = total_pile_area + num_gaps * DEFAULTMARGIN
		var start_x = (row_width - total_w) / 2.0

		var x = start_x
		for p in range(n):
			var layout = PileLayout.new()
			layout.x = x
			layout.gap = pile_gap(pile_counts[p], 0.0)
			results.append(layout)
			x += widths[p]
			if p < n - 1:
				x += DEFAULTMARGIN
		return results

	# Step 4: Cramming — distribute remaining space as margins
	var margin_space = row_width - total_pile_area
	var margin = DEFAULTMARGIN
	if num_gaps > 0:
		margin = clampf(margin_space / num_gaps, CRAMMEDMARGIN, DEFAULTMARGIN)

	var actual_total = total_pile_area + num_gaps * margin
	var start_x = maxf(0.0, (row_width - actual_total) / 2.0)

	var x = start_x
	for p in range(n):
		var layout = PileLayout.new()
		layout.x = x
		layout.gap = pile_gap(pile_counts[p], cram_factor)
		results.append(layout)
		x += widths[p]
		if p < n - 1:
			x += margin
	return results
