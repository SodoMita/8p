extends CanvasLayer
## All 2D UI: page counter, stamina, static overlay, notes, pause menu, end screens.

signal resume_pressed
signal pause_toggled
signal restart_pressed
signal menu_pressed
signal touch_toggle_pressed
signal camcorder_toggled
signal handheld_toggled

var root: Control
var static_rect: ColorRect
var static_mat: ShaderMaterial
var vignette_mat: ShaderMaterial
var crosshair: Control
var pages_label: Label
var pages_pips: HBoxContainer
var stamina_bg: ColorRect
var stamina_fill: ColorRect
var stamina_root: Control
var prompt: Label
var _tweens := {}
var toast: Label
var objective: Label
var note_root: Control
var note_body: Label
var flash_rect: ColorRect
var pause_root: Control
var end_root: Control
var end_title: Label
var end_sub: Label
var end_stats: Label
var end_retry: Button
var pause_button: Button
var fade_rect: ColorRect
var touch_hint: Label
var rotate_hint: Label
var camcorder: Node

var _serif: Font
var _sans: Font
var _static_energy := 0.0
var _target_static := 0.0
var _time := 0.0
var _end_visible := false
var _pips: Array[ColorRect] = []


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_serif = load("res://assets/fonts/DejaVuSerif-Bold.ttf")
	_sans = load("res://assets/fonts/DejaVuSans.ttf")
	_build()
	hide_pause()
	hide_end()


# --------------------------------------------------------------------------- #
# construction helpers
# --------------------------------------------------------------------------- #
func _label(text: String, size: int, color := Color(0.86, 0.86, 0.84), font: Font = null) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font if font != null else _sans)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _shader_rect(path: String) -> ColorRect:
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load(path)
	rect.material = mat
	return rect


func _button(text: String, size := 22) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(260, 56)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", _sans)
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", Color(0.9, 0.9, 0.88))
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(0.7, 0.7, 0.7))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.08, 0.08, 0.09, 0.85)
	normal.border_color = Color(0.32, 0.32, 0.34)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(2)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.16, 0.16, 0.17, 0.95)
	hover.border_color = Color(0.6, 0.6, 0.62)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.03, 0.03, 0.03, 0.95)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", hover)
	return b


func _build() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# --- camcorder: the lens, the tape, the viewfinder ---------------------
	# first child on purpose: the shader pass has to resample the 3D image
	# before any other overlay is composited, and the slop of the VHS tape is
	# allowed to run underneath the crisp HUD text
	var cam_scene: PackedScene = load("res://scenes/Camcorder.tscn")
	camcorder = cam_scene.instantiate()
	root.add_child(camcorder)

	# --- vignette --------------------------------------------------------
	var vig := _shader_rect("res://shaders/vignette.gdshader")
	vignette_mat = vig.material as ShaderMaterial
	# Full strength everywhere. The camcorder pass brings its own lens falloff, so
	# its first version halved this one to 0.35 to avoid stacking two -- that was
	# an effect the player had before, so it is back (#28 /re 21: the vignette and
	# the static overlay are the look, they stay on top of the tape).
	vignette_mat.set_shader_parameter("strength", 0.92)
	root.add_child(vig)

	# --- static / grain overlay -----------------------------------------
	static_rect = _shader_rect("res://shaders/static.gdshader")
	static_mat = static_rect.material as ShaderMaterial
	static_mat.set_shader_parameter("noise_tex", load("res://assets/textures/noise.png"))
	static_mat.set_shader_parameter("intensity", 0.03)
	root.add_child(static_rect)

	# --- white flash ------------------------------------------------------
	flash_rect = ColorRect.new()
	flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_rect.color = Color(1, 1, 1, 0)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(flash_rect)

	# --- fade to black ----------------------------------------------------
	fade_rect = ColorRect.new()
	fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade_rect.color = Color(0, 0, 0, 0)
	fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fade_rect)

	# --- crosshair --------------------------------------------------------
	crosshair = Control.new()
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot := ColorRect.new()
	dot.color = Color(0.85, 0.85, 0.82, 0.55)
	dot.size = Vector2(4, 4)
	dot.position = Vector2(-2, -2)
	crosshair.add_child(dot)
	root.add_child(crosshair)

	# --- page counter -----------------------------------------------------
	var pages_box := VBoxContainer.new()
	pages_box.position = Vector2(30, 24)
	pages_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cap := _label("PAGES", 15, Color(0.62, 0.62, 0.6, 0.9))
	cap.add_theme_constant_override("letter_spacing", 6)
	pages_box.add_child(cap)
	pages_label = _label("0 / 8", 40, Color(0.93, 0.91, 0.86), _serif)
	pages_box.add_child(pages_label)
	pages_pips = HBoxContainer.new()
	pages_pips.add_theme_constant_override("separation", 5)
	pages_pips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in Game.TOTAL_PAGES:
		var pip := ColorRect.new()
		pip.custom_minimum_size = Vector2(15, 5)
		pip.color = Color(0.3, 0.3, 0.3, 0.7)
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pages_pips.add_child(pip)
		_pips.append(pip)
	pages_box.add_child(pages_pips)
	root.add_child(pages_box)

	# --- objective --------------------------------------------------------
	objective = _label("FIND THE EIGHT PAGES", 16, Color(0.68, 0.68, 0.64, 0.9))
	objective.set_anchors_preset(Control.PRESET_CENTER_TOP)
	objective.position = Vector2(0, 26)
	objective.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	objective.anchor_left = 0.5
	objective.anchor_right = 0.5
	objective.offset_left = -220
	objective.offset_right = 220
	root.add_child(objective)

	# --- toast ------------------------------------------------------------
	toast = _label("", 20, Color(0.85, 0.82, 0.75))
	toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast.anchor_left = 0.5
	toast.anchor_right = 0.5
	toast.offset_left = -320
	toast.offset_right = 320
	toast.offset_top = 88
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.modulate.a = 0.0
	root.add_child(toast)

	# --- stamina ----------------------------------------------------------
	stamina_root = Control.new()
	stamina_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stamina_root.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	stamina_root.offset_left = 30
	stamina_root.offset_top = -64
	stamina_root.offset_right = 290
	stamina_root.offset_bottom = -44
	stamina_bg = ColorRect.new()
	stamina_bg.color = Color(0.0, 0.0, 0.0, 0.45)
	stamina_bg.size = Vector2(230, 9)
	stamina_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var border := ReferenceRect.new()
	border.set_anchors_preset(Control.PRESET_FULL_RECT)
	border.border_color = Color(0.55, 0.55, 0.55, 0.35)
	border.editor_only = false
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stamina_bg.add_child(border)
	stamina_root.add_child(stamina_bg)
	stamina_fill = ColorRect.new()
	stamina_fill.color = Color(0.78, 0.76, 0.7, 0.8)
	stamina_fill.size = Vector2(230, 9)
	stamina_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stamina_root.add_child(stamina_fill)
	var stam_cap := _label("BREATH", 12, Color(0.55, 0.55, 0.52))
	stam_cap.position = Vector2(0, -20)
	stamina_root.add_child(stam_cap)
	root.add_child(stamina_root)

	# --- interaction prompt ----------------------------------------------
	prompt = _label("", 20, Color(0.9, 0.88, 0.8))
	prompt.set_anchors_preset(Control.PRESET_CENTER)
	prompt.anchor_left = 0.5
	prompt.anchor_right = 0.5
	prompt.offset_left = -260
	prompt.offset_right = 260
	prompt.offset_top = 42
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.modulate.a = 0.0
	root.add_child(prompt)

	# --- rotate hint (portrait phones) ------------------------------------
	rotate_hint = _label("ROTATE YOUR DEVICE  ·  BEST IN LANDSCAPE", 15, Color(0.85, 0.83, 0.78, 0.85))
	rotate_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	rotate_hint.anchor_left = 0.5
	rotate_hint.anchor_right = 0.5
	rotate_hint.offset_left = -260
	rotate_hint.offset_right = 260
	rotate_hint.offset_top = -78
	rotate_hint.offset_bottom = -50
	rotate_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rotate_hint.visible = false
	root.add_child(rotate_hint)

	# --- mobile hint -------------------------------------------------------
	touch_hint = _label("LEFT STICK — MOVE     RIGHT SIDE — LOOK     HOLD RUN TO SPRINT", 13, Color(0.6, 0.6, 0.58, 0.8))
	touch_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	touch_hint.anchor_left = 0.5
	touch_hint.anchor_right = 0.5
	touch_hint.offset_left = -400
	touch_hint.offset_right = 400
	touch_hint.offset_top = -46
	touch_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	touch_hint.visible = false
	root.add_child(touch_hint)

	# --- note popup -------------------------------------------------------
	note_root = Control.new()
	note_root.set_anchors_preset(Control.PRESET_CENTER)
	note_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	note_root.modulate.a = 0.0
	var note_bg := TextureRect.new()
	note_bg.texture = load("res://assets/textures/note.png")
	note_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	note_bg.stretch_mode = TextureRect.STRETCH_SCALE
	note_bg.size = Vector2(430, 540)
	note_bg.position = Vector2(-215, -300)
	note_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	note_root.add_child(note_bg)
	note_body = _label("", 22, Color(0.16, 0.13, 0.11))
	note_body.add_theme_font_override("font", _serif)
	note_body.position = Vector2(-160, -215)
	note_body.size = Vector2(320, 430)
	note_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note_body.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	note_root.add_child(note_body)
	root.add_child(note_root)

	# --- pause button (touch) --------------------------------------------
	pause_button = _button("II", 20)
	pause_button.custom_minimum_size = Vector2(64, 64)
	pause_button.anchor_left = 1.0
	pause_button.anchor_right = 1.0
	pause_button.offset_left = -84
	pause_button.offset_top = 24
	pause_button.offset_right = -20
	pause_button.offset_bottom = 88
	pause_button.visible = false
	pause_button.pressed.connect(func(): pause_toggled.emit())
	root.add_child(pause_button)

	_build_pause()
	_build_end()


func _build_pause() -> void:
	pause_root = Control.new()
	pause_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_root.visible = false
	root.add_child(pause_root)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	pause_root.add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 0.5
	box.anchor_bottom = 0.5
	box.offset_left = -160
	box.offset_right = 160
	box.offset_top = -150
	box.offset_bottom = 150
	box.add_theme_constant_override("separation", 14)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	pause_root.add_child(box)

	var title := _label("PAUSED", 44, Color(0.9, 0.89, 0.85), _serif)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var resume := _button("RESUME")
	resume.pressed.connect(func(): resume_pressed.emit())
	box.add_child(resume)

	var restart := _button("RESTART RUN")
	restart.pressed.connect(func(): restart_pressed.emit())
	box.add_child(restart)

	var touch_btn := _button("TOUCH CONTROLS: AUTO", 18)
	touch_btn.pressed.connect(func(): touch_toggle_pressed.emit())
	box.add_child(touch_btn)
	touch_btn.set_meta("role", "touch_toggle")

	var cam_btn := _button("CAMCORDER FX: ON", 18)
	cam_btn.pressed.connect(func(): camcorder_toggled.emit())
	box.add_child(cam_btn)
	cam_btn.set_meta("role", "camcorder_toggle")

	var rig_btn := _button("HANDHELD CAMERA: ON", 18)
	rig_btn.pressed.connect(func(): handheld_toggled.emit())
	box.add_child(rig_btn)
	rig_btn.set_meta("role", "handheld_toggle")

	var menu := _button("QUIT TO TITLE")
	menu.pressed.connect(func(): menu_pressed.emit())
	box.add_child(menu)


func _build_end() -> void:
	end_root = Control.new()
	end_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	end_root.visible = false
	root.add_child(end_root)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.9)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	end_root.add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 0.5
	box.anchor_bottom = 0.5
	box.offset_left = -330
	box.offset_right = 330
	box.offset_top = -220
	box.offset_bottom = 220
	box.add_theme_constant_override("separation", 16)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	end_root.add_child(box)

	end_title = _label("", 52, Color(0.85, 0.83, 0.8), _serif)
	end_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(end_title)

	end_sub = _label("", 20, Color(0.6, 0.6, 0.58))
	end_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(end_sub)

	end_stats = _label("", 22, Color(0.75, 0.73, 0.7))
	end_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(end_stats)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 16)
	box.add_child(spacer)

	end_retry = _button("TRY AGAIN")
	end_retry.pressed.connect(func(): restart_pressed.emit())
	box.add_child(end_retry)

	var to_menu := _button("TITLE SCREEN")
	to_menu.pressed.connect(func(): menu_pressed.emit())
	box.add_child(to_menu)


# --------------------------------------------------------------------------- #
# runtime API
# --------------------------------------------------------------------------- #
func _unhandled_input(event: InputEvent) -> void:
	# a note never traps you: any button dismisses it instantly
	if note_root.modulate.a > 0.05:
		if event.is_action_pressed("interact") or event.is_action_pressed("sprint") or event.is_action_pressed("pause") or event.is_action_pressed("flashlight"):
			note_root.modulate.a = 0.0
			# the key that closes the note is spent: it must not also toggle the
			# torch, grab a page or open the pause menu on the same press
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("pause"):
		if end_root.visible:
			return
		pause_toggled.emit()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_time += delta
	if rotate_hint != null:
		var portrait := Game.is_portrait()
		rotate_hint.visible = Game.touch_mode and portrait and not _end_visible and not pause_root.visible
		# in portrait there is no room for the long control legend
		touch_hint.visible = Game.touch_mode and not portrait
	_static_energy = lerpf(_static_energy, _target_static, delta * 3.0)
	if static_mat != null:
		static_mat.set_shader_parameter("intensity", clampf(_static_energy, 0.0, 1.0))
	# subtle breathing crosshair opacity
	if crosshair != null:
		crosshair.modulate.a = 0.7 + 0.3 * sin(_time * 1.7)
	if camcorder != null:
		camcorder.set_time(Game.run_time)



func set_pages(n: int, total: int) -> void:
	pages_label.text = "%d / %d" % [n, total]
	for i in _pips.size():
		_pips[i].color = Color(0.88, 0.84, 0.72, 0.9) if i < n else Color(0.26, 0.26, 0.26, 0.7)


func set_stamina(v: float) -> void:
	var ratio := clampf(v / 100.0, 0.0, 1.0)
	stamina_fill.size.x = 230.0 * ratio
	stamina_fill.color = Color(0.78, 0.76, 0.7, 0.85) if ratio > 0.25 else Color(0.72, 0.32, 0.28, 0.9)
	stamina_root.modulate.a = 1.0 if ratio < 0.999 else 0.35


func set_static(v: float) -> void:
	_target_static = clampf(v, 0.0, 1.0)
	# The grain overlay composites OVER the camcorder pass (it is added after it in
	# _build()), so the two noise layers add up: this is the pre-camcorder look,
	# restored on request. Hiding it again is the A/B path back.
	if static_rect != null:
		static_rect.visible = true


## Danger level 0..1 for the camcorder pass (proximity, chase, being watched).
func set_dread(v: float) -> void:
	if camcorder != null:
		camcorder.set_dread(v)


## Night-vision lamp on/off — the camcorder's own light when the torch dies.
func set_camcorder_ir(on: bool) -> void:
	if camcorder != null:
		camcorder.set_ir(on)


## One-shot tape corruption.
func camcorder_glitch(strength := 0.6) -> void:
	if camcorder != null:
		camcorder.glitch(strength)


## One-shot blown-out frame (jumpscare, hard cut).
func camcorder_punch(strength := 0.5) -> void:
	if camcorder != null:
		camcorder.punch(strength)


func refresh_camcorder() -> void:
	if camcorder != null:
		camcorder.set_enabled(Settings.camcorder)
	if vignette_mat != null:
		vignette_mat.set_shader_parameter("strength", 0.92)
	if static_rect != null:
		static_rect.visible = true


func flash(amount: float, duration := 0.35) -> void:
	flash_rect.color = Color(1, 0.97, 0.92, amount)
	_kill_tween("flash")
	var tw := create_tween()
	_tweens["flash"] = tw
	tw.tween_property(flash_rect, "color:a", 0.0, duration)


func static_burst(amount := 0.75) -> void:
	if static_mat == null:
		return
	static_mat.set_shader_parameter("burst", amount)
	_kill_tween("static")
	var tw := create_tween()
	_tweens["static"] = tw
	tw.tween_method(func(v: float): static_mat.set_shader_parameter("burst", v), amount, 0.0, 0.9)
	# the tape damages itself in the same breath as the static spikes
	camcorder_glitch(amount * 0.45)


func show_prompt(text: String) -> void:
	if prompt.text != text:
		prompt.text = text
	var target := 1.0 if text != "" else 0.0
	prompt.modulate.a = lerpf(prompt.modulate.a, target, 0.25)


func _kill_tween(key: String) -> void:
	var old: Tween = _tweens.get(key)
	if old != null and old.is_valid():
		old.kill()


func show_toast(text: String, duration := 3.0) -> void:
	toast.text = text
	_kill_tween("toast")
	var tw := create_tween()
	_tweens["toast"] = tw
	tw.tween_property(toast, "modulate:a", 1.0, 0.4)
	tw.tween_interval(duration)
	tw.tween_property(toast, "modulate:a", 0.0, 1.0)


func set_objective(text: String) -> void:
	objective.text = text


func show_note(text: String, duration := 3.6) -> void:
	note_body.text = text
	_kill_tween("note")
	var tw := create_tween()
	_tweens["note"] = tw
	tw.tween_property(note_root, "modulate:a", 1.0, 0.35)
	tw.tween_interval(duration)
	tw.tween_property(note_root, "modulate:a", 0.0, 0.6)


func set_touch_ui(enabled: bool) -> void:
	pause_button.visible = enabled
	touch_hint.visible = enabled
	if enabled:
		stamina_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
		stamina_root.offset_left = 32
		stamina_root.offset_right = 262
		stamina_root.offset_top = 132
		stamina_root.offset_bottom = 152
	else:
		stamina_root.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		stamina_root.offset_left = 30
		stamina_root.offset_top = -64
		stamina_root.offset_right = 290
		stamina_root.offset_bottom = -44


func show_pause() -> void:
	pause_root.visible = true
	pause_root.modulate.a = 0.0
	create_tween().tween_property(pause_root, "modulate:a", 1.0, 0.2)


func hide_pause() -> void:
	pause_root.visible = false


func update_touch_toggle_label(enabled: bool) -> void:
	for c in pause_root.find_children("*", "Button", true, false):
		if c.has_meta("role") and c.get_meta("role") == "touch_toggle":
			c.text = "TOUCH CONTROLS: " + ("ON" if enabled else "OFF")
		elif c.has_meta("role") and c.get_meta("role") == "camcorder_toggle":
			c.text = "CAMCORDER FX: " + ("ON" if Settings.camcorder else "OFF")
		elif c.has_meta("role") and c.get_meta("role") == "handheld_toggle":
			c.text = "HANDHELD CAMERA: " + ("ON" if Settings.camcorder_physics else "OFF")


func show_end(won: bool, pages: int, time_taken: float) -> void:
	_end_visible = true
	end_root.visible = true
	end_root.modulate.a = 0.0
	create_tween().tween_property(end_root, "modulate:a", 1.0, 0.8)
	if won:
		end_title.text = "THE PAGES ARE YOURS"
		end_title.add_theme_color_override("font_color", Color(0.85, 0.82, 0.76))
		end_sub.text = "Eight pages. The forest lets you go.\nFor now."
	else:
		end_title.text = "HE FOUND YOU"
		end_title.add_theme_color_override("font_color", Color(0.75, 0.16, 0.14))
		end_sub.text = "You cannot outrun him. You can only refuse to look."
	var best := Settings.best_time
	var best_line := ""
	if best >= 0.0:
		best_line = "\nBEST: " + Game.format_time(best)
	end_stats.text = "PAGES  %d / 8        TIME  %s%s" % [pages, Game.format_time(time_taken), best_line]

	crosshair.visible = false
	static_rect.visible = won
	if won:
		set_static(0.0)


func hide_end() -> void:
	_end_visible = false
	end_root.visible = false
	static_rect.visible = true


func fade_to_black(duration := 2.0) -> Tween:
	var tw := create_tween()
	tw.tween_property(fade_rect, "color:a", 1.0, duration)
	return tw


func set_black(a: float) -> void:
	fade_rect.color.a = a


func end_visible() -> bool:
	return _end_visible
