extends Control
## Title screen: start, how-to-play, settings, quit.

var _serif: Font
var _sans: Font
var _fade: ColorRect
var _menu: VBoxContainer
var _info: Control
var _settings: Control
var _settings_first: Control
var _info_first: Control
var _press_hint: Label
var _best_label: Label
var _time := 0.0
var _starting := false
var _lang_btn: Button
var _menu_first_focus: Control

func _ready() -> void:
	Game.run_active = false
	if Game.autotest and "--flow" in OS.get_cmdline_user_args():
		# attach to the root so the test survives the scene change
		get_tree().root.add_child.call_deferred(load("res://scripts/flowtest.gd").new())
	_serif = load("res://assets/fonts/DejaVuSerif-Bold.ttf")
	_sans = load("res://assets/fonts/DejaVuSans.ttf")
	_build()
	Sfx.resume_ambience()
	Sfx.set_loop_volume("static_loop", -60.0)
	Sfx.set_heartbeat(0.0, -60.0)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_fade.color.a = 1.0
	create_tween().tween_property(_fade, "color:a", 0.0, 1.6)


func _label(text: String, size: int, color := Color(0.88, 0.87, 0.84), font: Font = null) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font if font != null else _sans)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 3)
	return l


func _button(text: String, size := 24) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(300, 56)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", _sans)
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", Color(0.82, 0.81, 0.78))
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(0.6, 0.6, 0.6))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.03, 0.03, 0.04, 0.55)
	normal.border_color = Color(0.28, 0.28, 0.3, 0.8)
	normal.set_border_width_all(1)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.1, 0.1, 0.11, 0.8)
	hover.border_color = Color(0.62, 0.62, 0.64)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.03, 0.03, 0.03, 0.95)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", hover)
	return b


func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := TextureRect.new()
	bg.texture = load("res://assets/textures/title_bg.png")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var vig := ColorRect.new()
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	var vm := ShaderMaterial.new()
	vm.shader = load("res://shaders/vignette.gdshader")
	vm.set_shader_parameter("strength", 0.95)
	vig.material = vm
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vig)

	# --- title ------------------------------------------------------------
	var title := _label(TranslationManager.get_instance().get_string("title_main"), 88, Color(0.9, 0.89, 0.86), _serif)
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.offset_top = 92
	title.offset_bottom = 200
	title.offset_left = 0
	title.offset_right = 0
	add_child(title)

	var sub := _label(TranslationManager.get_instance().get_string("title_subtitle"), 20, Color(0.55, 0.56, 0.56))
	sub.set_anchors_preset(Control.PRESET_CENTER_TOP)
	sub.anchor_left = 0.0
	sub.anchor_right = 1.0
	sub.offset_top = 196
	sub.offset_bottom = 230
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(sub)

	# --- menu -------------------------------------------------------------
	_menu = VBoxContainer.new()
	_menu.anchor_left = 0.5
	_menu.anchor_right = 0.5
	_menu.anchor_top = 0.5
	_menu.anchor_bottom = 0.5
	_menu.offset_left = -150
	_menu.offset_right = 150
	_menu.offset_top = 10
	_menu.offset_bottom = 330
	_menu.alignment = BoxContainer.ALIGNMENT_CENTER
	_menu.add_theme_constant_override("separation", 12)
	add_child(_menu)

	var start := _button(TranslationManager.get_instance().get_string("button_begin"))
	start.pressed.connect(_start_game)
	_menu.add_child(start)
	_menu_first_focus = start

	var how := _button(TranslationManager.get_instance().get_string("button_how"))
	how.pressed.connect(func():
		_menu.visible = false
		_info.visible = true
		pass)
	_menu.add_child(how)

	var settings := _button(TranslationManager.get_instance().get_string("button_settings"))
	settings.pressed.connect(func():
		_menu.visible = false
		_settings.visible = true
		pass)
	_menu.add_child(settings)

	var quit := _button(TranslationManager.get_instance().get_string("button_quit"))
	quit.pressed.connect(func(): get_tree().quit())
	_menu.add_child(quit)

	_best_label = _label(_best_text(), 17, Color(0.5, 0.5, 0.5))
	_best_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_best_label.anchor_top = 1.0
	_best_label.anchor_bottom = 1.0
	_best_label.offset_left = 32
	_best_label.offset_top = -92
	_best_label.offset_right = 600
	_best_label.offset_bottom = -60
	add_child(_best_label)

	var controls := _label(controls_text(), 15, Color(0.46, 0.46, 0.46))
	controls.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	controls.anchor_top = 1.0
	controls.anchor_bottom = 1.0
	controls.anchor_left = 1.0
	controls.anchor_right = 1.0
	controls.offset_left = -640
	controls.offset_right = -32
	controls.offset_top = -92
	controls.offset_bottom = -60
	controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(controls)

	var credit := _label(TranslationManager.get_instance().get_string("credit"), 13, Color(0.36, 0.36, 0.36))
	credit.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	credit.anchor_top = 1.0
	credit.anchor_bottom = 1.0
	credit.offset_left = 32
	credit.offset_top = -52
	credit.offset_right = 640
	credit.offset_bottom = -30
	add_child(credit)

	_build_info()
	_build_settings()

	_fade = ColorRect.new()
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.color = Color(0, 0, 0, 1)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)

	# Language switch button
	_lang_btn = _button("EN/RU/ZH", 16)
	_lang_btn.custom_minimum_size = Vector2(120, 40)
	_lang_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_lang_btn.anchor_left = 1.0
	_lang_btn.anchor_right = 1.0
	_lang_btn.anchor_top = 1.0
	_lang_btn.anchor_bottom = 1.0
	_lang_btn.offset_left = -150
	_lang_btn.offset_right = -20
	_lang_btn.offset_top = -80
	_lang_btn.offset_bottom = -30
	_lang_btn.pressed.connect(_toggle_language)
	add_child(_lang_btn)


func _toggle_language() -> void:
	var tm = TranslationManager.get_instance()
	var next_lang = tm.get_language()
	if next_lang == TranslationManager.Language.EN:
		next_lang = TranslationManager.Language.RU
	elif next_lang == TranslationManager.Language.RU:
		next_lang = TranslationManager.Language.ZH
	else:
		next_lang = TranslationManager.Language.EN
	tm.set_language(next_lang)
	_refresh_ui()


func _refresh_ui() -> void:
	# Refresh title screen text
	for child in get_children():
		if child is Label:
			pass # Handle specific labels
	
	# Rebuild menu buttons
	for child in _menu.get_children():
		_menu.remove_child(child)
		child.queue_free()
	
	var start := _button(TranslationManager.get_instance().get_string("button_begin"))
	start.pressed.connect(_start_game)
	_menu.add_child(start)
	_menu_first_focus = start

	var how := _button(TranslationManager.get_instance().get_string("button_how"))
	how.pressed.connect(func():
		_menu.visible = false
		_info.visible = true
		pass)
	_menu.add_child(how)

	var settings := _button(TranslationManager.get_instance().get_string("button_settings"))
	settings.pressed.connect(func():
		_menu.visible = false
		_settings.visible = true
		pass)
	_menu.add_child(settings)

	var quit := _button(TranslationManager.get_instance().get_string("button_quit"))
	quit.pressed.connect(func(): get_tree().quit())
	_menu.add_child(quit)

	_best_label.text = _best_text()
	
	# Refresh controls text
	for child in get_children():
		if child.name == "controls_label" or child is Label and (child.text.begins_with("WASD") or child.text.begins_with("drag") or child.text.begins_with("键盘") or child.text.begins_with("влево")):
			child.text = controls_text()
	
	# Refresh credit
	for child in get_children():
		if child is Label and (child.text.begins_with("a tribute") or child.text.begins_with("дань") or child.text.begins_with("向")):
			child.text = TranslationManager.get_instance().get_string("credit")
	
	# Refresh info panel
	for child in _info.get_children():
		if child is VBoxContainer:
			for sub in child.get_children():
				if sub is Label and (sub.text.begins_with("HOW TO") or sub.text.begins_with("КАК") or sub.text.begins_with("如何")):
					sub.text = TranslationManager.get_instance().get_string("how_header")
				elif sub is Label and (sub.text.begins_with("You are") or sub.text.begins_with("Вы") or sub.text.begins_with("你")):
					sub.text = TranslationManager.get_instance().get_string("how_body")
				elif sub is Label and (sub.text.begins_with("KEYBOARD") or sub.text.begins_with("КЛАВИАТУРА") or sub.text.begins_with("键盘")):
					sub.text = TranslationManager.get_instance().get_string("how_keys_keyboard") + "\n" + TranslationManager.get_instance().get_string("how_keys_touch")
				elif sub is Button:
					sub.text = TranslationManager.get_instance().get_string("button_back")
	
	# Refresh settings panel
	for child in _settings.get_children():
		if child is VBoxContainer:
			for sub in child.get_children():
				if sub is Label and (sub.text.begins_with("SETTINGS") or sub.text.begins_with("НАСТРОЙКИ") or sub.text.begins_with("设置")):
					sub.text = TranslationManager.get_instance().get_string("settings_header")
				elif sub is HBoxContainer:
					for s in sub.get_children():
						if s is Label and (s.text.begins_with("MOUSE") or s.text.begins_with("ЧУВСТВИТЕЛЬНОСТЬ") or s.text.begins_with("鼠标")):
							s.text = TranslationManager.get_instance().get_string("setting_mouse")
						elif s is Label and (s.text.begins_with("VOLUME") or s.text.begins_with("ГРОМКОСТЬ") or s.text.begins_with("音量")):
							s.text = TranslationManager.get_instance().get_string("setting_volume")
						elif s is CheckButton and (s.text.begins_with("INVERT") or s.text.begins_with("ИНВЕРТИРОВАТЬ") or s.text.begins_with("反转")):
							s.text = TranslationManager.get_instance().get_string("setting_invert")
						elif s is CheckButton and (s.text.begins_with("FORCE") or s.text.begins_with("ПРИНУДИТЕЛЬНЫЕ") or s.text.begins_with("强制")):
							s.text = TranslationManager.get_instance().get_string("setting_touch")
				elif sub is Button:
					sub.text = TranslationManager.get_instance().get_string("button_back")


func _panel() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 0.5
	box.anchor_bottom = 0.5
	box.offset_left = -330
	box.offset_right = 330
	box.offset_top = -230
	box.offset_bottom = 250
	box.add_theme_constant_override("separation", 14)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.visible = false
	add_child(box)
	return box


func _plain(text: String, size := 18, color := Color(0.72, 0.72, 0.7)) -> Label:
	var l := _label(text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


func _build_info() -> void:
	_info = _panel()
	var head := _plain(TranslationManager.get_instance().get_string("how_header"), 32, Color(0.9, 0.89, 0.86))
	head.add_theme_font_override("font", _serif)
	(_info as VBoxContainer).add_child(head)
	var body := _plain(
		TranslationManager.get_instance().get_string("how_body"),
		18)
	(_info as VBoxContainer).add_child(body)
	var keys := _plain(
		TranslationManager.get_instance().get_string("how_keys_keyboard") + "\n" + TranslationManager.get_instance().get_string("how_keys_touch"),
		15, Color(0.55, 0.55, 0.55))
	(_info as VBoxContainer).add_child(keys)
	var back := _button(TranslationManager.get_instance().get_string("button_back"), 20)
	back.pressed.connect(func():
		_info.visible = false
		_menu.visible = true
		pass)
	(_info as VBoxContainer).add_child(back)
	_info_first = back


func _slider_row(box: VBoxContainer, label: String, min_v: float, max_v: float, step: float, value: float, cb: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	var l := _label(label, 18, Color(0.7, 0.7, 0.68))
	l.custom_minimum_size = Vector2(220, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(300, 24)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.value_changed.connect(cb)
	row.add_child(s)
	box.add_child(row)


func _check_row(box: VBoxContainer, label: String, value: bool, cb: Callable) -> void:
	var c := CheckButton.new()
	c.text = label
	c.button_pressed = value
	c.add_theme_font_override("font", _sans)
	c.add_theme_font_size_override("font_size", 18)
	c.add_theme_color_override("font_color", Color(0.7, 0.7, 0.68))
	c.toggled.connect(cb)
	box.add_child(c)


func _build_settings() -> void:
	var box := _panel()
	_settings = box
	var head := _plain(TranslationManager.get_instance().get_string("settings_header"), 32, Color(0.9, 0.89, 0.86))
	head.add_theme_font_override("font", _serif)
	box.add_child(head)
	_slider_row(box, TranslationManager.get_instance().get_string("setting_mouse"), 0.2, 3.0, 0.05, Settings.mouse_sensitivity, func(v: float):
		Settings.mouse_sensitivity = v
		Settings.save_settings())
	_slider_row(box, TranslationManager.get_instance().get_string("setting_volume"), 0.0, 1.0, 0.02, Settings.master_volume, func(v: float):
		Settings.master_volume = v
		Settings.apply_volume())
	_check_row(box, TranslationManager.get_instance().get_string("setting_invert"), Settings.invert_y, func(v: bool):
		Settings.invert_y = v
		Settings.save_settings())
	_check_row(box, TranslationManager.get_instance().get_string("setting_touch"), Settings.force_touch, func(v: bool):
		Settings.force_touch = v
		Game.touch_mode = v
		Settings.save_settings())
	var back := _button(TranslationManager.get_instance().get_string("button_back"), 20)
	back.pressed.connect(func():
		_settings.visible = false
		_menu.visible = true
		pass)
	box.add_child(back)
	_settings_first = back


func controls_text() -> String:
	if Game.touch_mode:
		return TranslationManager.get_instance().get_string("controls_touch")
	return TranslationManager.get_instance().get_string("controls_keyboard")


func _best_text() -> String:
	if Settings.best_time < 0.0:
		return TranslationManager.get_instance().get_string("best_none")
	return TranslationManager.get_instance().get_string("best_format") % [Game.format_time(Settings.best_time), Settings.best_pages]


func _start_game() -> void:
	if _starting:
		return
	_starting = true
	Sfx.play("ui_click", -8.0, 0.8)
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 1.0, 1.1)
	await tw.finished
	get_tree().change_scene_to_file("res://scenes/World.tscn")


func _process(delta: float) -> void:
	_time += delta
	if _fade != null and _press_hint != null:
		_press_hint.modulate.a = 0.5 + 0.5 * sin(_time * 2.0)
