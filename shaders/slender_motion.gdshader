shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.06, 0.06, 0.07, 1.0);
uniform float surface_roughness = 0.9;
uniform float glow = 0.04;
// Explicit clocks (not TIME) allow hidden/dead figures and inspection to freeze.
uniform float motion_time = 0.0;
uniform float gait_phase = 0.0;
uniform float chase_amount : hint_range(0.0, 1.0) = 0.0;
uniform float freedom : hint_range(0.0, 1.0) = 1.0;

void rotate_x(inout vec3 p, inout vec3 n, vec3 pivot, float angle) {
	float c = cos(angle); float s = sin(angle);
	mat3 r = mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, s), vec3(0.0, -s, c));
	p = pivot + r * (p - pivot); n = r * n;
}
void rotate_z(inout vec3 p, inout vec3 n, vec3 pivot, float angle) {
	float c = cos(angle); float s = sin(angle);
	mat3 r = mat3(vec3(c, s, 0.0), vec3(-s, c, 0.0), vec3(0.0, 0.0, 1.0));
	p = pivot + r * (p - pivot); n = r * n;
}
void vertex() {
	vec3 rest = VERTEX;
	float region = floor(COLOR.r * 8.0 + 0.5);
	float t = motion_time;
	float free_motion = mix(0.035, 1.0, freedom);
	float run = chase_amount;
	float side = (region == 2.0 || region == 4.0 || region == 6.0) ? -1.0 : 1.0;
	float step_wave = sin(gait_phase + (side < 0.0 ? 3.14159265 : 0.0));
	if (region == 1.0) {
		// Almost imperceptible tilt while watched; no large head-target drift.
		rotate_z(VERTEX, NORMAL, vec3(0.0, 2.32, 0.0), (sin(t * 0.61) * 0.038 + 0.018) * free_motion);
		rotate_x(VERTEX, NORMAL, vec3(0.0, 2.32, 0.0), sin(t * 0.83) * 0.022 * free_motion - run * 0.06);
	} else if (region == 2.0 || region == 3.0) {
		// Fingertips curl around their knuckles. Palm/wrist remain attached.
		float fingers = 1.0 - smoothstep(0.80, 0.86, rest.y);
		rotate_x(VERTEX, NORMAL, vec3(side * 0.415, 0.85, 0.082), fingers * (0.14 + sin(t * 1.27 + side) * 0.11) * free_motion);
		// Elbow bends first, then the entire chain rotates at the shoulder.
		float forearm = 1.0 - smoothstep(1.48, 1.72, rest.y);
		float elbow = run * (0.18 + max(0.0, -step_wave) * 0.32) + sin(t * 0.9 + side) * 0.018 * free_motion;
		rotate_x(VERTEX, NORMAL, vec3(side * 0.35, 1.62, 0.02), forearm * elbow);
		float shoulder = 1.0 - smoothstep(2.10, 2.22, rest.y);
		rotate_x(VERTEX, NORMAL, vec3(side * 0.22, 2.17, 0.0), shoulder * (-step_wave * run * 0.24 + sin(t * 0.72 + side) * 0.022 * free_motion));
	} else if (region == 4.0 || region == 5.0) {
		// Distal bend followed by hip swing. Restrained stride retains a gliding,
		// inhuman chase instead of a large cartoon run cycle.
		float shin = 1.0 - smoothstep(0.49, 0.72, rest.y);
		float knee = max(0.0, -step_wave) * 0.48 * run;
		rotate_x(VERTEX, NORMAL, vec3(side * 0.12, 0.60, 0.02), -knee * shin);
		float hip = 1.0 - smoothstep(0.98, 1.20, rest.y);
		rotate_x(VERTEX, NORMAL, vec3(side * 0.10, 1.13, 0.0), step_wave * 0.25 * run * hip);
		// Lift the returning foot to keep the planted sole above the floor.
		VERTEX.y += max(0.0, -step_wave) * run * 0.045 * hip;
	} else if (region >= 6.0) {
		float tip = smoothstep(0.17, 1.05, abs(rest.x));
		VERTEX.z += sin(t * 1.05 + abs(rest.x) * 3.8 + rest.y * 2.1 + side) * tip * (0.065 * free_motion + 0.065 * run);
		rotate_z(VERTEX, NORMAL, vec3(side * 0.12, 1.6, -0.1), sin(t * 0.81 + rest.y * 2.3 + side) * tip * (0.035 * free_motion + 0.04 * run));
	}
	// Coherent ribcage breath, suppressed under observation. No root translation.
	float chest = smoothstep(1.25, 1.8, rest.y) * (1.0 - smoothstep(2.18, 2.34, rest.y));
	float breath = sin(t * 1.35) * 0.006 * free_motion;
	VERTEX.z += chest * breath;
	VERTEX.x += sign(rest.x) * chest * breath * 0.4;
	// A tiny unified lean binds the articulated parts together during the chase.
	rotate_x(VERTEX, NORMAL, vec3(0.0, 1.1, 0.0), -0.035 * run * smoothstep(1.0, 1.7, rest.y));
	NORMAL = normalize(NORMAL);
}
void fragment() {
	ALBEDO = base_color.rgb;
	ROUGHNESS = surface_roughness;
	EMISSION = base_color.rgb * glow;
}
