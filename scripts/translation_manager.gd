extends Node

# Singleton access for TranslationManager
static func get_instance() -> TranslationManager:
	var tm = find_node("TranslationManager", true, false) as TranslationManager
	if tm == null:
		# If not found in scene tree, create and add to root
		tm = TranslationManager.new()
		get_tree().root.add_child(tm)
		tm.name = "TranslationManager"
	return tm
