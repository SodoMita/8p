extends Node
## Tiny audio manager: looping ambience beds + a pool of one-shot players +
## bus-level stone reverb & wind occlusion driven by spatial ReverbZones.
## All sounds are procedurally generated Ogg Vorbis files shipped with the project
## (see tools/gen_sfx.py — the screams are a formant voice, not noise).

const ONE_SHOTS := 12
const AUDIO_DIR := "res://assets/audio/"
const WORLD_BUS := "World"
const EXTERIOR_BUS := "Exterior"
const SPATIAL_REVERB_BUS := "LabyrinthReverb"

## stingers that exist in several takes, so he never sounds the same twice
const VARIANTS := {
	"appear": 3,
}

var reverb_amount := 0.0

var _streams := {}
var _loops := {}
var _loop_tweens := {}
var _pool: Array[AudioStreamPlayer] = []
var _ui_player: AudioStreamPlayer = null
var _pool_index := 0
var _rng := RandomNumberGenerator.new()
var _reverb: AudioEffectReverb = null
var _wind_lpf: AudioEffectLowPassFilter = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_setup_buses()
	for file in [
		"wind_loop", "drone_loop", "static_loop", "heartbeat_loop", "breath_loop",
		"wire_hum_loop",
		"step_0", "step_1", "step_2", "step_3",
		"stone_step_0", "stone_step_1", "stone_step_2", "stone_step_3",
		"page", "appear_near", "chase",
		"jumpscare", "win", "ui_click", "branch",
		"appear_0", "appear_1", "appear_2",
	]:
		var path: String = AUDIO_DIR + file + ".ogg"
		if ResourceLoader.exists(path):
			_streams[file] = load(path)
		else:
			push_warning("Missing sound: " + path)
	if _streams.get("wire_hum_loop") is AudioStreamOggVorbis:
		(_streams["wire_hum_loop"] as AudioStreamOggVorbis).loop = true
	for i in ONE_SHOTS:
		var p := AudioStreamPlayer.new()
		p.bus = WORLD_BUS
		add_child(p)
		_pool.append(p)
	_ui_player = AudioStreamPlayer.new()
	_ui_player.bus = "Master"
	add_child(_ui_player)

	# looping beds (loop points are configured at runtime, no import tweaks needed)
	_start_loop("wind_loop", EXTERIOR_BUS)
	_start_loop("drone_loop", "Master")
	_start_loop("static_loop", "Master")
	_start_loop("heartbeat_loop", "Master")
	_start_loop("breath_loop", WORLD_BUS)
	set_reverb(0.0)


func _ensure_bus(bus_name: String, send_to := "Master") -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, send_to)
	return idx


## Master limiter + World stone reverb + Exterior wind low-pass + 3D Area reverb bus.
func _setup_buses() -> void:
	var master_idx := AudioServer.get_bus_index("Master")
	if ClassDB.class_exists("AudioEffectLimiter"):
		var has_lim := false
		for i in AudioServer.get_bus_effect_count(master_idx):
			if AudioServer.get_bus_effect(master_idx, i) is AudioEffectLimiter:
				has_lim = true
				break
		if not has_lim:
			var lim := AudioEffectLimiter.new()
			lim.ceiling_db = -0.6
			lim.threshold_db = -2.0
			lim.soft_clip_db = 2.0
			lim.soft_clip_ratio = 2.0
			AudioServer.add_bus_effect(master_idx, lim)

	var world_idx := _ensure_bus(WORLD_BUS, "Master")
	if ClassDB.class_exists("AudioEffectReverb"):
		for i in AudioServer.get_bus_effect_count(world_idx):
			var fx := AudioServer.get_bus_effect(world_idx, i)
			if fx is AudioEffectReverb:
				_reverb = fx
				break
		if _reverb == null:
			_reverb = AudioEffectReverb.new()
			_reverb.room_size = 0.72
			_reverb.damping = 0.25
			_reverb.spread = 0.95
			_reverb.hipass = 0.14
			_reverb.predelay_msec = 34.0
			_reverb.predelay_feedback = 0.46
			_reverb.dry = 1.0
			_reverb.wet = 0.0
			AudioServer.add_bus_effect(world_idx, _reverb)

	var ext_idx := _ensure_bus(EXTERIOR_BUS, "Master")
	if ClassDB.class_exists("AudioEffectLowPassFilter"):
		for i in AudioServer.get_bus_effect_count(ext_idx):
			var fx := AudioServer.get_bus_effect(ext_idx, i)
			if fx is AudioEffectLowPassFilter:
				_wind_lpf = fx
				break
		if _wind_lpf == null:
			_wind_lpf = AudioEffectLowPassFilter.new()
			_wind_lpf.cutoff_hz = 20000.0
			_wind_lpf.resonance = 0.45
			AudioServer.add_bus_effect(ext_idx, _wind_lpf)

	# Dedicated spatial reverb bus referenced by Area3D.reverb_bus_name so any
	# AudioStreamPlayer3D inside the labyrinth gets matching stone acoustics too.
	var spatial_idx := _ensure_bus(SPATIAL_REVERB_BUS, "Master")
	if ClassDB.class_exists("AudioEffectReverb") and AudioServer.get_bus_effect_count(spatial_idx) == 0:
		var srev := AudioEffectReverb.new()
		srev.room_size = 0.86
		srev.damping = 0.25
		srev.spread = 0.95
		srev.hipass = 0.14
		srev.predelay_msec = 34.0
		srev.predelay_feedback = 0.46
		srev.dry = 0.85
		srev.wet = 0.58
		AudioServer.add_bus_effect(spatial_idx, srev)


## Blend stone-corridor acoustics (0 = open forest, 1 = deep inside labyrinth).
func set_reverb(amount: float) -> void:
	reverb_amount = clampf(amount, 0.0, 1.0)
	if _reverb != null:
		_reverb.wet = 0.56 * reverb_amount
		_reverb.dry = lerpf(1.0, 0.84, reverb_amount)
		_reverb.room_size = lerpf(0.72, 0.88, reverb_amount)
	if _wind_lpf != null:
		_wind_lpf.cutoff_hz = 20000.0 * pow(780.0 / 20000.0, reverb_amount)
	var ext_idx := AudioServer.get_bus_index(EXTERIOR_BUS)
	if ext_idx >= 0:
		AudioServer.set_bus_volume_db(ext_idx, -4.5 * reverb_amount)


func refresh_reverb_zones() -> void:
	var best := 0.0
	if is_inside_tree():
		for z in get_tree().get_nodes_in_group("reverb_zone"):
			if is_instance_valid(z) and not z.is_queued_for_deletion():
				best = maxf(best, float(z.get("current_amount")))
	set_reverb(best)


func in_reverb_zone() -> bool:
	return reverb_amount > 0.05


func reverb_wet() -> float:
	return _reverb.wet if _reverb != null else 0.0


func wind_cutoff_hz() -> float:
	return _wind_lpf.cutoff_hz if _wind_lpf != null else 20000.0


func stream(name: String) -> AudioStream:
	return _streams.get(name)


func _start_loop(name: String, bus_name := "Master") -> void:
	var s: AudioStream = _streams.get(name)
	if s == null:
		return
	if s is AudioStreamOggVorbis:
		var ogg: AudioStreamOggVorbis = s
		ogg.loop = true
	elif s is AudioStreamWAV:
		var wav: AudioStreamWAV = s
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = int(wav.get_length() * wav.mix_rate) - 1
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.bus = bus_name
	p.volume_db = -80.0
	add_child(p)
	p.play()
	_loops[name] = p


func play(name: String, volume_db := 0.0, pitch := 1.0) -> void:
	var s: AudioStream = _streams.get(name)
	if s == null:
		return
	if name == "ui_click" and _ui_player != null:
		_ui_player.stream = s
		_ui_player.volume_db = volume_db
		_ui_player.pitch_scale = pitch
		_ui_player.play()
		return
	var p := _pool[_pool_index]
	_pool_index = (_pool_index + 1) % _pool.size()
	p.stream = s
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
	if reverb_amount > 0.35 and _streams.has("stone_step_%d" % idx):
		var base_db := -9.0 if sprint else -13.0
		play("stone_step_%d" % idx, base_db, randf_range(0.94, 1.12))
	else:
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
	set_reverb(0.0)


func resume_ambience() -> void:
	set_reverb(0.0)
	set_loop_volume("wind_loop", -12.0)
	set_loop_volume("drone_loop", -16.0)
