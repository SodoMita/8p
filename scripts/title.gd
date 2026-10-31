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
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
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
	var title := _label("EIGHT PAGES", 88, Color(0.9, 0.89, 0.86), _serif)
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.offset_top = 92
	title.offset_bottom = 200
	title.offset_left = 0
	title.offset_right = 0
	add_child(title)

	var sub := _label("a forest · eight notes · one tall figure", 20, Color(0.55, 0.56, 0.56))
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

	var start := _button("BEGIN")
	start.pressed.connect(_start_game)
	_menu.add_child(start)
	_menu_first_focus = start

	var how := _button("HOW TO PLAY")
	how.pressed.connect(func():
		_menu.visible = false
		_info.visible = true
		pass)
	_menu.add_child(how)

	var settings := _button("SETTINGS")
	settings.pressed.connect(func():
		_menu.visible = false
		_settings.visible = true
		pass)
	_menu.add_child(settings)

	var quit := _button("QUIT")
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

	var credit := _label("a tribute to Slender: The Eight Pages", 13, Color(0.36, 0.36, 0.36))
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


var _menu_first_focus: Control


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
	var head := _plain("HOW TO PLAY", 32, Color(0.9, 0.89, 0.86))
	head.add_theme_font_override("font", _serif)
	(_info as VBoxContainer).add_child(head)
	var body := _plain(
		"You are alone in a dark forest. Eight pages are pinned to landmarks: " +
		"a stone labyrinth, a tunnel, a silo, a truck, a shed, a ring of stones, " +
		"a ruined bathroom and a watchtower.\n\n" +
		"Collect all eight, then get out.\n\n" +
		"He appears at the edge of the trees. Looking at him slows him down — " +
		"but if you stare too long he will know, and he will run.\n\n" +
		"Static is his voice. When it rises, look away — or run.",
		18)
	(_info as VBoxContainer).add_child(body)
	var keys := _plain(
		"KEYBOARD:  WASD move · SHIFT sprint · F flashlight · E take page · ESC pause\n" +
		"TOUCH:  left side = virtual stick · right side = look · RUN to sprint · TAKE to pick up",
		15, Color(0.55, 0.55, 0.55))
	(_info as VBoxContainer).add_child(keys)
	var back := _button("BACK", 20)
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
	var head := _plain("SETTINGS", 32, Color(0.9, 0.89, 0.86))
	head.add_theme_font_override("font", _serif)
	box.add_child(head)
	_slider_row(box, "MOUSE SENSITIVITY", 0.2, 3.0, 0.05, Settings.mouse_sensitivity, func(v: float):
		Settings.mouse_sensitivity = v
		Settings.save_settings())
	_slider_row(box, "VOLUME", 0.0, 1.0, 0.02, Settings.master_volume, func(v: float):
		Settings.master_volume = v
		Settings.apply_volume())
	_check_row(box, "INVERT LOOK Y", Settings.invert_y, func(v: bool):
		Settings.invert_y = v
		Settings.save_settings())
	_check_row(box, "FORCE TOUCH CONTROLS", Settings.force_touch, func(v: bool):
		Settings.force_touch = v
		Game.touch_mode = v
		Settings.save_settings())
	var back := _button("BACK", 20)
	back.pressed.connect(func():
		_settings.visible = false
		_menu.visible = true
		pass)
	box.add_child(back)
	_settings_first = back


func controls_text() -> String:
	if Game.touch_mode:
		return "drag left to walk · drag right to look"
	return "WASD move · SHIFT sprint · F light · E take · ESC pause"


func _best_text() -> String:
	if Settings.best_time < 0.0:
		return "no escape recorded yet"
	return "best escape: %s   ·   %d/8 pages" % [Game.format_time(Settings.best_time), Settings.best_pages]


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
