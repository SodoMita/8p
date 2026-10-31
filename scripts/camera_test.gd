extends Node
## Rig test for the handheld camera (physics joint vs procedural fallback).
##   godot --path . res://scenes/World.tscn -- --autotest=camtest
## Verifies that the camera really is carried by the RigidBody3D + 6DOF joint,
## that it lags and settles instead of snapping, that it never diverges, and
## that the procedural fallback behaves the same way. Exits 0 when all pass.

var world: Node = null
var passed := 0
var failed := 0
var player: CharacterBody3D
var handle: RigidBody3D
var camera: Camera3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await get_tree().process_frame
	await _wait(1.2)
	player = world.player
	handle = player.handle
	camera = player.camera
	await _run()
	print("[camtest] RESULT %d passed, %d failed" % [passed, failed])
	get_tree().quit(0 if failed == 0 else 1)


func check(name: String, condition: bool, detail := "") -> void:
	if condition:
		passed += 1
		print("[camtest] PASS  %s %s" % [name, detail])
	else:
		failed += 1
		print("[camtest] FAIL  %s %s" % [name, detail])


func _wait(t: float) -> void:
	await get_tree().create_timer(t, true, false, true).timeout


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## Angle between where the camera looks and where the head aims.
func aim_error() -> float:
	var a: Vector3 = -camera.global_transform.basis.z
	var b: Vector3 = -player.head.global_transform.basis.z
	return a.angle_to(b)


func cam_offset() -> float:
	return camera.global_position.distance_to(player.head.global_position)


func _finite() -> bool:
	var o := camera.global_position
	return is_finite(o.x) and is_finite(o.y) and is_finite(o.z)


## Record the aim error for `seconds` after an instantaneous yaw change.
func _turn_profile(radians: float, seconds := 1.2) -> Dictionary:
	player.rotation.y += radians
	var samples: Array[float] = []
	var steps := int(seconds * 60.0)
	for i in steps:
		await get_tree().physics_frame
		samples.append(aim_error())
	return {
		"first": samples[0] if samples.size() > 0 else 0.0,
		"max": samples.max() if samples.size() > 0 else 0.0,
		"at_0_1": samples[int(0.1 * 60.0)] if samples.size() > 6 else 0.0,
		"at_0_4": samples[int(0.4 * 60.0)] if samples.size() > 24 else 0.0,
		"final": samples[samples.size() - 1] if samples.size() > 0 else 0.0,
		"all": samples,
	}


func _run() -> void:
	# ---------------------------------------------------------------- rig shape
	check("handle_is_rigidbody", handle is RigidBody3D)
	var joint := player.get_node_or_null("CamJoint") as Generic6DOFJoint3D
	check("joint_present", joint != null)
	if joint != null:
		check("joint_has_limits",
			joint.get_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT)
			and joint.get_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_SPRING))
		# the engine's 6DOF constraint cannot follow a kinematic anchor (see
		# camera_handle.gd), so the rig reads the tether's tuning and hands the
		# same spring law to the solver; the joint must be detached from it
		check("tether_tuning_read", handle.travel > 0.05 and handle.travel < 0.2,
			"travel=%.3f" % handle.travel)
		check("joint_detached_by_design",
			joint.node_a == NodePath("") and joint.node_b == NodePath(""),
			"%s -> %s" % [joint.node_a, joint.node_b])
	check("camera_under_rig", camera.get_parent() == handle.get_node("CameraMount"),
		str(camera.get_parent()))
	check("physics_mode_on", handle.physics_mode, "quality=%d" % Game.quality)

	# ------------------------------------------------------------- idle settle
	await _wait(0.8)
	check("idle_aim_settled", aim_error() < 0.03, "%.4f rad" % aim_error())
	check("idle_offset_small", cam_offset() < 0.12, "%.3f m" % cam_offset())
	check("finite_transform", _finite())

	# --------------------------------------------------------------- turn lag
	# a real camcorder cannot snap 70 degrees: the camera must trail the head
	var p := await _turn_profile(deg_to_rad(70.0))
	check("turn_lags_at_first_frame", p["first"] > 0.25, "first=%.3f rad" % p["first"])
	check("turn_catches_up", p["at_0_4"] < 0.06, "0.4s=%.4f rad" % p["at_0_4"])
	check("turn_settles", p["final"] < 0.02, "final=%.4f rad" % p["final"])
	# no wild oscillation: the error must fall monotonically after the peak
	var overshoot := 0.0
	var prev: float = p["all"][0]
	var falling := false
	for i in range(1, p["all"].size()):
		var v: float = p["all"][i]
		if v < prev - 0.001:
			falling = true
		elif falling and v > prev + 0.02:
			overshoot = maxf(overshoot, v)
		prev = v
	check("turn_no_overshoot", overshoot < 0.05, "overshoot=%.3f rad" % overshoot)

	# a snap (teleport) is a cut, not a turn: the rig must follow immediately
	player.look_at_point(player.global_position + Vector3(12, 1.6, 0))
	await _frames(2)
	check("snap_follows_teleport", aim_error() < 0.08, "%.3f rad" % aim_error())

	# a 180 deg flip is still a cut: folding the quaternion angle would hide it
	player.rotation.y += PI
	await _frames(2)
	check("half_turn_resyncs", aim_error() < 0.08, "%.3f rad" % aim_error())

	# a stalled tick (breakpoint, compile hitch) must not teleport the rig
	player.rotation.y += deg_to_rad(40.0)
	handle._drive_physics(0.0)      # zero-length tick
	handle._drive_physics(2.5)      # two and a half seconds in one call
	await _frames(2)
	var stalled_offset := cam_offset()
	await _wait(0.8)
	# the tick is clamped, so the rig keeps trailing normally and then settles
	# instead of being flung (or dividing by zero) on the resume frame
	check("stall_is_clamped", cam_offset() < 0.5 and stalled_offset < 0.5,
		"immediate %.3f m, later %.3f m" % [stalled_offset, cam_offset()])
	check("stall_recovers", aim_error() < 0.05, "%.3f rad" % aim_error())
	handle.snap()
	await _frames(2)

	# ------------------------------------------------------------- walk shake
	player.set_touch_move(Vector2(0, -1))
	var max_offset := 0.0
	var lateral := 0.0
	for i in 90:
		await get_tree().physics_frame
		max_offset = maxf(max_offset, handle.global_position.distance_to(player.head.global_position))
		lateral += handle.global_position.distance_to(player.head.global_position)
	player.set_touch_move(Vector2.ZERO)
	check("walk_rig_moves", max_offset > 0.008, "peak %.4f m" % max_offset)
	check("walk_rig_bounded", max_offset < 0.45, "peak %.4f m" % max_offset)
	await _wait(1.2)
	check("walk_settles_after_stop", cam_offset() < 0.10, "%.3f m" % cam_offset())

	# ------------------------------------------------------------ hit reaction
	var before := aim_error()
	handle.impact(Vector3(0, 0, -1), 2.5)
	await _frames(8)
	var during := cam_offset()
	await _wait(1.4)
	var after := aim_error()
	check("impact_kicks_camera", during > 0.02,
		"offset %.3f m (aim %.3f)" % [during, before])
	check("impact_recovers", after < 0.03, "%.4f rad" % after)

	# -------------------------------------------------------- survives a chase
	# shake + sprint + impact at once must never produce NaN or a flyaway
	player.set_touch_move(Vector2(0, -1))
	player.set_touch_sprint(true)
	handle.shake = 0.05
	handle.impact(Vector3(1, 0, 1), 3.0)
	var ok := true
	var worst := 0.0
	for i in 120:
		await get_tree().physics_frame
		if not _finite():
			ok = false
			break
		worst = maxf(worst, cam_offset())
	player.set_touch_sprint(false)
	player.set_touch_move(Vector2.ZERO)
	handle.shake = 0.0
	check("stays_finite_under_stress", ok)
	check("no_flyaway", worst < 1.0, "worst offset %.3f m" % worst)

	# ------------------------------------------------------- procedural mode
	handle.set_physics_mode(false)
	check("fallback_active", not handle.physics_mode)
	await _wait(0.5)
	var q := await _turn_profile(deg_to_rad(70.0))
	check("fallback_lags", q["first"] > 0.2, "first=%.3f rad" % q["first"])
	check("fallback_settles", q["final"] < 0.02, "final=%.4f rad" % q["final"])
	check("fallback_finite", _finite())

	# and back again
	handle.set_physics_mode(true)
	await _frames(4)
	check("physics_mode_restored", handle.physics_mode and aim_error() < 0.1,
		"%.3f rad" % aim_error())

	print("[camtest] fps=%d" % Engine.get_frames_per_second())
