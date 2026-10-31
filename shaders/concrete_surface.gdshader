shader_type spatial;
render_mode cull_disabled;
uniform sampler2D albedo_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roughness_map : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float metres_per_repeat = 1.2;
uniform float normal_strength = 0.85;
uniform float roughness_multiplier = 1.0;
uniform float crack_strength = 0.8;
varying vec3 metric_pos;
varying vec3 material_normal;
varying vec3 frame_x;
varying vec3 frame_y;
varying vec3 frame_z;
varying vec3 world_pos;
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
 // Remove rotation only, retaining metric distances, scale and parent shear.
 frame_x = normalize(MODEL_MATRIX[0].xyz);
 frame_y = normalize(MODEL_MATRIX[1].xyz - frame_x * dot(frame_x, MODEL_MATRIX[1].xyz));
 frame_z = normalize(cross(frame_x, frame_y));
 mat3 frame = mat3(frame_x, frame_y, frame_z);
 metric_pos = transpose(frame) * (MODEL_MATRIX * vec4(VERTEX, 0.0)).xyz;
 material_normal = transpose(frame) * normalize(MODEL_NORMAL_MATRIX * NORMAL);
 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
vec4 surface_sample(sampler2D tex, vec2 uv, float blend) {
 mat2 turn = mat2(vec2(0.8,0.6),vec2(-0.6,0.8));
 return mix(texture(tex, uv), texture(tex, turn * uv * 1.113 + vec2(7.31,19.17)), blend);
}
vec3 normal_sample(vec2 uv, float blend) {
 mat2 turn = mat2(vec2(0.8,0.6),vec2(-0.6,0.8));
 vec3 a = texture(normal_map, uv).xyz * 2.0 - 1.0;
 vec3 b = texture(normal_map, turn * uv * 1.113 + vec2(7.31,19.17)).xyz * 2.0 - 1.0;
 b.xy = transpose(turn) * b.xy;
 return normalize(mix(a,b,blend));
}
void fragment() {
 vec3 p = metric_pos / metres_per_repeat;
 vec3 n = normalize(material_normal);
 vec3 weights = pow(abs(n),vec3(5.0));
 weights /= max(dot(weights,vec3(1.0)),0.0001);
 // Continuous, aperiodic crossfade: no tile grid, seams or repeated offsets.
 float blend = 0.25 + 0.5 * smoothstep(0.25,0.75,vnoise(p * 0.47 + vec3(8.3,2.1,9.6)));
 vec2 ux = p.zy;
 vec2 uy = p.xz;
 vec2 uz = p.xy;
 vec3 base = vec3(0.0);
 float rough = 0.0;
 vec3 perturb = vec3(0.0);
 // Skip invisible projections (six fetches on a flat face, not eighteen).
 if (weights.x > 0.001) {
  base += surface_sample(albedo_map,ux,blend).rgb * weights.x;
  rough += surface_sample(roughness_map,ux,blend).r * weights.x;
  vec3 detail = normal_sample(ux,blend);
  perturb += vec3(0.0,detail.y,detail.x) * weights.x;
 }
 if (weights.y > 0.001) {
  base += surface_sample(albedo_map,uy,blend).rgb * weights.y;
  rough += surface_sample(roughness_map,uy,blend).r * weights.y;
  vec3 detail = normal_sample(uy,blend);
  perturb += vec3(detail.x,0.0,detail.y) * weights.y;
 }
 if (weights.z > 0.001) {
  base += surface_sample(albedo_map,uz,blend).rgb * weights.z;
  rough += surface_sample(roughness_map,uz,blend).r * weights.z;
  vec3 detail = normal_sample(uz,blend);
  perturb += vec3(detail.x,detail.y,0.0) * weights.z;
 }
 // Keep main's high-resolution concrete noise; only add broad non-repeating age.
 float broad = fbm3(metric_pos * 0.29 + vec3(7.2,1.6,4.3));
 base *= 0.88 + broad * 0.24;
 float crack_field = fbm3(metric_pos * vec3(1.9,1.35,1.9) + vec3(21.4,7.3,12.8));
 float crack_dist = abs(crack_field - 0.505);
 float mask = smoothstep(0.56,0.76,vnoise(metric_pos * 0.52 + vec3(4.1,8.3,2.7)));
 float aa = max(fwidth(crack_dist), 0.0007);
 float cracks = (1.0 - smoothstep(0.004,0.004 + max(aa,0.003),crack_dist)) * mask;
 float halo = (1.0 - smoothstep(0.006,0.06,crack_dist)) * mask;
 base *= 1.0 - crack_strength * (cracks * 0.55 + halo * 0.12);
 // Texture-space normal samples rotate back into the shared material frame.
 perturb -= n * dot(n,perturb);
 mat3 frame = mat3(normalize(frame_x),normalize(frame_y),normalize(frame_z));
 vec3 world_n = frame * normalize(n + perturb * normal_strength);
 NORMAL = normalize((VIEW_MATRIX * vec4(world_n,0.0)).xyz) * (FRONT_FACING ? 1.0 : -1.0);
 ALBEDO = clamp(base,vec3(0.0),vec3(1.0));
 ROUGHNESS = clamp(rough * roughness_multiplier + cracks * 0.08,0.35,1.0);
 METALLIC = 0.0;
 SPECULAR = 0.35;
}
