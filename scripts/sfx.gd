extends Node
## Tiny audio manager: looping ambience beds + a pool of one-shot players.
## All sounds are procedurally generated WAV files shipped with the project
## (see tools/gen_sfx.py — the screams are a formant voice, not noise).

const ONE_SHOTS := 12
const AUDIO_DIR := "res://assets/audio/"
## stingers that exist in several takes, so he never sounds the same twice
const VARIANTS := {
	"appear": 3,
}

var _streams := {}
var _loops := {}
var _loop_tweens := {}
var _pool: Array[AudioStreamPlayer] = []
var _pool_index := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_install_limiter()
	for file in [
		"wind_loop", "drone_loop", "static_loop", "heartbeat_loop", "breath_loop",
		"step_0", "step_1", "step_2", "step_3", "page", "appear_near", "chase",
		"jumpscare", "win", "ui_click", "branch",
		"appear_0", "appear_1", "appear_2",
	]:
		var path: String = AUDIO_DIR + file + ".wav"
		if ResourceLoader.exists(path):
			_streams[file] = load(path)
		else:
			push_warning("Missing sound: " + path)
	for i in ONE_SHOTS:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool.append(p)
	# looping beds (loop points are configured at runtime, no import tweaks needed)
	for loop_name in ["wind_loop", "drone_loop", "static_loop", "heartbeat_loop", "breath_loop"]:
		_start_loop(loop_name)


## The stingers are mastered hot on purpose; this keeps the sum of scream +
## heartbeat + static from ever clipping the output.
func _install_limiter() -> void:
	if not ClassDB.class_exists("AudioEffectLimiter"):
		return
	var idx := AudioServer.get_bus_index("Master")
	for i in AudioServer.get_bus_effect_count(idx):
		if AudioServer.get_bus_effect(idx, i) is AudioEffectLimiter:
			return
	var lim := AudioEffectLimiter.new()
	lim.ceiling_db = -0.6
	lim.threshold_db = -2.0
	lim.soft_clip_db = 2.0
	lim.soft_clip_ratio = 2.0
	AudioServer.add_bus_effect(idx, lim)


func _start_loop(name: String) -> void:
	var stream: AudioStream = _streams.get(name)
	if stream == null:
		return
	if stream is AudioStreamWAV:
		var wav: AudioStreamWAV = stream
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = int(wav.get_length() * wav.mix_rate) - 1
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = "Master"
	p.volume_db = -80.0
	add_child(p)
	p.play()
	_loops[name] = p


func play(name: String, volume_db := 0.0, pitch := 1.0) -> void:
	var stream: AudioStream = _streams.get(name)
	if stream == null:
		return
	var p := _pool[_pool_index]
	_pool_index = (_pool_index + 1) % _pool.size()
	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


## A random take of a multi-variant stinger (see VARIANTS).
func play_variant(base: String, volume_db := 0.0, pitch := 1.0) -> void:
	var count: int = VARIANTS.get(base, 1)
	if count <= 1:
		play(base, volume_db, pitch)
		return
	var idx := _rng.randi_range(0, count - 1)
	play("%s_%d" % [base, idx], volume_db, pitch)


## He steps out of the tree line.  Distant, wrong, and never the same twice.
func appear(volume_db := -12.0) -> void:
	play_variant("appear", volume_db, _rng.randf_range(0.94, 1.07))


func footstep(sprint: bool) -> void:
	var idx := _rng.randi_range(0, 3)
	play("step_%d" % idx, -10.0 if sprint else -14.0, randf_range(0.9, 1.12))


func set_loop_volume(name: String, volume_db: float) -> void:
	var p: AudioStreamPlayer = _loops.get(name)
	if p == null:
		return
	_kill_loop_tween(name)
	p.volume_db = clampf(volume_db, -80.0, 6.0)


func loop_volume(name: String) -> float:
	var p: AudioStreamPlayer = _loops.get(name)
	return p.volume_db if p != null else -80.0


func _kill_loop_tween(name: String) -> void:
	var old: Tween = _loop_tweens.get(name)
	if old != null and old.is_valid():
		old.kill()
	_loop_tweens.erase(name)


func fade_loop(name: String, target_db: float, time: float) -> void:
	var p: AudioStreamPlayer = _loops.get(name)
	if p == null:
		return
	_kill_loop_tween(name)
	var tw := create_tween()
	_loop_tweens[name] = tw
	tw.tween_property(p, "volume_db", clampf(target_db, -80.0, 6.0), time)


func duck_all(time := 1.5, db := -30.0) -> void:
	for loop_key in _loops.keys():
		fade_loop(loop_key, db, time)


func stop_all_loops() -> void:
	for p in _loops.values():
		p.stop()


func resume_ambience() -> void:
	set_loop_volume("wind_loop", -12.0)
	set_loop_volume("drone_loop", -16.0)
