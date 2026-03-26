class_name VisualHooks
extends RefCounted

var _hooks: Dictionary = {}  # event_type (String) -> Array[Callable]

func register(event_type: String, handler: Callable) -> void:
	if not _hooks.has(event_type):
		_hooks[event_type] = []
	_hooks[event_type].append(handler)

func dispatch(events: Array, context: VisualContext) -> void:
	for event in events:
		var type = event.get("type", "")
		if _hooks.has(type):
			for handler in _hooks[type]:
				handler.call(event, context)
