class_name CardVisualAssets
extends RefCounted

## Centralized texture cache for card rendering.
## Load once, access by key. No per-frame resource loading.

var backgrounds: Array = []    # Indexed by BACK_* constants (0-9)
var covers: Array = []         # Indexed by COVER_* constants (0-5)
var shadings: Array = []       # Indexed by SHADING_* constants (0-4)
var icons: Dictionary = {}     # Keyed by icon name string
var effects: Dictionary = {}   # Keyed by effect name string

const BG_FILES = [
    "bg_dead", "bg_block", "bg_busy", "bg_absorb", "bg_chilled",
    "bg_bought", "bg_whitepink", "bg_blockred", "bg_busyblue", "bg_busyred"
]

const COVER_FILES = [
    "", "cover_blackclock", "cover_goldclock", "cover_cage",
    "cover_goldshield", "cover_damagebang"
]

const SHADING_FILES = [
    "", "shade_whiteshield", "shade_blueshield",
    "shade_whiteshieldB", "shade_redshield"
]

const ICON_FILES = [
    "sword_blue", "icon_defend", "icon_clock",
    "icon_hp", "icon_undefendable", "icon_delay", "icon_doom",
    "icon_charge0", "icon_charge1", "icon_charge2", "icon_charge3",
    "icon_tap", "icon_attack",
]

const EFFECT_FILES = ["chill_snowflake"]

func _init() -> void:
    _load_indexed("res://assets/backgrounds/", BG_FILES, backgrounds)
    _load_indexed("res://assets/overlays/", COVER_FILES, covers)
    _load_indexed("res://assets/overlays/", SHADING_FILES, shadings)
    _load_keyed("res://assets/icons/", ICON_FILES, icons)
    _load_keyed("res://assets/effects/", EFFECT_FILES, effects)

func _load_indexed(dir: String, names: Array, target: Array) -> void:
    for name in names:
        if name == "":
            target.append(null)
        else:
            var tex_path = "%s%s.png" % [dir, name]
            if ResourceLoader.exists(tex_path):
                target.append(load(tex_path))
            else:
                push_warning("CardVisualAssets: missing %s" % tex_path)
                target.append(null)

func _load_keyed(dir: String, names: Array, target: Dictionary) -> void:
    for name in names:
        var tex_path = "%s%s.png" % [dir, name]
        if ResourceLoader.exists(tex_path):
            target[name] = load(tex_path)
        else:
            push_warning("CardVisualAssets: missing %s" % tex_path)

func get_background(index: int) -> Texture2D:
    if index >= 0 and index < backgrounds.size():
        return backgrounds[index]
    return null

func get_cover(index: int) -> Texture2D:
    if index >= 0 and index < covers.size():
        return covers[index]
    return null

func get_shading(index: int) -> Texture2D:
    if index >= 0 and index < shadings.size():
        return shadings[index]
    return null

func get_icon(key: String) -> Texture2D:
    return icons.get(key)

func get_effect(key: String) -> Texture2D:
    return effects.get(key)
