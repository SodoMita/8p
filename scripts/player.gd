extends CharacterBody3D
## First person controller: WASD + mouse on desktop, virtual stick + swipe on touch.
##
## The render camera does not sit directly on the head any more: it hangs off the
## "Handle" rigid body (see camera_handle.gd), which is tethered to the head with
## a Generic6DOFJoint3D. Aiming therefore drives the *head*, and the rig swings
## after it like a camcorder held in two hands.

const WALK_SPEED := 3.15
const SPRINT_SPEED := 6.1
const ACCEL := 11.0
const GRAVITY := 18.0
const MOUSE_SENS := 0.0021
const STAMINA_MAX := 100.0
const STAMINA_DRAIN := 17.0
const STAMINA_REGEN := 13.0
const BUMP_SPEED := 2.6      # m/s of horizontal speed that registers as a knock

# the camcorder's night-vision lamp: the same cone as the torch, but dimmer and
# pushed towards the near IR, which is why the world goes almost monochrome
const IR_ENERGY := 13.0
const IR_RANGE := 26.0
const IR_ANGLE := 36.0

@onready var head: Node3D = $Head
@onready var handle: RigidBody3D = $Head/Handle
@onready var camera: Camera3D = $Head/Handle/CameraMount/Camera
@onready var flashlight: SpotLight3D = $Head/Handle/CameraMount/Camera/Flashlight
@onready var fill_light: OmniLight3D = $Head/Fill

var pitch := 0.0
var stamina := STAMINA_MAX
var sprinting := false
var frozen := false
var flashlight_on := true
var ir_lamp := false
var flicker := 0.0
var shake_amount := 0.0

var touch_move := Vector2.ZERO
var touch_sprint := false

var _bob := 0.0
var _bob_phase := 0.0
var _step_accum := 0.0
var _stamina_delay := 0.0
var _base_head := Vector3(0, 1.58, 0)
var _breath_time := 0.0
var _noise_world: Node = null
var _last_hit := 0.0


func _ready() -> void:
	_apply_lamp()
	add_to_group("player")
	_base_head = head.position
	_noise_world = get_tree().get_first_node_in_group("world")
	if Game.quality < 1:
		fill_light.visible = false
	# low quality falls back to the procedural spring; the joint rig is cheap
	# but it is one more body for the solver on very weak hardware
	var use_physics := Settings.camcorder_physics and Game.quality >= 1
	if Game.autotest and OS.get_environment("EIGHT_PAGES_FORCE_PROC_CAM") == "1":
		use_physics = false
	handle.set_physics_mode(use_physics)
	handle.impact_gain = 1.0


func _unhandled_input(event: InputEvent) -> void:
	if frozen:
		return
	# The mouse always looks. Nothing about touch mode disables it: a phone with
	# a mouse, a tablet with a trackpad, or a desktop where touch auto-detection
	# fired by mistake all get the same controls. On a real touchscreen nobody
	# is moving a mouse, so there is nothing to fight over.
	if event is InputEventMouseMotion:
		add_look(event.relative)
	# keyboard actions are never disabled by touch mode either
	if event.is_action_pressed("flashlight"):
		toggle_flashlight()
	if event.is_action_pressed("interact"):
		interact()


func add_look(delta_px: Vector2) -> void:
	var s := MOUSE_SENS * Settings.mouse_sensitivity
	rotate_y(-delta_px.x * s)
	var dy := delta_px.y * s
	if Settings.invert_y:
		dy = -dy
	pitch = clampf(pitch - dy, -1.35, 1.35)
	head.rotation.x = pitch


func toggle_flashlight() -> void:
	flashlight_on = not flashlight_on
	_apply_lamp()
	Sfx.play("ui_click", -22.0, 1.4)


## The torch has two modes: the warm spot, and the camcorder's IR lamp.
func _apply_lamp() -> void:
	if flashlight == null:
		return
	# both modes are "the lamp is on": F swaps the warm torch for the camcorder's
	# IR spot, it no longer turns the light off entirely
	if flashlight_on:
		flashlight.visible = true
	ir_lamp = not flashlight_on
	if ir_lamp:
		flashlight.visible = true if Settings.camcorder else false
		flashlight.light_color = Color(0.62, 0.7, 1.0)
		flashlight.light_energy = IR_ENERGY
		flashlight.spot_range = IR_RANGE
		flashlight.spot_angle = IR_ANGLE
	else:
		flashlight.light_color = Color(1, 0.94, 0.78)
		flashlight.light_energy = 11.5
		flashlight.spot_range = 30.0
		flashlight.spot_angle = 30.0
	# a hair of fill so the lamp's own spill is visible on the ground at your feet
	fill_light.light_color = Color(0.55, 0.66, 0.85) if not ir_lamp else Color(0.5, 0.62, 0.9)
	fill_light.light_energy = 0.34 if not ir_lamp else 0.22


func interact() -> void:
	var world := get_tree().get_first_node_in_group("world")
	if world != null and world.has_method("try_pickup"):
		world.try_pickup(self)


func _physics_process(delta: float) -> void:
	if frozen:
		velocity = Vector3.ZERO
		move_and_slide()
		return

	# WASD/arrows are always read; the virtual stick adds to them
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	input += touch_move
	input = input.limit_length(1.0)

	var want_sprint := Input.is_action_pressed("sprint") or touch_sprint
	var moving_forward := input.y < -0.12
	var has_speed := Vector2(velocity.x, velocity.z).length() > 0.6
	sprinting = want_sprint and moving_forward and has_speed and stamina > 0.5

	if sprinting:
		stamina = maxf(0.0, stamina - STAMINA_DRAIN * delta)
		_stamina_delay = 0.9
	else:
		_stamina_delay = maxf(0.0, _stamina_delay - delta)
		if _stamina_delay <= 0.0:
			stamina = minf(STAMINA_MAX, stamina + STAMINA_REGEN * delta)
	if stamina <= 0.5:
		sprinting = false

	var move_dir := (global_transform.basis * Vector3(input.x, 0.0, input.y))
	move_dir.y = 0.0
	move_dir = move_dir.normalized() if move_dir.length() > 0.02 else Vector3.ZERO

	var target_speed := SPRINT_SPEED if sprinting else WALK_SPEED
	if input.length() < 0.15:
		target_speed = 0.0
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	horiz = horiz.move_toward(move_dir * target_speed, ACCEL * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z

	if is_on_floor():
		velocity.y = -0.2
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()

	_update_bumps(delta, horiz.length())
	_update_bob(delta, horiz.length())
	_update_footsteps(delta, horiz.length())
	_update_breathing(delta)


## Running into a tree shoves the camera rig: the joint does the rest.
func _update_bumps(delta: float, speed: float) -> void:
	_last_hit = maxf(0.0, _last_hit - delta)
	if speed < BUMP_SPEED or _last_hit > 0.0:
		return
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		if c == null:
			continue
		var n := c.get_normal()
		if absf(n.y) > 0.6:
			continue
		var strength := clampf((speed - BUMP_SPEED) / SPRINT_SPEED, 0.0, 1.0) * 2.2
		if strength > 0.02:
			handle.impact(-n, strength)
			handle.shake = maxf(handle.shake, strength * 0.05)
			shake_amount = maxf(shake_amount, strength * 0.012)
			_last_hit = 0.35
			Sfx.play("branch", -26.0 + strength * 8.0, randf_range(0.9, 1.1))
		return


func _update_bob(delta: float, speed: float) -> void:
	var speed_ratio := clampf(speed / SPRINT_SPEED, 0.0, 1.0)
	_bob_phase += delta * (5.2 + 4.5 * speed_ratio) * speed_ratio
	var amp := 0.030 * speed_ratio
	var y := sin(_bob_phase * 2.0) * amp
	var x := cos(_bob_phase) * amp * 0.8
	# the head bobs; the joint drags the camera along behind it
	_breath_time += delta
	var idle := (1.0 - speed_ratio) * 0.012
	var sway := sin(_breath_time * 1.5) * idle
	head.position = head.position.lerp(_base_head + Vector3(x, y + sway, 0.0), delta * 12.0)
	# the camera itself only carries the roll of the swing
	var tilt := -cos(_bob_phase) * 0.016 * speed_ratio
	tilt += sin(_breath_time * 0.7) * 0.004 * (1.0 - speed_ratio)
	handle.roll_target = tilt
	# damage / jumpscare shake rides on the rig as well
	handle.shake = maxf(shake_amount, 0.0)
	if shake_amount > 0.001:
		shake_amount = move_toward(shake_amount, 0.0, delta * 1.4)


func _update_footsteps(delta: float, speed: float) -> void:
	if speed < 0.6 or not is_on_floor():
		return
	_step_accum += speed * delta
	var stride := 0.9 if not sprinting else 1.35
	if _step_accum >= stride:
		_step_accum = 0.0
		handle.footstep(1.4 if sprinting else 1.0)
		Sfx.footstep(sprinting)
		if _noise_world != null:
			_noise_world.noise_emitted(position, 14.0 if sprinting else 6.0)


func _update_breathing(delta: float) -> void:
	var exertion := 1.0 - stamina / STAMINA_MAX
	# the loop itself is mastered loud (it is a real strained breath now), so the
	# fader range sits lower: inaudible at rest, close and ragged when spent
	var target := -74.0 + 42.0 * exertion
	target += -9.0 * clampf(flicker, 0.0, 1.0)
	Sfx.set_loop_volume("breath_loop", maxf(target, -80.0))


func _process(delta: float) -> void:
	_update_aspect()
	# walking FOV + sprint kick
	var target_fov := 74.0
	if sprinting:
		target_fov = 82.0
	camera.fov = lerp(camera.fov, target_fov, delta * 4.0)

	# flashlight flicker driven by the world (Slender proximity / static)
	var base_energy := IR_ENERGY if ir_lamp else 11.5
	if flicker > 0.01:
		var f := 1.0 - flicker * randf_range(0.2, 1.0)
		flashlight.light_energy = base_energy * clampf(f, 0.05, 1.0)
	else:
		flashlight.light_energy = lerp(flashlight.light_energy, base_energy, delta * 6.0)


func _update_aspect() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var r := vp.get_visible_rect().size
	var portrait := r.y > r.x
	if portrait and camera.keep_aspect != Camera3D.KEEP_WIDTH:
		camera.keep_aspect = Camera3D.KEEP_WIDTH
	elif not portrait and camera.keep_aspect != Camera3D.KEEP_HEIGHT:
		camera.keep_aspect = Camera3D.KEEP_HEIGHT


func freeze() -> void:
	frozen = true
	touch_move = Vector2.ZERO
	touch_sprint = false


func look_at_point(point: Vector3) -> void:
	var to := point - camera.global_position
	var flat := Vector2(to.x, to.z).length()
	rotation.y = atan2(to.x, to.z) + PI
	head.rotation.x = atan2(to.y, flat)
	pitch = head.rotation.x
	# a snap this large is a cut, not a turn: put the rig straight there
	if handle != null:
		handle.snap()


func set_touch_move(v: Vector2) -> void:
	touch_move = v


func set_touch_sprint(v: bool) -> void:
	touch_sprint = v


## True when the camera is being carried by the physics rig.
func handheld() -> bool:
	return handle != null and handle.physics_mode
