class_name CardVisualState
extends RefCounted

## Pure visual-state decision tree.
## Port of tools/visual_state.js — stateless, deterministic.
## Input: snapshot unit data + owner.
## Output: dictionary describing what each layer should show.

# Background frame indices (matches PixiJS UnitCard.ts)
const BACK_DEAD = 0
const BACK_BLOCK = 1
const BACK_BUSY = 2
const BACK_ABSORB = 3
const BACK_BLOCK_FROST = 4
const BACK_BOUGHT = 5
const BACK_WHITEPINK = 6
const BACK_BLOCKRED = 7
const BACK_BUSYBLUE = 8
const BACK_BUSYRED = 9

# Cover overlay indices
const COVER_EMPTY = 0
const COVER_INVSPAWN = 1
const COVER_INVBOUGHT = 2
const COVER_ASSIGNED = 3
const COVER_PROMPT = 4
const COVER_BANG = 5

# Shading overlay indices
const SHADING_EMPTY = 0
const SHADING_NOTBLOCK = 1
const SHADING_BLOCK = 2
const SHADING_DEAD_BLOCK = 3
const SHADING_REDBLOCK = 4

## Compute the full visual state for a single unit.
## Returns a dictionary with all layer decisions.
static func compute(state: Dictionary, stats: Dictionary, owner: int) -> Dictionary:
	var mode = str(state.get("mode", "idle"))
	var blocking = state.get("blocking", false)
	var attacking = state.get("attacking", false)
	var chilled = int(state.get("chilled", 0))
	var hp = int(stats.get("hp", 0))
	var max_hp = int(stats.get("maxHp", 0))
	var damage = max_hp - hp
	var build_turns = int(state.get("buildTurnsRemaining", 0))
	var fragile = state.get("fragile", false)
	var attack_val = int(stats.get("attack", 0))
	var is_bottom = (owner == 0)

	# Dead units shouldn't reach here (removed during reconciliation),
	# but handle defensively.
	var is_dead = (mode == "dead")
	var is_fully_chilled = chilled >= hp and hp > 0

	# --- Phase 1: Base background frame ---
	var back_frame: int
	var show_snowflake = false
	var card_alpha = 1.0

	if is_dead:
		back_frame = BACK_DEAD
	elif is_fully_chilled:
		back_frame = BACK_BLOCK_FROST
		show_snowflake = true
	elif blocking:
		back_frame = BACK_BLOCK if is_bottom else BACK_BLOCKRED
	else:
		back_frame = BACK_BUSYBLUE if is_bottom else BACK_BUSYRED

	# --- Phase 2: Construction / role overrides ---
	var cover_frame = COVER_EMPTY
	var shading_frame = SHADING_EMPTY

	if build_turns >= 1:
		back_frame = BACK_BOUGHT
		cover_frame = COVER_INVSPAWN  # No boughtThisPhase yet — always INVSPAWN
		card_alpha = 0.87
	elif attacking:
		cover_frame = COVER_ASSIGNED

	# Shading: blocking shields
	# Note: SHADING_NOTBLOCK requires defaultBlocking from card metadata (deferred)
	if blocking and not is_dead:
		shading_frame = SHADING_BLOCK if is_bottom else SHADING_REDBLOCK

	# --- Phase 3: Damage overrides ---
	var damage_counter = 0
	if damage > 0 and not is_dead:
		cover_frame = COVER_BANG
		shading_frame = SHADING_EMPTY
		damage_counter = damage
		if blocking:
			back_frame = BACK_ABSORB
		else:
			back_frame = BACK_ABSORB
		# Note: full PixiJS logic distinguishes BACK_WHITEPINK for dead+damaged.
		# Dead units are removed here, so this case doesn't arise in practice.

	return {
		"back_frame": back_frame,
		"cover_frame": cover_frame,
		"shading_frame": shading_frame,
		"card_alpha": card_alpha,
		"show_snowflake": show_snowflake,
		"damage_counter": damage_counter,
		# Pass through stats for status icon logic
		"attack": attack_val,
		"hp": hp,
		"max_hp": max_hp,
		"damage": damage,
		"fragile": fragile,
		"build_turns": build_turns,
		"is_dead": is_dead,
		"chilled": chilled,
		"delay": int(state.get("delay", 0)),
		"lifespan": int(state.get("lifespan", -1)),
		"charge": int(state.get("charge", 0)),
		"frontline": state.get("frontline", false),
	}
