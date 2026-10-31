shader_type canvas_item;
render_mode unshaded;
// --------------------------------------------------------------------------- //
// CAMCORDER  —  one full-screen pass that turns the renderer into the finder
// of a cheap night-shift video camera (Outlast style).
//
// Everything happens in a single fragment shader on a full-rect ColorRect that
// sits at the very bottom of the HUD stack, so the 3D view is resampled once
// and the whole post chain stays inside one draw call:
//
//   lens warp + digital zoom      barrel distortion inside the lens circle
//   chromatic aberration          radial R/B split, scaled by dread
//   rolling-shutter band          a soft bright band that scrolls up the frame
//   tape tear / dropout           displaced slices and signal-loss blocks
//   scanlines + sensor grain      luminance weighted so shadows get noisy
//   lens dirt                     low-frequency blotches from the noise texture
//   grade                         crushed toe, cold shadows, warm highlights
//   IR / night-vision mode        monochrome green gain x4 when the light is off
//
// Performance: 1 screen tap at quality 0, 3 at quality 1+ (CA), plus two small
// noise taps. No loops, no branches on per-pixel data beyond a couple of
// smoothsteps, so it stays cheap on integrated GPUs and phones.
// --------------------------------------------------------------------------- //

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D noise_tex : repeat_enable, filter_linear;

uniform int quality : hint_range(0, 2) = 2;
uniform int debug_mode = 0;   // 1 = raw passthrough, 2 = optics only, 3 = no grain

// --- grade ------------------------------------------------------------------
uniform float exposure : hint_range(0.2, 2.5) = 1.0;
uniform float saturation : hint_range(0.0, 1.6) = 0.78;
uniform float gamma : hint_range(0.5, 2.0) = 0.94;   // sensor gamma, <1 lifts the night
uniform float shoulder : hint_range(0.0, 2.0) = 0.22; // highlight roll-off
uniform float lift : hint_range(-0.05, 0.2) = 0.007;  // tape black floor
uniform vec3 shadow_tint = vec3(0.74, 0.86, 1.0);
uniform vec3 highlight_tint = vec3(1.0, 0.965, 0.9);

// --- optics -----------------------------------------------------------------
uniform float lens_warp : hint_range(0.0, 0.4) = 0.075;
uniform float ca : hint_range(0.0, 4.0) = 0.65;      // pixels, radial
uniform float vignette : hint_range(0.0, 1.5) = 0.9;
uniform float zoom : hint_range(1.0, 1.25) = 1.0;    // digital crop pulse
uniform vec2 jitter = vec2(0.0);                     // handheld micro-shake (uv)

// --- tape -------------------------------------------------------------------
uniform float grain : hint_range(0.0, 1.0) = 0.34;
uniform float scanline : hint_range(0.0, 1.0) = 0.35;
uniform float rolling : hint_range(0.0, 1.0) = 0.25;
uniform float tear : hint_range(0.0, 1.0) = 0.0;      // sliced displacement
uniform float dropout : hint_range(0.0, 1.0) = 0.0;   // signal loss blocks
uniform float dirt : hint_range(0.0, 1.0) = 0.16;     // lens smudge
uniform float ir : hint_range(0.0, 1.0) = 0.0;        // night vision
uniform float ir_gain : hint_range(1.0, 6.0) = 1.0;   // sensor gain; the world
                                                      // must light the scene with
                                                      // its own IR lamp first
uniform float ir_floor : hint_range(0.0, 0.6) = 0.05;  // tube black level
uniform float ir_ceil : hint_range(0.2, 1.0) = 0.42;    // tube saturation point
uniform float flash : hint_range(0.0, 1.0) = 0.0;     // one-frame white blowout
uniform float time_scale : hint_range(0.0, 4.0) = 1.0;

// --- helpers ----------------------------------------------------------------
float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 lens_uv(vec2 uv, vec2 px) {
	// barrel distortion around the optical centre, corrected for aspect so the
	// curve stays circular on widescreen and on a phone held upright
	vec2 c = uv - 0.5;
	c.x *= px.y / max(px.x, 1e-6);
	float r2 = dot(c, c);
	vec2 bent = c * (1.0 + lens_warp * r2) / max(zoom, 0.001);
	bent.x *= px.x / max(px.y, 1e-6);
	return bent + 0.5;
}

vec3 sample_screen(vec2 uv) {
	return texture(screen_tex, clamp(uv, vec2(0.0005), vec2(0.9995))).rgb;
}

vec3 render_frame(vec2 uv_in, vec2 px, float t) {
	vec2 uv = uv_in + jitter;

	// --- tape tear: a few horizontal slices slip sideways --------------------
	if (tear > 0.001) {
		float slice = floor(uv.y * 44.0);
		float n = hash21(vec2(slice, floor(t * 14.0)));
		float wob = step(1.0 - tear * 0.65, n);
		uv.x += wob * (hash11(slice * 3.7 + floor(t * 9.0)) - 0.5) * 0.09 * tear;
	}

	vec2 wuv = lens_uv(uv, px);

	// --- chromatic aberration ------------------------------------------------
	vec3 col;
	if (quality >= 1 && ca > 0.01) {
		vec2 dir = wuv - 0.5;
		vec2 off = dir * ca * px * (1.0 + 2.0 * ir);
		col.r = sample_screen(wuv + off).r;
		col.g = sample_screen(wuv).g;
		col.b = sample_screen(wuv - off).b;
	} else {
		col = sample_screen(wuv);
	}

	// --- rolling shutter band ------------------------------------------------
	float band_pos = fract(uv.y * 0.85 - t * 0.23);
	// a soft, wide band: a hard edge reads as a UI artefact, not as tape
	float band = smoothstep(0.0, 0.38, band_pos) * smoothstep(0.75, 0.12, band_pos);
	col *= 1.0 + rolling * 0.20 * band;
	// the band drags a little colour with it, like a real rolling shutter
	if (quality >= 1 && rolling > 0.01) {
		vec2 drag = vec2(band * rolling * 0.0016, 0.0);
		col.b = mix(col.b, sample_screen(wuv + drag).b, 0.5 * band * rolling);
	}

	// ---------------------------------------------------------------------- //
	// grade: camcorder sensors crush the toe and desaturate the highlights
	// ---------------------------------------------------------------------- //
	col = max(col, 0.0) * exposure;
	float l = luma(col);
	if (debug_mode != 4) {
		// This forest is almost black: pivoting contrast around 0.5 would crush
		// every shadow to zero and leave nothing but grain. Real camcorders
		// instead run high gain at night — a gamma lift plus a shoulder, with a
		// small black floor so the tape noise sits on top of something.
		col = mix(vec3(l), col, saturation);
		col = pow(max(col, vec3(0.0)), vec3(gamma));
		col = col / (1.0 + col * shoulder);
		col += lift;
		col = mix(col * shadow_tint, col * highlight_tint, smoothstep(0.04, 0.55, l));
		col = max(col, 0.0);
	}

	// --- night vision --------------------------------------------------------
	if (ir > 0.001) {
		// Tubes are low resolution and optically soft: a cheap 5-tap blur (only
		// while the lamp is on) smooths the sensor speckle into glow instead of
		// television snow, which is what makes the picture readable at all.
		if (quality >= 1) {
			vec2 o = px * 1.35;
			vec3 soft = sample_screen(wuv) * 2.0
				+ sample_screen(wuv + vec2(o.x, 0.0))
				+ sample_screen(wuv - vec2(o.x, 0.0))
				+ sample_screen(wuv + vec2(0.0, o.y))
				+ sample_screen(wuv - vec2(0.0, o.y));
			col = mix(col, soft / 6.0, ir * 0.75);
		}
		// A night-vision tube is high gain but low latitude: whatever the IR lamp
		// catches is bright, everything beyond it falls into the noise. A soft
		// knee instead of a plain gamma keeps the ground readable (the forest is
		// genuinely dark) while still crushing what the lamp never reaches.
		float x = clamp(l * ir_gain, 0.0, 1.0);
		float mono = smoothstep(ir_floor, ir_ceil, x);
		mono = mono * 0.92 + 0.03;
		vec3 nv = vec3(mono * 0.42, mono, mono * 0.36);
		nv += vec3(0.0, 0.012, 0.004) * (1.0 - mono);      // faint tube glow
		col = mix(col, nv, ir);
	}

	// --- sensor grain, weighted towards the shadows --------------------------
	vec2 nuv = uv * vec2(px.y / max(px.x, 1e-6), 1.0);
	if (debug_mode != 3) {
	float n1 = texture(noise_tex, nuv * 2.7 + vec2(t * 0.73, -t * 0.41)).r;
	float n2 = texture(noise_tex, nuv * 7.9 - vec2(t * 0.11, t * 0.07)).g;
	float noise = (n1 - 0.5) * 1.35 + (n2 - 0.5) * 0.65;
	// amplitude follows the signal: a night-shot sensor is noisy, but the noise
	// must never be louder than the picture it sits on
	float amp = grain * (0.005 + 0.26 * l * l + 0.05 * l) * (1.0 + ir * 0.8);
	col += noise * amp;
	// chromatic noise speckle, mostly where the gain is highest
	col.rb += vec2(noise, -noise) * amp * 0.35;
	}

	// --- lens dirt: slow, static blotches ------------------------------------
	if (dirt > 0.001) {
		float d = texture(noise_tex, nuv * 0.75 + vec2(0.17, 0.61)).b;
		float blot = smoothstep(0.62, 0.92, d) * dirt;
		col = mix(col, col * 1.5 + vec3(0.012), blot);
	}

	// --- scanlines -----------------------------------------------------------
	float sl = sin(uv.y / max(px.y, 1e-6) * 1.15) * 0.5 + 0.5;
	col *= 1.0 - scanline * 0.16 * sl;
	// gentle interlace flicker
	col *= 1.0 - scanline * 0.03 * step(0.5, fract(uv.y / max(px.y, 1e-6) * 0.5));

	// --- signal loss blocks --------------------------------------------------
	if (dropout > 0.001) {
		float b = hash21(floor(uv * vec2(26.0, 40.0)) + floor(t * 11.0) * 0.37);
		float hit = step(1.0 - dropout * 0.8, b);
		vec3 trash = vec3(hash11(floor(t * 21.0) + uv.y * 90.0),
			hash11(floor(t * 17.0) + uv.x * 61.0),
			hash11(floor(t * 29.0) + uv.y * 13.0));
		col = mix(col, trash * (0.55 + 0.45 * band), hit * dropout);
		// horizontal tape burn line
		float burn = smoothstep(0.0, 0.02, abs(fract(uv.y * 1.7 - t * 0.9) - 0.5));
		col += (1.0 - burn) * dropout * vec3(0.55, 0.6, 0.7);
	}

	// --- vignette (soft, lens shaped) ---------------------------------------
	vec2 vd = (uv - 0.5) * vec2(1.06, 0.98);
	float vig = smoothstep(0.36, 0.92, length(vd));
	if (debug_mode != 5) {
		col *= 1.0 - vig * vignette;
		// darker optical corners, the tube itself
		float tube = smoothstep(0.47, 0.62, length((uv - 0.5) * vec2(1.12, 1.0)));
		col *= 1.0 - tube * 0.55 * vignette;
	}

	// --- one frame of blown out tape on a jumpscare -------------------------
	col = mix(col, col * 2.2 + vec3(0.35, 0.33, 0.32), flash);

	return col;
}

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE;
	float t = TIME * time_scale;
	if (debug_mode == 1) {
		COLOR = vec4(texture(screen_tex, SCREEN_UV).rgb, 1.0);
	} else if (debug_mode == 2) {
		COLOR = vec4(0.5, 0.5, 0.5, 1.0);
	} else {
		COLOR = vec4(render_frame(SCREEN_UV, px, t), 1.0);
	}
}
