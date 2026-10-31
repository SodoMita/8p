extends RigidBody3D
## CAMCORDER HANDLE — the camera is not bolted to the player's head.
##
## The render camera hangs off this rigid body, which is tethered to an
## AnimatableBody3D anchor at eye height by a Generic6DOFJoint3D (see
## scenes/Player.tscn: CamJoint, linear limits + spring). The camera therefore
## drifts, lags, swings and shudders while the player walks, sprints, turns,
## gets hit or runs into a tree — the view is a physical object being carried,
## not a matrix copied from the head every frame.
##
## The rigid body is the thing that actually moves the camera, and the joint
## node is the rig's tuning: `_ready()` reads the tether's travel and spring
## constants off the Generic6DOFJoint3D and feeds the same spring-damper law to
## the simulated body every tick as a velocity servo, with anchor-velocity
## feed-forward. Impacts arrive as real impulses (`impact()`, `footstep()`).
##
## Why the servo exists: in Godot 4.7 neither GodotPhysics3D nor Jolt moves a
## jointed body when its partner is a *kinematic* anchor — the joint's frames
## are frozen at setup, so the rig would ignore the head and also lock the
## handle's rotation. Measured with a constant-force probe (see
## tools/cam_rig_probe.md), the constraint applied no force at all while the
## anchor walked away. So the joint is detached from the solver at runtime
## (`node_a`/`node_b` are cleared after their parameters have been read) and the
## body is driven by the equivalent force law instead. Same physical model, no
## engine roulette: the handle keeps a real mass, real solver integration and
## real impulse response.
##
## Orientation is a critically damped PD controller towards the head's aim, so
## swinging the view around feels like moving a heavy handheld camera instead of
## a mouse-look. Physics runs at the fixed tick; CameraMount is interpolated
## between ticks (Engine.get_physics_interpolation_fraction), so the picture
## stays smooth at any framerate.
##
## `physics_mode = false` swaps the body for a procedural spring (low quality
## preset / accessibility toggle). Public API is identical either way.

signal reseated

const RESEAT_DISTANCE := 0.75     # the body escaped its tether: put it back
const TELEPORT_ANGLE := 1.0       # rad in a single tick — only a cut can do that
const TELEPORT_DISTANCE := 0.75   # metres in a single tick
const TRAVEL := 0.115             # metres of slack, mirrors the joint's limits
const STUCK_TIME := 0.45          # seconds of sustained aim error before resync

@export var physics_mode := true
@export var follow_damp := 8.5     # 1/s — how quickly the rig matches the head
@export var follow_spring := 5.5    # 1/s — pull back onto the tether
@export var aim_stiffness := 5.0    # P gain: aim error (rad) -> angular speed
@export var aim_response := 0.09   # D: seconds the body takes to match the P target
@export var max_aim_speed := 10.0
@export var smooth_rate := 22.0     # procedural fallback spring rate
@export var impact_gain := 1.0

var head: Node3D
var anchor: AnimatableBody3D
var joint: Generic6DOFJoint3D
var mount: Node3D

var roll_target := 0.0
var shake := 0.0        # 0..1, driven by the player (damage, jumpscares, bumps)

var _target_basis := Basis.IDENTITY
var _prev_xform := Transform3D.IDENTITY
var _cur_xform := Transform3D.IDENTITY
var _fallback_xform := Transform3D.IDENTITY
var _last_head_basis := Basis.IDENTITY
var _last_head_origin := Vector3.ZERO
var _anchor_prev := Vector3.ZERO
var _has_last := false
var _stuck := 0.0
var _settled := false
var travel := TRAVEL              # metres of slack, from the joint's limits
var tether_spring := 2.0         # 1/s, from the joint's spring stiffness


func _ready() -> void:
	top_level = true            # physics owns this transform; the head must not teleport it
	can_sleep = false
	gravity_scale = 0.0
	collision_layer = 0
	collision_mask = 0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0           # the servo below is the damping
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.0

	head = get_parent() as Node3D
	mount = get_node_or_null("CameraMount")
	anchor = get_node_or_null("../Anchor") as AnimatableBody3D
	joint = get_node_or_null("../../CamJoint") as Generic6DOFJoint3D
	if joint == null:
		joint = get_node_or_null("../CamJoint") as Generic6DOFJoint3D
	_read_tether()

	snap()
	set_physics_mode(physics_mode)


## Take the rig's travel and spring out of the joint node, then let the solver
## go: the servo below applies the same law every tick.
func _read_tether() -> void:
	if joint == null:
		return
	var upper := joint.get_param_y(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT)
	var lower := joint.get_param_y(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT)
	if upper > lower:
		travel = clampf((upper - lower) * 0.5, 0.02, 0.4)
	var stiff := joint.get_param_y(Generic6DOFJoint3D.PARAM_LINEAR_SPRING_STIFFNESS)
	if stiff > 0.0:
		tether_spring = stiff
	# the engine's own constraint cannot follow a kinematic anchor (see header)
	joint.node_a = NodePath("")
	joint.node_b = NodePath("")


## Put the body exactly on the anchor and kill all momentum.
func snap() -> void:
	var target := Transform3D.IDENTITY
	if head != null:
		target = head.global_transform
	elif anchor != null:
		target = anchor.global_transform
	_prev_xform = target
	_cur_xform = target
	_fallback_xform = target
	_anchor_prev = target.origin
	_has_last = false
	# teleport the body itself, not just the picture: the solver works from the
	# body's real transform, so a cached transform alone would leave it behind
	global_transform = target
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	if mount != null:
		mount.global_transform = target


## Switch between the simulated handle and the cheap procedural spring.
func set_physics_mode(enabled: bool) -> void:
	physics_mode = enabled
	# a frozen body is weightless: the solver stops pushing it around, which is
	# exactly what the procedural fallback wants
	freeze = not enabled
	snap()


func _physics_process(delta: float) -> void:
	if head == null:
		return
	_target_basis = head.global_transform.basis.orthonormalized()
	if roll_target != 0.0:
		_target_basis = _target_basis.rotated(_target_basis.z, roll_target)
		_target_basis = _target_basis.orthonormalized()

	if physics_mode:
		_drive_physics(delta)
	else:
		_drive_fallback(delta)


func _drive_physics(delta: float) -> void:
	var head_basis := head.global_transform.basis.orthonormalized()
	var head_origin := head.global_position

	# A teleport is a cut: the head moved further in one tick than a human can
	# move it. Detecting it from the *delta* (not from the absolute error)
	# keeps fast mouse flicks — which produce a big temporary error — intact.
	if _has_last:
		if _angle_between(head_basis, _last_head_basis) > TELEPORT_ANGLE \
				or head_origin.distance_to(_last_head_origin) > TELEPORT_DISTANCE:
			_last_head_basis = head_basis
			_last_head_origin = head_origin
			snap()
			reseated.emit()
			return
	_last_head_basis = head_basis
	_last_head_origin = head_origin

	# hard safety net: the body escaped its tether (stutter, solver blow-up)
	var err := head_origin - global_position
	if err.length() > RESEAT_DISTANCE:
		snap()
		reseated.emit()
		return

	if not _has_last:
		_anchor_prev = head_origin
		_has_last = true
	var anchor_vel := (head_origin - _anchor_prev) / maxf(delta, 0.0001)
	_anchor_prev = head_origin

	# --- linear: follow the head, then settle back onto the tether -----------
	# feed-forward on the anchor's velocity means walking produces no steady
	# lag at all; what is left is the *transient* — the camera leaning back
	# when you start moving and overshooting a step, which is the whole point
	var target_v := anchor_vel + err.limit_length(travel) * follow_spring
	linear_velocity = linear_velocity.lerp(target_v, 1.0 - exp(-follow_damp * delta))

	# --- angular: critically damped PD towards the aim -----------------------
	var cur_basis := global_transform.basis.orthonormalized()
	var q := (_target_basis * cur_basis.transposed()).get_rotation_quaternion().normalized()
	if q.w < 0.0:
		q = -q
	var angle := 2.0 * acos(clampf(q.w, -1.0, 1.0))
	if angle > STUCK_TIME * 4.0:
		# the rig has been grossly out of alignment; give up gracefully instead
		# of spinning forever (can only happen if a sync was missed)
		_stuck += delta
		if _stuck > STUCK_TIME:
			_stuck = 0.0
			snap()
			reseated.emit()
			return
	else:
		_stuck = 0.0

	var axis := Vector3(q.x, q.y, q.z)
	var desired := Vector3.ZERO
	if axis.length() > 0.000001:
		desired = axis.normalized() * angle * aim_stiffness
	if shake > 0.0005:
		desired += Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * shake * 22.0
	angular_velocity = angular_velocity.lerp(desired.limit_length(max_aim_speed),
		1.0 - exp(-delta / maxf(aim_response, 0.001)))


func _drive_fallback(delta: float) -> void:
	# no simulated body: an exponential spring on the transform itself — same
	# broad feel, a fraction of the cost
	var basis := _target_basis
	if shake > 0.0005:
		var j := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
		basis = basis.rotated(basis.x, j.x * shake * 0.05).rotated(basis.y, j.y * shake * 0.05)
	var target := Transform3D(basis, head.global_position)
	_prev_xform = _fallback_xform
	var k := 1.0 - exp(-delta * smooth_rate)
	var f := Transform3D(
		_fallback_xform.basis.orthonormalized().slerp(target.basis, k),
		_fallback_xform.origin.lerp(target.origin, k * 1.6)
	)
	f.basis = f.basis.orthonormalized()
	if f.origin.distance_to(target.origin) > RESEAT_DISTANCE:
		f = target
		_prev_xform = target
		reseated.emit()
	_fallback_xform = f
	_cur_xform = f


func _angle_between(a: Basis, b: Basis) -> float:
	var q := (a * b.transposed()).get_rotation_quaternion()
	return 2.0 * acos(clampf(absf(q.w), -1.0, 1.0))


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# the transform the physics solver actually produced this tick
	_prev_xform = _cur_xform
	_cur_xform = state.transform.orthonormalized()


func _process(_delta: float) -> void:
	if mount == null:
		return
	var a: float = clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	var xf := _prev_xform.interpolate_with(_cur_xform, a)
	if not _is_finite(xf):
		return
	mount.global_transform = xf
	_settled = true


func _is_finite(xf: Transform3D) -> bool:
	var o := xf.origin
	var b := xf.basis
	return is_finite(o.x) and is_finite(o.y) and is_finite(o.z) \
		and is_finite(b.x.x) and is_finite(b.y.y) and is_finite(b.z.z)


## Kick the rig, e.g. running into a tree. `dir` is a world-space direction.
func impact(dir: Vector3, strength := 1.0) -> void:
	if not physics_mode or freeze:
		return
	var f := dir.normalized() * clampf(strength, 0.0, 3.0) * 0.30 * impact_gain
	apply_central_impulse(f)
	apply_torque_impulse(Vector3(f.z, f.x, -f.x) * 0.05)


## A footstep: tiny downward jolt, plus a touch of roll swing.
func footstep(strength := 1.0) -> void:
	if not physics_mode or freeze:
		return
	apply_central_impulse(Vector3(0.0, -0.028, 0.0) * strength)
	apply_torque_impulse(Vector3(0.0, 0.0, randf_range(-1.0, 1.0)) * 0.004 * strength)


## Set the rig's world rotation straight from the aim (teleports, cutscenes).
func align_to_head() -> void:
	snap()


func is_settled() -> bool:
	return _settled


## How far the camera is from where the head aims, in radians.
func aim_error() -> float:
	return _angle_between(_target_basis, global_transform.basis.orthonormalized())
