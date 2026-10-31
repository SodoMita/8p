extends SceneTree
## Check the actual runtime tie band geometry, not just declared dimensions.
func _initialize() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var parts: Array[MeshInstance3D] = load("res://scripts/slender_model.gd").new().build(host)
	var verts: PackedVector3Array = parts[1].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var ids := {}
	var edges := {}
	var count := 0
	for i in range(0,verts.size(),3):
		var is_band := true
		for j in 3:
			var p := verts[i+j]
			var at_end := absf(p.y-3.392)<0.00001 or absf(p.y-3.416)<0.00001
			var inner := pow(p.x/.076,2)+pow((p.z-.012)/.070,2)
			var outer := pow(p.x/.081,2)+pow((p.z-.012)/.075,2)
			if not at_end or (absf(inner-1)>0.0001 and absf(outer-1)>0.0001): is_band=false
		if not is_band: continue
		count += 1
		var face: Array[int] = []
		for j in 3:
			var p := verts[i+j]
			var key := "%.6f,%.6f,%.6f" % [p.x,p.y,p.z]
			if not ids.has(key): ids[key]=ids.size()
			face.append(ids[key])
		for j in 3:
			var a: int = face[j]
			var b: int = face[(j+1)%3]
			var edge := "%d:%d" % [mini(a,b),maxi(a,b)]
			edges[edge]=edges.get(edge,0)+1
	assert(count==384, "Actual 48-segment, four-wall closed tie loop required")
	for value in edges.values(): assert(value==2, "Tie band cannot have boundary/open edges")
	assert(ids.size()-edges.size()+count==0, "Tie band must have torus topology, not a capped disk")
	# Satin geometry must have depth around the knot rather than one flat diamond.
	var min_z := INF
	var max_z := -INF
	for p in verts:
		if p.y>=3.295 and p.y<=3.370 and absf(p.x)<.03 and p.z>.15:
			min_z=minf(min_z,p.z)
			max_z=maxf(max_z,p.z)
	assert(max_z-min_z>.025)
	print("[attachment-test] PASS: closed neck-encircling tie band (384 faces, no open edges, torus topology) and solid knot; blade attachment remains pinned by animation contract")
	host.queue_free()
	quit()
