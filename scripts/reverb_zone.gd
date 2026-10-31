extends Area3D
## Spatial stone-hall ReverbZone placed over the procedural labyrinth.
##
## Configures Godot's native Area3D 3D reverb bus (for AudioStreamPlayer3D) AND
## drives Sfx.set_reverb() continuously with threshold feathering across the
## entrance archways so footsteps, breathing, whispers and screams echo off the
## stone corridors while exterior forest wind muffles behind the walls.

var half_extents := Vector3(11.6, 2.8, 11.6)
var feather := 2.4
var current_amount := 0.0
var player_inside := false

var _last_player_pos := Vector3.INF
var _has_entered_signal := false


func setup(extents: Vector3, edge_feather := 2.4) -> void:
	half_extents = extents
	feather = maxf(edge_feather, 0.25)
	add_to_group("reverb_zone")

	collision_layer = 0
	collision_mask = 2  # Player CharacterBody3D lives on layer 2
	monitoring = true
	monitorable = false

	# Native Godot 3D spatial reverb routing
	reverb_bus_enabled = true
	reverb_bus_name = StringName(Sfx.SPATIAL_REVERB_BUS)
	reverb_bus_amount = 0.58
	reverb_bus_uniformity = 0.78

	var col := CollisionShape3D.new()
	col.name = "ReverbBounds"
	var box := BoxShape3D.new()
	box.size = half_extents * 2.0
	col.shape = box
	add_child(col)

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node3D) -> void:
	if body != null and body.is_in_group("player"):
		_has_entered_signal = true
		player_inside = true
		_update_for_player(body, 0.0, true)


func _on_body_exited(body: Node3D) -> void:
	if body != null and body.is_in_group("player"):
		player_inside = false


## Returns [0..1] stone-reverb strength at a world-space point.
func amount_at(world_pos: Vector3) -> float:
	var lp := to_local(world_pos)
	if absf(lp.y) > half_extents.y:
		return 0.0
	var dx := half_extents.x - absf(lp.x)
	var dz := half_extents.z - absf(lp.z)
	var inside_depth := minf(dx, dz)
	if inside_depth <= 0.0:
		return 0.0
	var t := clampf(inside_depth / feather, 0.0, 1.0)
	# smoothstep from 0.26 right inside the gateposts to 1.0 in the corridors
	var s := t * t * (3.0 - 2.0 * t)
	return lerpf(0.26, 1.0, s)


func _physics_process(delta: float) -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player == null:
		return
	_update_for_player(player, delta, false)


func _update_for_player(player: Node3D, delta: float, force_snap: bool) -> void:
	var pos := player.global_position + Vector3(0.0, 0.9, 0.0)
	var target := amount_at(pos)
	player_inside = target > 0.0
	var jumped := _last_player_pos == Vector3.INF or pos.distance_to(_last_player_pos) > 4.0
	_last_player_pos = pos
	if force_snap or jumped or delta <= 0.0:
		current_amount = target
	else:
		var k := 1.0 - exp(-6.5 * delta)
		current_amount = lerpf(current_amount, target, k)
		if current_amount < 0.004 and target == 0.0:
			current_amount = 0.0
	Sfx.refresh_reverb_zones()


func _exit_tree() -> void:
	current_amount = 0.0
	Sfx.refresh_reverb_zones()
