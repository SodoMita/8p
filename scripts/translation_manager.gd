class_name TranslationManager
extends Node
## Loads translations/<lang>.json and hands out UI strings.
##
## The branch this came from shipped a stub that could not run: it declared
## `get_instance() -> TranslationManager` inside a script with no `class_name`,
## called the Godot 3 `find_node()`, and used `get_tree()` from a static
## function. Rewritten here as a plain singleton with a lazily built instance.
## English is the fallback table, so a key that a language has not translated
## yet renders as English rather than as a blank label.

enum Language { EN = 0, RU = 1, ZH = 2 }

const FILES := {
	Language.EN: "res://translations/en.json",
	Language.RU: "res://translations/ru.json",
	Language.ZH: "res://translations/zh.json",
}

static var _instance: TranslationManager
var _tables: Dictionary = {}
var _lang: Language = Language.EN


static func get_instance() -> TranslationManager:
	if _instance != null and is_instance_valid(_instance):
		return _instance
	# Deliberately NOT added to the scene tree: it needs no _process, no signals
	# and no viewport, and adding a node from inside another node's _ready() is
	# what produced "Parent node is busy setting up children".
	_instance = TranslationManager.new()
	_instance.name = "TranslationManager"
	return _instance


func _ready() -> void:
	_ensure_loaded()


func _ensure_loaded() -> void:
	if _tables.size() == FILES.size():
		return
	for lang in FILES:
		var path: String = FILES[lang]
		var txt := FileAccess.get_file_as_string(path)
		if txt.is_empty():
			push_warning("TranslationManager: cannot read %s" % path)
			continue
		var parsed = JSON.parse_string(txt)
		if parsed is Dictionary:
			_tables[lang] = parsed
		else:
			push_warning("TranslationManager: %s is not a JSON object" % path)
	if _tables.has(Language.EN):
		_lang = int(Settings.language) as Language


func get_string(key: String) -> String:
	_ensure_loaded()
	var table: Dictionary = _tables.get(_lang, {})
	if table.has(key):
		return str(table[key])
	var fallback: Dictionary = _tables.get(Language.EN, {})
	if fallback.has(key):
		return str(fallback[key])
	return key


func get_language() -> Language:
	return _lang


func set_language(lang: Language) -> void:
	_lang = lang
	Settings.language = int(lang)
	Settings.save_settings()


func cycle_language() -> Language:
	var nxt := Language.EN
	match _lang:
		Language.EN: nxt = Language.RU
		Language.RU: nxt = Language.ZH
		Language.ZH: nxt = Language.EN
	set_language(nxt)
	return _lang
