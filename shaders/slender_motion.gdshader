shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;
uniform vec4 base_color : source_color = vec4(0.06, 0.06, 0.07, 1.0);
uniform float surface_roughness = 0.9;
uniform float glow = 0.04;
uniform float motion_time = 0.0;
uniform float chase_amount : hint_range(0.0, 1.0) = 0.0;
uniform float freedom : hint_range(0.0, 1.0) = 1.0;
uniform vec3 body_pose = vec3(0.0);
uniform vec2 arm_lag = vec2(0.0);
uniform vec3 left_leg = vec3(0.0);
uniform vec3 right_leg = vec3(0.0);
uniform vec3 tie_nodes[5];

void rotate_x(inout vec3 p, inout vec3 n, vec3 pivot, float a) {
	float c = cos(a); float s = sin(a);
	mat3 r = mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, s), vec3(0.0, -s, c));
	p = pivot + r * (p - pivot); n = r * n;
}
void rotate_z(inout vec3 p, inout vec3 n, vec3 pivot, float a) {
	float c = cos(a); float s = sin(a);
	mat3 r = mat3(vec3(c, s, 0.0), vec3(-s, c, 0.0), vec3(0.0, 0.0, 1.0));
	p = pivot + r * (p - pivot); n = r * n;
}
void vertex() {
	vec3 rest = VERTEX;
	float region = floor(COLOR.r * 8.0 + 0.5);
	float joint_weight = clamp(COLOR.g, 0.0, 1.0);
	float t = motion_time;
	float quiet = mix(0.025, 1.0, freedom);
	float side = (region == 2.0 || region == 4.0 || region == 6.0) ? -1.0 : 1.0;
	bool leg = region == 4.0 || region == 5.0;
	if (leg) {
		// Solved from actual planted/swinging foot targets, not a sine cycle.
		vec3 angles = region == 4.0 ? left_leg : right_leg;
		VERTEX.y += body_pose.y;
		vec3 hip = vec3(side * 0.10, 1.13 + body_pose.y, 0.0);
		vec3 knee = vec3(side * 0.12, 0.60 + body_pose.y, 0.02);
		vec3 ankle = vec3(side * 0.13, 0.07 + body_pose.y, 0.02);
		// Foot counter-rotation preserves a level sole during contact.
		float foot = 1.0 - smoothstep(0.10, 0.20, rest.y);
		rotate_z(VERTEX, NORMAL, ankle, -angles.z * foot);
		rotate_x(VERTEX, NORMAL, ankle, -(angles.x + angles.y) * foot);
		float shin = 1.0 - smoothstep(0.51, 0.68, rest.y);
		rotate_x(VERTEX, NORMAL, knee, angles.y * shin);
		float hip_weight = 1.0 - smoothstep(1.01, 1.20, rest.y);
		rotate_x(VERTEX, NORMAL, hip, angles.x * hip_weight * joint_weight);
		rotate_z(VERTEX, NORMAL, hip, angles.z * hip_weight * joint_weight);
	} else {
		if (region == 1.0) {
			// Vestibular counter-motion: head stays quieter than the shoulders.
			rotate_x(VERTEX, NORMAL, vec3(0.0, 2.32, 0.0), (-body_pose.x * 0.7 + sin(t * 0.43) * 0.009 * quiet) * joint_weight);
			rotate_z(VERTEX, NORMAL, vec3(0.0, 2.32, 0.0), (-body_pose.z * 0.7 + sin(t * 0.37) * 0.012 * quiet) * joint_weight);
		} else if (region == 2.0 || region == 3.0) {
			float fingers = 1.0 - smoothstep(0.80, 0.86, rest.y);
			rotate_x(VERTEX, NORMAL, vec3(side * 0.415, 0.85, 0.082), fingers * (0.10 + sin(t * 0.67 + side) * 0.025) * quiet);
			float forearm = 1.0 - smoothstep(1.48, 1.72, rest.y);
			rotate_x(VERTEX, NORMAL, vec3(side * 0.35, 1.62, 0.02), forearm * abs(arm_lag.x) * 0.45 * joint_weight);
			float shoulder = 1.0 - smoothstep(2.10, 2.22, rest.y);
			rotate_x(VERTEX, NORMAL, vec3(side * 0.22, 2.17, 0.0), shoulder * arm_lag.x * joint_weight);
			rotate_z(VERTEX, NORMAL, vec3(side * 0.22, 2.17, 0.0), shoulder * arm_lag.y * joint_weight);
		} else if (region == 6.0 || region == 7.0) {
			float tip = smoothstep(0.17, 1.05, abs(rest.x));
			VERTEX.z += tip * (sin(t * 0.65 + rest.y * 2.0 + side) * 0.018 * quiet - arm_lag.x * 0.8);
			rotate_z(VERTEX, NORMAL, vec3(side * 0.12, 1.6, -0.1), tip * (arm_lag.y * 0.6 + sin(t * 0.52 + rest.y + side) * 0.012 * quiet));
		} else if (region == 8.0) {
			// The blade is segmented at the physical distance-joint nodes.
			float along = clamp((2.176 - rest.y) / 0.074, 0.0, 4.0);
			int link = min(int(floor(along)), 3);
			float w = along - float(link);
			vec3 tangent = normalize(tie_nodes[link + 1] - tie_nodes[link]);
			vec3 right = normalize(cross(vec3(0.0, 0.0, 1.0), tangent));
			VERTEX = mix(tie_nodes[link], tie_nodes[link + 1], w) + right * rest.x;
			NORMAL = normalize(cross(tangent, right));
		}
		float chest = smoothstep(1.25, 1.8, rest.y) * (1.0 - smoothstep(2.18, 2.34, rest.y));
		VERTEX.z += chest * sin(t * 1.18) * 0.003 * quiet;
		float upper = smoothstep(1.04, 1.6, rest.y);
		rotate_x(VERTEX, NORMAL, vec3(0.0, 1.13, 0.0), body_pose.x * upper);
		rotate_z(VERTEX, NORMAL, vec3(0.0, 1.13, 0.0), body_pose.z * upper);
		VERTEX.y += body_pose.y;
	}
	NORMAL = normalize(NORMAL);
}
void fragment() {
	ALBEDO = base_color.rgb;
	ROUGHNESS = surface_roughness;
	EMISSION = base_color.rgb * glow;
}
