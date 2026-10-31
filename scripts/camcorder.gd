extends Control
## CAMCORDER — the video-camera look, as a self-contained scene.
##
## scenes/Camcorder.tscn holds the whole finder: `Post` is a full-rect ColorRect
## running shaders/camcorder.gdshader over whatever the renderer produced, and
## `Chrome` is the viewfinder furniture (corner brackets, blinking REC dot,
## timecode, tape counter, battery, IR lamp flag). The HUD instantiates the
## scene at the bottom of its canvas stack, so the tape and the lens sit under
## the game's own typography while menus, notes and fades still cover it.
##
## The world feeds it three numbers:
##   set_dread()   danger 0..1 -> tearing, signal loss, desaturation, zoom pulse
##   set_ir()      night-vision lamp (the torch's second mode)
##   glitch()      one-shot burst for apparitions, chases and jumpscares
##
## All animation happens on the CPU with cheap lerps: the shader itself only
## receives floats. `quality` is passed through so the shader can drop the
## chromatic-aberration and IR softening taps on the low preset.

const SHADER := "res://shaders/camcorder.gdshader"
const NOISE := "res://assets/textures/noise.png"

@onready var post: ColorRect = $Post
@onready var chrome: Control = $Chrome
@onready var rec_dot: ColorRect = $Chrome/TopRight/RecRow/RecDot
@onready var tc_label: Label = $Chrome/TopRight/Timecode
@onready var battery_fill: ColorRect = $Chrome/TopRight/BatteryRow/BatteryBody/BatteryFill
@onready var battery_label: Label = $Chrome/TopRight/BatteryRow/BatteryLabel
@onready var ir_label: Label = $Chrome/TapeFlag

var mat: ShaderMaterial

var enabled := true
var dread := 0.0        # smoothed danger, 0..1
var target_dread := 0.0
var ir_target := 0.0
var ir := 0.0

var _flash := 0.0
var _burst := 0.0
var _handheld := 0.0
var _time := 0.0
var _jitter := Vector2.ZERO
var _jitter_target := Vector2.ZERO
var _jitter_timer := 0.0
var _zoom := 1.0
var _battery := 0.94
var _rec_phase := 0.0
var _timecode := 0.0
var _chrome_a := 0.0


func _ready() -> void:
	mat = post.material as ShaderMaterial
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = load(SHADER)
		post.material = mat
	mat.set_shader_parameter("noise_tex", load(NOISE))
	mat.set_shader_parameter("quality", Game.quality)
	# 1 = raw passthrough, 3 = skip grain, 4 = skip grade (A/B in the harness)
	var dbg := OS.get_environment("EIGHT_PAGES_CAM_DEBUG")
	if dbg != "":
		mat.set_shader_parameter("debug_mode", int(dbg))
	# the tube gain is calibrated for this world: the IR-lit forest lands around
	# 0.09 luma, so x2.4 puts the ground mid-tube while black stays black
	mat.set_shader_parameter("ir_gain", 2.4)
	if Game.quality <= 0:
		mat.set_shader_parameter("dirt", 0.10)
	set_enabled(Settings.camcorder)


# --------------------------------------------------------------------------- #
# public API (called by the world / hud)
# --------------------------------------------------------------------------- #
func set_enabled(on: bool) -> void:
	enabled = on
	if post != null:
		post.visible = on
	if chrome != null:
		chrome.visible = on


func set_dread(v: float) -> void:
	target_dread = clampf(v, 0.0, 1.0)


func set_ir(on: bool) -> void:
	ir_target = 0.82 if on else 0.0


func set_ir_strength(v: float) -> void:
	ir_target = clampf(v, 0.0, 1.0)


## One-shot burst: apparitions, chase start, a page picked up.
func glitch(strength := 0.6) -> void:
	_burst = maxf(_burst, clampf(strength, 0.0, 1.0))


## A hard cut / blows the frame out for a frame or two.
func punch(strength := 0.5) -> void:
	_flash = maxf(_flash, clampf(strength, 0.0, 1.0))


func set_time(seconds: float) -> void:
	_timecode = maxf(0.0, seconds)


func set_handheld(v: float) -> void:
	_handheld = clampf(v, 0.0, 1.0)


func battery() -> float:
	return _battery


# --------------------------------------------------------------------------- #
# per-frame animation
# --------------------------------------------------------------------------- #
func _process(delta: float) -> void:
	if not enabled or mat == null:
		return
	_time += delta

	# --- danger ramps in and out slowly so it never feels like a switch ------
	dread = lerpf(dread, target_dread, 1.0 - exp(-delta * 1.6))
	ir = lerpf(ir, ir_target, 1.0 - exp(-delta * 7.0))
	_burst = maxf(0.0, _burst - delta * 2.2)
	_flash = maxf(0.0, _flash - delta * 6.0)

	# --- handheld micro shake: slow wander plus a breath rhythm --------------
	_jitter_timer -= delta
	if _jitter_timer <= 0.0:
		_jitter_timer = randf_range(0.18, 0.5)
		var amp := 0.00035 + 0.0005 * _handheld + 0.0012 * dread
		_jitter_target = Vector2(randf_range(-amp, amp), randf_range(-amp, amp))
	_jitter = _jitter.lerp(_jitter_target, 1.0 - exp(-delta * 9.0))
	var breath := sin(_time * 1.9) * 0.00016 + sin(_time * 0.53) * 0.00012
	var shake := Vector2(_jitter.x + breath, _jitter.y + cos(_time * 1.4) * 0.0001)

	# --- digital zoom creep: the camera hunts while you are in danger --------
	var zoom_target := 1.0 + 0.035 * dread + 0.02 * absf(sin(_time * 0.7)) * dread
	if _burst > 0.01:
		zoom_target += _burst * 0.04
	_zoom = lerpf(_zoom, zoom_target, 1.0 - exp(-delta * 3.0))

	# --- feed the shader ----------------------------------------------------
	mat.set_shader_parameter("jitter", shake)
	mat.set_shader_parameter("zoom", _zoom)
	mat.set_shader_parameter("ca", 0.5 + 1.9 * dread + 1.6 * _burst + 0.5 * ir)
	mat.set_shader_parameter("tear", clampf(0.05 * dread + _burst * 0.9, 0.0, 1.0))
	mat.set_shader_parameter("dropout", clampf(_burst * 0.85 + maxf(0.0, dread - 0.55) * 1.1, 0.0, 1.0))
	mat.set_shader_parameter("grain", 0.34 + 0.3 * dread + 0.2 * ir + 0.3 * _burst)
	mat.set_shader_parameter("scanline", 0.30 + 0.16 * ir + 0.12 * dread)
	mat.set_shader_parameter("rolling", 0.22 + 0.3 * dread + 0.35 * ir)
	mat.set_shader_parameter("vignette", 0.72 + 0.24 * dread + 0.12 * ir)
	mat.set_shader_parameter("saturation", 0.84 - 0.36 * dread)
	mat.set_shader_parameter("gamma", 0.90 + 0.06 * dread)
	mat.set_shader_parameter("shoulder", 0.20 + 0.10 * dread)
	mat.set_shader_parameter("exposure", 1.30 + 0.10 * ir - 0.10 * dread)
	mat.set_shader_parameter("ir", ir)
	mat.set_shader_parameter("flash", _flash)
	mat.set_shader_parameter("time_scale", 1.0 + 2.0 * _burst)

	_update_chrome(delta)


func _update_chrome(delta: float) -> void:
	if chrome == null:
		return
	# the viewfinder fades in over the first second of a run; it is never drawn
	# half-transparent, because a ghostly REC dot just looks like a bug
	var want := 1.0 if Settings.camcorder else 0.0
	_chrome_a = lerpf(_chrome_a, want, 1.0 - exp(-delta * 2.2))
	chrome.modulate.a = 0.0 if (_chrome_a < 0.55 and want > 0.0) else _chrome_a

	_rec_phase += delta
	var blink := 0.55 + 0.45 * sin(_rec_phase * 5.2)
	rec_dot.color.a = 0.35 + 0.55 * blink
	_battery = maxf(0.0, _battery - delta * 0.0007)

	var total := _timecode
	var hh := int(total / 3600.0)
	var mm := int(total / 60.0) % 60
	var ss := int(total) % 60
	var ff := int(fmod(total, 1.0) * 25.0)
	tc_label.text = "%02d:%02d:%02d:%02d" % [hh, mm, ss, ff]

	battery_fill.size.x = 30.0 * _battery
	battery_label.text = "%d" % int(round(_battery * 100.0))
	if _battery < 0.2:
		battery_fill.color = Color(0.85, 0.3, 0.24, 0.9)
		battery_label.add_theme_color_override("font_color", Color(0.85, 0.34, 0.28, 0.8))
	ir_label.add_theme_color_override("font_color",
		Color(0.55, 0.95, 0.62, clampf(ir, 0.0, 0.85)))

	# tape overlay jitters with dread
	chrome.position = Vector2(
		randf_range(-1.0, 1.0) * dread * 0.8,
		randf_range(-1.0, 1.0) * dread * 0.8)
