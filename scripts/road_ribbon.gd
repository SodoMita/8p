class_name RoadRibbon
extends RefCounted
## Builds a reusable road / dirt-track ribbon mesh from a terrain-following polyline.
## The mesh is generated entirely in code and can be used by any 3D scene.

## Height of the road edges above the ground plane, in metres.
const GROUND_OFFSET := 0.02
## Number of vertices across the ribbon: left edge, crowned centre, right edge.
const COLUMNS := 3


## Builds a triangulated ribbon [ArrayMesh] following [param points].
## [param points] is the centreline on the ground; Y follows the terrain height.
## [param width] is the full ribbon width in metres.
## [param uv_metres] is how many metres one texture tile spans along the road.
## [param camber] is the crown height of the centre above the edges, in metres.
## [param wobble_seed] deterministically seeds a gentle horizontal wobble.
## [param segments_per_span] is how many spline samples are taken per input span.
static func build(points: PackedVector3Array, width: float, uv_metres: float = 4.0,
		camber: float = 0.06, wobble_seed: int = 1234,
		segments_per_span: int = 2) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var centre := _sanitise(points)
	if centre.size() < 2 or width <= 0.0:
		return mesh

	var samples_per_span: int = maxi(segments_per_span, 1)
	var uv_scale: float = uv_metres if uv_metres > 0.0 else 1.0

	var centreline := _sample_catmull_rom(centre, samples_per_span)
	_apply_wobble(centreline, width, wobble_seed)

	var tangents := _tangents(centreline)
	var arc_lengths := _arc_lengths(centreline)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half_width: float = width * 0.5
	for i in range(centreline.size()):
		var forward := tangents[i]
		forward.y = 0.0
		if forward.length_squared() < 1e-8:
			forward = Vector3.FORWARD
		forward = forward.normalized()

		var right := forward.cross(Vector3.UP)
		if right.length_squared() < 1e-8:
			right = Vector3.RIGHT
		right = right.normalized()

		var base := centreline[i]
		var left_edge := base - right * half_width + Vector3.UP * GROUND_OFFSET
		var crowned_centre := base + Vector3.UP * (GROUND_OFFSET + camber)
		var right_edge := base + right * half_width + Vector3.UP * GROUND_OFFSET
		var v: float = arc_lengths[i] / uv_scale

		st.set_uv(Vector2(0.0, v))
		st.add_vertex(left_edge)
		st.set_uv(Vector2(0.5, v))
		st.add_vertex(crowned_centre)
		st.set_uv(Vector2(1.0, v))
		st.add_vertex(right_edge)

	for i in range(centreline.size() - 1):
		var row: int = i * COLUMNS
		var next_row: int = (i + 1) * COLUMNS

		# Left half of the crown, wound counter-clockwise seen from above.
		st.add_index(row + 0)
		st.add_index(row + 1)
		st.add_index(next_row + 1)
		st.add_index(row + 0)
		st.add_index(next_row + 1)
		st.add_index(next_row + 0)

		# Right half of the crown, wound counter-clockwise seen from above.
		st.add_index(row + 1)
		st.add_index(row + 2)
		st.add_index(next_row + 2)
		st.add_index(row + 1)
		st.add_index(next_row + 2)
		st.add_index(next_row + 1)

	st.generate_normals()
	return st.commit()


## Returns the total arc length of the supplied polyline, in metres.
static func length_of(points: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
	return total


## Drops consecutive duplicate points while retaining their terrain heights.
static func _sanitise(points: PackedVector3Array) -> PackedVector3Array:
	var cleaned := PackedVector3Array()
	for point in points:
		if cleaned.is_empty() or cleaned[cleaned.size() - 1].distance_squared_to(point) > 1e-8:
			cleaned.append(point)
	return cleaned


## Returns Catmull-Rom style tangents: forward difference at the ends,
## central differences in between.
static func _tangents(points: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	var count := points.size()
	if count == 0:
		return result
	result.resize(count)
	if count == 1:
		result[0] = Vector3.ZERO
		return result
	result[0] = points[1] - points[0]
	for i in range(1, count - 1):
		result[i] = (points[i + 1] - points[i - 1]) * 0.5
	result[count - 1] = points[count - 1] - points[count - 2]
	return result


## Samples a Catmull-Rom spline through the control points.
static func _sample_catmull_rom(points: PackedVector3Array,
		segments_per_span: int) -> PackedVector3Array:
	var result := PackedVector3Array()
	var tangents := _tangents(points)
	var last := points.size() - 1
	for i in range(last):
		for step in range(segments_per_span):
			var t: float = float(step) / float(segments_per_span)
			result.append(_hermite(points[i], tangents[i], points[i + 1], tangents[i + 1], t))
	result.append(points[last])
	return result


## Evaluates one cubic Hermite segment.
static func _hermite(p0: Vector3, m0: Vector3, p1: Vector3, m1: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	var h00 := 2.0 * t3 - 3.0 * t2 + 1.0
	var h10 := t3 - 2.0 * t2 + t
	var h01 := -2.0 * t3 + 3.0 * t2
	var h11 := t3 - t2
	return p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11


## Adds a deterministic, gentle horizontal wobble to the sampled centreline.
static func _apply_wobble(points: PackedVector3Array, width: float, seed_value: int) -> void:
	if points.size() < 2:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var total_length := 0.0
	for i in range(1, points.size()):
		total_length += points[i].distance_to(points[i - 1])
	if total_length <= 1e-6:
		return

	var amplitude_a: float = clampf(width * 0.05, 0.02, 0.5)
	var amplitude_b: float = amplitude_a * rng.randf_range(0.25, 0.5)
	var wavelength_a: float = maxf(total_length / rng.randf_range(1.5, 3.5), 1.0)
	var wavelength_b: float = maxf(wavelength_a * rng.randf_range(0.3, 0.6), 0.75)
	var phase_a: float = rng.randf_range(0.0, TAU)
	var phase_b: float = rng.randf_range(0.0, TAU)

	var tangents := _tangents(points)
	var travelled := 0.0
	for i in range(points.size()):
		if i > 0:
			travelled += points[i].distance_to(points[i - 1])
		var forward := tangents[i]
		forward.y = 0.0
		if forward.length_squared() < 1e-8:
			forward = Vector3.FORWARD
		var right := forward.normalized().cross(Vector3.UP)
		if right.length_squared() < 1e-8:
			right = Vector3.RIGHT
		right = right.normalized()

		var offset := amplitude_a * sin(TAU * travelled / wavelength_a + phase_a)
		offset += amplitude_b * sin(TAU * travelled / wavelength_b + phase_b)
		var point := points[i] + right * offset
		points[i] = point


## Returns the cumulative arc length at every point of the polyline.
static func _arc_lengths(points: PackedVector3Array) -> PackedFloat32Array:
	var lengths := PackedFloat32Array()
	lengths.resize(points.size())
	var travelled := 0.0
	for i in range(points.size()):
		if i > 0:
			travelled += points[i].distance_to(points[i - 1])
		lengths[i] = travelled
	return lengths
