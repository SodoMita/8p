shader_type spatial;
render_mode cull_disabled;

uniform vec4 concrete_color : source_color = vec4(0.31, 0.315, 0.30, 1.0);
uniform float formwork_spacing : hint_range(0.25, 1.5) = 0.62;
uniform float damp_height : hint_range(0.2, 3.0) = 1.45;

varying vec3 world_pos;
varying vec3 world_normal;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash13(i);
	float b = hash13(i + vec3(1.0, 0.0, 0.0));
	float c = hash13(i + vec3(0.0, 1.0, 0.0));
	float d = hash13(i + vec3(1.0, 1.0, 0.0));
	float e = hash13(i + vec3(0.0, 0.0, 1.0));
	float f1 = hash13(i + vec3(1.0, 0.0, 1.0));
	float g = hash13(i + vec3(0.0, 1.0, 1.0));
	float h = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(a, b, f.x), mix(c, d, f.x), f.y),
		mix(mix(e, f1, f.x), mix(g, h, f.x), f.y), f.z);
}

float fbm3(vec3 p) {
	float n = vnoise(p) * 0.5;
	n += vnoise(p * 2.03 + vec3(17.3, 5.1, 9.7)) * 0.25;
	n += vnoise(p * 4.01 + vec3(3.7, 11.9, 8.1)) * 0.125;
	return n * 1.142857;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec3 p = world_pos;
	vec3 geo_n = normalize(world_normal) * (FRONT_FACING ? 1.0 : -1.0);

	float broad = fbm3(p * 0.33 + vec3(7.2, 1.6, 4.3));
	float mid = vnoise(p * 3.4 + vec3(3.1, 8.7, 5.4));
	float fine = vnoise(p * 31.0 + vec3(1.7, 9.3, 2.9));
	float micro = vnoise(p * 92.0 + vec3(11.2, 4.6, 7.1));

	float aggregate = smoothstep(0.34, 0.72, fine * 0.72 + micro * 0.28);
	float pore = smoothstep(0.80, 0.91, micro * 0.70 + fine * 0.30);
	float vertical = 1.0 - smoothstep(0.55, 0.88, abs(geo_n.y));

	float board_phase = p.y / formwork_spacing;
	float seam_dist = abs(fract(board_phase + 0.5) - 0.5) * formwork_spacing;
	float seam = (1.0 - smoothstep(0.002, 0.018, seam_dist)) * vertical;
	float board_var = hash13(vec3(floor(board_phase), 13.7, 5.2));

	float crack_field = fbm3(p * vec3(1.9, 1.35, 1.9) + vec3(21.4, 7.3, 12.8));
	float crack_dist = abs(crack_field - 0.505);
	float crack_mask = smoothstep(0.56, 0.76, vnoise(p * 0.52 + vec3(4.1, 8.3, 2.7)));
	float cracks = (1.0 - smoothstep(0.004, 0.012, crack_dist)) * crack_mask;
	float crack_halo = (1.0 - smoothstep(0.006, 0.060, crack_dist)) * crack_mask;

	float rain_a = vnoise(vec3(p.x * 6.4 + p.z * 0.7, p.y * 0.23, p.z * 6.4 - p.x * 0.6) + vec3(8.3, 2.4, 4.1));
	float rain_b = vnoise(vec3(p.x * 19.0 - p.z * 0.5, p.y * 0.52 + 7.0, p.z * 19.0 + p.x * 0.4));
	float rain = smoothstep(0.57, 0.78, rain_a) * (0.55 + 0.45 * rain_b);
	rain *= 0.35 + 0.65 * vertical;

	float ground = 1.0 - smoothstep(0.0, damp_height * (0.85 + broad * 0.70 + mid * 0.25), p.y);
	float damp = ground * (0.55 + 0.45 * smoothstep(0.25, 0.75, broad));
	float moss_noise = vnoise(p * vec3(2.2, 1.0, 2.2) + vec3(14.7, 3.2, 9.4));
	float moss = smoothstep(0.58, 0.78, moss_noise) * ground;

	vec3 albedo = concrete_color.rgb * (0.78 + 0.32 * (broad * 0.62 + mid * 0.38));
	albedo *= (0.92 + 0.16 * aggregate) * (1.0 + (board_var - 0.5) * 0.045 * vertical);
	albedo *= 1.0 - seam * (0.22 + 0.15 * mid);
	albedo *= 1.0 - crack_halo * 0.12 - cracks * 0.55;
	albedo = mix(albedo, albedo * 0.55, pore * 0.7);
	albedo *= 1.0 - rain * 0.20;
	albedo = mix(albedo, albedo * vec3(0.55, 0.64, 0.52), damp * 0.55);
	albedo = mix(albedo, vec3(0.095, 0.115, 0.070), moss * 0.45);

	float rough = 0.88 + (mid - 0.5) * 0.07 + (fine - 0.5) * 0.04;
	rough = mix(rough, 0.99, pore * 0.65);
	rough = mix(rough, 0.78, rain * 0.28);
	rough = mix(rough, 1.0, moss * 0.8);
	rough = mix(rough, 0.96, seam * 0.5);

	vec3 helper = abs(geo_n.y) < 0.98 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(helper, geo_n));
	vec3 bitangent = cross(geo_n, tangent);
	float e = 0.006;
	float h0 = vnoise(p * 34.0);
	float ht = vnoise((p + tangent * e) * 34.0);
	float hb = vnoise((p + bitangent * e) * 34.0);
	vec3 bump_n = normalize(geo_n - (tangent * (ht - h0) + bitangent * (hb - h0)) * 0.30);
	NORMAL = normalize((VIEW_MATRIX * vec4(bump_n, 0.0)).xyz);

	ALBEDO = clamp(albedo, 0.0, 1.0);
	ROUGHNESS = clamp(rough, 0.72, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.32;
}
