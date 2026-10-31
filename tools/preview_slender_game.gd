extends SceneTree
## Actual game environment/camera inspection, without changing runtime scripts.
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	change_scene_to_file("res://scenes/World.tscn")
	await create_timer(2.0).timeout
	var world := current_scene
	var player: Node3D = world.player
	var slender: Node3D = world.slender
	world.autotest_no_pickup = true
	player.global_position = Vector3(0, 0.1, 5)
	player.rotation.y = 0
	player.look_at_point(Vector3(0, 1.9, -3))
	player.set_physics_process(false)
	slender.set_process(false)
	slender.global_position = Vector3(0, 0, -3)
	slender.rotation.y = 0
	slender.visible = true
	await create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://screenshots/slender_after_game.png")
	print("[preview] saved actual forest view")
	quit()
