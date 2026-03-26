# providers/base_provider.gd
class_name BaseProvider
extends RefCounted

signal snapshot_available(seq: int)
signal provider_reset()
signal provider_error(message: String)

func request_snapshot(_seq: int) -> void:
	push_error("BaseProvider.request_snapshot not implemented")

func get_snapshot(_seq: int) -> Variant:
	push_error("BaseProvider.get_snapshot not implemented")
	return null

func has_snapshot(_seq: int) -> bool:
	return false

func get_latest_seq() -> int:
	return -1

func is_live() -> bool:
	return false

func can_seek() -> bool:
	return false

func get_total_seqs() -> int:
	return -1
