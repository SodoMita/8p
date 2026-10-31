extends SceneTree

func _initialize() -> void:
	var out := {}
	for i in 6:
		var path := "res://assets/models/tree_%d.res" % i
		var m: Mesh = load(path)
		if m == null:
			continue
		var arr: Array = m.surface_get_arrays(0)
		out[str(i)] = {
			"verts": Array(arr[Mesh.ARRAY_VERTEX]),
			"normals": Array(arr[Mesh.ARRAY_NORMAL]),
			"index": Array(arr[Mesh.ARRAY_INDEX]),
		}
	var f := FileAccess.open("/tmp/trees.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	print("[dump] wrote /tmp/trees.json")
	quit()
