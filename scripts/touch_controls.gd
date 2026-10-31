extends CanvasLayer
## Mobile interface: floating virtual stick (left), swipe-look (right),
## hold-to-run and flashlight / pickup buttons. Multi-touch aware.

const JOY_RADIUS := 96.0
const KNOB_RADIUS := 42.0

var player: Node = null
var hud: Node = null

var _base: Panel
var _knob: Panel
var _run_btn: Panel
var _run_label: Label
var _light_btn: Panel
var _take_btn: Panel

var _move_id := -1
var _look_id := -1
var _run_id := -1
var _look_last := Vector2.ZERO
var _base_origin := Vector2.ZERO
var _joy_vec := Vector2.ZERO
var _pickup_available := false
var _pulse := 0.0

var _vp := Vector2(1280, 720)
var _s := 1.0


func _ready() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_layout()
	get_viewport().size_changed.connect(_layout)


func _build() -> void:
	_base = _circle(JOY_RADIUS, Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.18))
	_knob = _circle(KNOB_RADIUS, Color(1, 1, 1, 0.11), Color(1, 1, 1, 0.34))
	_run_btn = _circle(60, Color(1, 1, 1, 0.06), Color(1, 1, 1, 0.22))
	_run_label = _center_label("RUN", 19, _run_btn)
	_light_btn = _circle(46, Color(1, 1, 1, 0.06), Color(1, 1, 1, 0.22))
	_center_label("LIGHT", 14, _light_btn)
	_take_btn = _circle(52, Color(1, 0.96, 0.85, 0.10), Color(1, 0.96, 0.85, 0.5))
	_center_label("TAKE", 16, _take_btn)
	_take_btn.visible = false
	for n in [_base, _knob, _run_btn, _light_btn, _take_btn]:
		add_child(n)
	_base.visible = false
	_knob.visible = false


func _circle(radius: float, fill: Color, border: Color) -> Panel:
	var p := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(int(radius))
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size = Vector2(radius * 2.0, radius * 2.0)
	return p


func _set_radius(p: Panel, radius: float) -> void:
	var sb := p.get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.set_corner_radius_all(int(radius))
	p.size = Vector2(radius * 2.0, radius * 2.0)


func _center_label(text: String, size: int, parent: Control) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _layout() -> void:
	_vp = get_viewport().get_visible_rect().size
	_s = clampf(minf(_vp.x / 1280.0, _vp.y / 720.0), 0.62, 1.7)
	_set_radius(_run_btn, 60.0 * _s)
	_set_radius(_light_btn, 46.0 * _s)
	_set_radius(_take_btn, 52.0 * _s)
	_run_label.add_theme_font_size_override("font_size", int(19 * _s))
	_run_btn.position = Vector2(_vp.x - 150.0 * _s, _vp.y - 150.0 * _s)
	_light_btn.position = Vector2(_vp.x - 128.0 * _s, _vp.y - 300.0 * _s)
	_take_btn.position = Vector2(_vp.x - 260.0 * _s, _vp.y - 215.0 * _s)
	if not _base.visible:
		_home_stick()


func _home_stick() -> void:
	_set_radius(_base, JOY_RADIUS * _s)
	_set_radius(_knob, KNOB_RADIUS * _s)
	_base.position = Vector2(30.0 * _s, _vp.y - (JOY_RADIUS * 2.0 + 46.0) * _s)
	_knob.position = _base.position + Vector2(JOY_RADIUS - KNOB_RADIUS, JOY_RADIUS - KNOB_RADIUS) * _s


func set_pickup_available(v: bool) -> void:
	_pickup_available = v
	_take_btn.visible = v


func set_player(p: Node) -> void:
	player = p


func clear_input() -> void:
	## drop any latched stick/run state (used when the pause menu opens)
	_move_id = -1
	_run_id = -1
	_joy_vec = Vector2.ZERO
	if _knob != null:
		_home_stick()
	if _base != null:
		_base.visible = false
	if _knob != null:
		_knob.visible = false
	_run_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	_apply_move()
	if player != null:
		player.touch_sprint = false


# --------------------------------------------------------------------------- #
# input
# --------------------------------------------------------------------------- #
func _rect_of(node: Control) -> Rect2:
	return Rect2(node.position, node.size)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_touch_down(event.index, event.position)
		else:
			_on_touch_up(event.index)
	elif event is InputEventScreenDrag:
		_on_drag(event.index, event.position, event.relative)


func _on_touch_down(id: int, pos: Vector2) -> void:
	if _rect_of(_run_btn).has_point(pos):
		_run_id = id
		_run_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
		if player != null:
			player.set_touch_sprint(true)
		return
	if _rect_of(_light_btn).has_point(pos):
		if player != null:
			player.toggle_flashlight()
		return
	if _take_btn.visible and _rect_of(_take_btn).has_point(pos):
		if player != null:
			player.interact()
		return
	# top-right corner belongs to the HUD pause button
	if pos.x > _vp.x - 120.0 * _s and pos.y < 110.0 * _s:
		return

	# virtual stick: appears wherever the thumb lands in the left/bottom area
	if pos.x < _vp.x * 0.45 and pos.y > _vp.y * 0.30 and _move_id < 0:
		_move_id = id
		_base_origin = pos
		_set_radius(_base, JOY_RADIUS * _s)
		_set_radius(_knob, KNOB_RADIUS * _s)
		_base.position = pos - Vector2(JOY_RADIUS, JOY_RADIUS) * _s
		_knob.position = pos - Vector2(KNOB_RADIUS, KNOB_RADIUS) * _s
		_base.visible = true
		_knob.visible = true
		_joy_vec = Vector2.ZERO
		_apply_move()
		return
	if _look_id < 0:
		_look_id = id
		_look_last = pos


func _on_touch_up(id: int) -> void:
	if id == _move_id:
		_move_id = -1
		_joy_vec = Vector2.ZERO
		_base.visible = false
		_knob.visible = false
		if player != null:
			player.set_touch_move(Vector2.ZERO)
		_home_stick()
	elif id == _look_id:
		_look_id = -1
	elif id == _run_id:
		_run_id = -1
		_run_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
		if player != null:
			player.set_touch_sprint(false)


func _on_drag(id: int, pos: Vector2, relative: Vector2) -> void:
	if id == _move_id:
		var offset := (pos - _base_origin) / _s
		var length := offset.length()
		var max_len := JOY_RADIUS * 0.8
		if length > max_len:
			offset = offset / length * max_len
		_joy_vec = Vector2(offset.x / max_len, offset.y / max_len)
		_knob.position = _base_origin + offset * _s - Vector2(KNOB_RADIUS, KNOB_RADIUS) * _s
		_apply_move()
	elif id == _look_id:
		if player != null:
			var sens := 1.45 * clampf(_vp.x / 1280.0, 0.65, 1.9) * Settings.mouse_sensitivity
			player.add_look(relative * sens)
		_look_last = pos


func _apply_move() -> void:
	if player != null:
		player.set_touch_move(Vector2(_joy_vec.x, _joy_vec.y))


func _process(delta: float) -> void:
	_pulse += delta
	if _take_btn.visible:
		_take_btn.modulate.a = 0.75 + 0.25 * sin(_pulse * 5.0)
