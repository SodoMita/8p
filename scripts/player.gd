extends CharacterBody3D
## First person controller: WASD + mouse on desktop, virtual stick + swipe on touch.

const WALK_SPEED := 3.15
const SPRINT_SPEED := 6.1
const ACCEL := 11.0
const GRAVITY := 18.0
const MOUSE_SENS := 0.0021
const STAMINA_MAX := 100.0
const STAMINA_DRAIN := 17.0
const STAMINA_REGEN := 13.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera
@onready var flashlight: SpotLight3D = $Head/Camera/Flashlight
@onready var fill_light: OmniLight3D = $Head/Fill

var pitch := 0.0
var stamina := STAMINA_MAX
var sprinting := false
var frozen := false
var flashlight_on := true
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


func _ready() -> void:
	add_to_group("player")
	_base_head = head.position
	_noise_world = get_tree().get_first_node_in_group("world")
	if Game.quality < 1:
		fill_light.visible = false
	flashlight.visible = flashlight_on


func _unhandled_input(event: InputEvent) -> void:
	if Game.touch_mode or frozen:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		add_look(event.relative)
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
	flashlight.visible = flashlight_on
	Sfx.play("ui_click", -22.0, 1.4)


func interact() -> void:
	var world := get_tree().get_first_node_in_group("world")
	if world != null and world.has_method("try_pickup"):
		world.try_pickup(self)


func _physics_process(delta: float) -> void:
	if frozen:
		velocity = Vector3.ZERO
		move_and_slide()
		return

	var input := Vector2.ZERO
	if not Game.touch_mode:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	input += touch_move
	input = input.limit_length(1.0)

	var want_sprint := (Input.is_action_pressed("sprint") and not Game.touch_mode) or touch_sprint
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

	_update_bob(delta, horiz.length())
	_update_footsteps(delta, horiz.length())
	_update_breathing(delta)


func _update_bob(delta: float, speed: float) -> void:
	var speed_ratio := clampf(speed / SPRINT_SPEED, 0.0, 1.0)
	_bob_phase += delta * (5.2 + 4.5 * speed_ratio) * speed_ratio
	var amp := 0.028 * speed_ratio
	var y := sin(_bob_phase * 2.0) * amp
	var x := cos(_bob_phase) * amp * 0.8
	head.position = head.position.lerp(_base_head + Vector3(x, y, 0.0), delta * 12.0)
	# idle breathing sway
	_breath_time += delta
	var idle := (1.0 - speed_ratio) * 0.012
	camera.position.y = sin(_breath_time * 1.5) * idle
	var tilt := -cos(_bob_phase) * 0.012 * speed_ratio
	camera.rotation.z = lerp_angle(camera.rotation.z, tilt, delta * 8.0)
	# damage / jumpscare shake
	if shake_amount > 0.001:
		var s := shake_amount
		camera.rotation.z += randf_range(-s, s)
		camera.rotation.x += randf_range(-s, s) * 0.5
		shake_amount = move_toward(shake_amount, 0.0, delta * 1.4)


func _update_footsteps(delta: float, speed: float) -> void:
	if speed < 0.6 or not is_on_floor():
		return
	_step_accum += speed * delta
	var stride := 0.9 if not sprinting else 1.35
	if _step_accum >= stride:
		_step_accum = 0.0
		Sfx.footstep(sprinting)
		if _noise_world != null:
			_noise_world.noise_emitted(position, 14.0 if sprinting else 6.0)


func _update_breathing(delta: float) -> void:
	var exertion := 1.0 - stamina / STAMINA_MAX
	var target := -60.0 + 42.0 * exertion
	target += -10.0 * clampf(flicker, 0.0, 1.0)
	Sfx.set_loop_volume("breath_loop", maxf(target, -60.0))


func _process(delta: float) -> void:
	_update_aspect()
	# walking FOV + sprint kick
	var target_fov := 74.0
	if sprinting:
		target_fov = 82.0
	camera.fov = lerp(camera.fov, target_fov, delta * 4.0)

	# flashlight flicker driven by the world (Slender proximity / static)
	var base_energy := 11.5
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


func set_touch_move(v: Vector2) -> void:
	touch_move = v


func set_touch_sprint(v: bool) -> void:
	touch_sprint = v
