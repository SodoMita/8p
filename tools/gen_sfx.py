#!/usr/bin/env python3
"""EIGHT PAGES — procedural horror & physical-modeling foley audio.

Every sample in assets/audio is synthesised here, from nothing, as Ogg Vorbis.

Design rule: NO lazy `filtered_noise * exp(-t)` stand-ins for physical objects.
  * Voices & screams use a 5-formant additive glottal harmonic engine with
    pitch contour, vibrato, vocal-fold jitter, pitch breaks, and subharmonics.
  * Solid foley (forest footsteps on dead leaves/twigs, flagstone boots, paper
    tears/creases, snapping branches, mechanical switch clicks) uses damped
    modal resonator banks (beam/plate/shell eigenfrequencies) excited by
    discrete Poisson micro-fracture & slip-stick impulse cascades.
  * Wind uses sweeping high-Q Aeolian vortex-whistle resonances tied to gust
    velocity; breathing uses narrow tracheal formants + a faint voiced sigh;
    wire hum uses 50 Hz magnetostriction harmonics + AC-peak-locked plasma arcs;
    even VHS static layers 60 Hz sync buzz, carrier heterodynes, and tracking
    dropouts rather than stationary Gaussian hiss.

    python3 tools/gen_sfx.py            # writes assets/audio/*.ogg
"""
import math
import os

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt, fftconvolve

SR = 22050
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO = os.path.join(ROOT, "assets", "audio")


# --------------------------------------------------------------------------- #
# basic dsp & physical-modeling primitives
# --------------------------------------------------------------------------- #
def lp(x, cutoff, order=2, sr=SR):
    return sosfilt(butter(order, min(0.99, cutoff / (sr / 2)), btype="low", output="sos"), x)


def hp(x, cutoff, order=2, sr=SR):
    return sosfilt(butter(order, min(0.99, cutoff / (sr / 2)), btype="high", output="sos"), x)


def bp(x, lo, hi, order=2, sr=SR):
    lo_n = max(1e-4, min(0.95, lo / (sr / 2)))
    hi_n = max(lo_n + 1e-3, min(0.99, hi / (sr / 2)))
    sos = butter(order, [lo_n, hi_n], btype="band", output="sos")
    return sosfilt(sos, x)


def noise(n, rng, sr=SR):
    return rng.normal(0, 1, n).astype(np.float32)


def smooth_noise(n, rng, cutoff=6.0, sr=SR):
    """Band-limited random contour in [-1, 1]."""
    k = max(4, int(sr / cutoff))
    m = n // k + 3
    w = rng.normal(0, 1, m).astype(np.float32)
    idx = np.arange(m) * k
    out = np.interp(np.arange(n), idx, w)[:n].astype(np.float32)
    med = np.median(out)
    return (out - med) / (np.max(np.abs(out - med)) + 1e-9)


def modal_ping(n, modes, sr=SR, bend=0.0):
    """Sum of damped physical eigenmodes: modes = [(freq_hz, decay_s_inv, amp, phase), ...]."""
    t = np.arange(n, dtype=np.float64) / sr
    y = np.zeros(n, dtype=np.float64)
    for f, dec, amp, ph in modes:
        if f >= sr * 0.47 or f < 18.0:
            continue
        if abs(bend) > 1e-6:
            f_inst = f * (1.0 + bend * np.exp(-t * dec * 0.7))
            phase = 2.0 * math.pi * np.cumsum(f_inst) / sr + ph
        else:
            phase = 2.0 * math.pi * f * t + ph
        y += amp * np.sin(phase) * np.exp(-t * dec)
    return y.astype(np.float32)


def add_at(dst, src, idx, gain=1.0):
    if idx < 0:
        src = src[-idx:]
        idx = 0
    if idx >= len(dst) or len(src) == 0:
        return
    ln = min(len(src), len(dst) - idx)
    dst[idx:idx + ln] += src[:ln] * gain


def resonator(x, freq, bw, sr=SR):
    """Time-varying 2-pole resonator, unity gain at centre."""
    n = len(x)
    freq = np.full(n, freq, dtype=np.float64) if np.isscalar(freq) else np.asarray(freq, float)
    bw = np.full(n, bw, dtype=np.float64) if np.isscalar(bw) else np.asarray(bw, float)
    freq = np.clip(freq, 30.0, sr * 0.45)
    bw = np.clip(bw, 12.0, sr * 0.4)
    r = np.exp(-np.pi * bw / sr)
    th = 2.0 * np.pi * freq / sr
    a1 = 2.0 * r * np.cos(th)
    a2 = -(r * r)
    g = (1.0 - r) * np.sqrt(1.0 - 2.0 * r * np.cos(2.0 * th) + r * r)
    y = np.zeros(n)
    x = np.asarray(x, float)
    y1 = y2 = 0.0
    for i in range(n):
        v = g[i] * x[i] + a1[i] * y1 + a2[i] * y2
        y2, y1 = y1, v
        y[i] = v
    return y.astype(np.float32)


def res_mag(f, F, B):
    return 1.0 / np.sqrt(1.0 + ((f * f - F * F) / (f * B + 1e-9)) ** 2)


def env_ad(n, attack, release, sr=SR, hold=1.0):
    t = np.arange(n) / sr
    dur = n / sr
    e = np.clip(t / max(attack, 1e-4), 0, 1) ** 0.8
    e *= np.clip((dur - t) / max(release, 1e-4), 0, 1) ** 1.2
    return e * hold


def normalise(x, peak=1.0):
    m = np.max(np.abs(x)) + 1e-9
    return (x / m * peak).astype(np.float32)


# --------------------------------------------------------------------------- #
# the voice (additive 5-formant harmonic stack)
# --------------------------------------------------------------------------- #
def vocal(dur, f0_shape, sr=SR, seed=0, formant_scale=1.0, amps=(1.0, 0.84, 0.60, 0.38, 0.20),
          bw=(115, 155, 210, 260, 330), rough=0.45, breath=0.35, sub=0.35,
          tilt=4300.0, fmax=6800.0, jitter=0.018, vibrato=(5.3, 0.030, 0.018),
          crack_at=None, crack_depth=0.0, tear_at=None, attack=0.03, release=0.30,
          vowel_shift=1.0, drive=1.15):
    """One voice. f0_shape(t, dur) -> array of Hz."""
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    N = n

    f0 = np.asarray(f0_shape(t, dur), dtype=np.float64)
    f0 = np.clip(f0, 60.0, 1600.0)
    rate, depth, vib = vibrato
    f0 = f0 * (1.0 + depth * np.sin(2 * np.pi * (rate + 1.4 * t) * t)
               + vib * smooth_noise(N, rng, 11.0, sr))
    f0 = f0 * (1.0 + jitter * smooth_noise(N, rng, 85.0, sr))
    if crack_at is not None and crack_depth > 0:
        c = np.zeros(N)
        i0 = int(crack_at * dur * sr)
        i1 = min(N, i0 + int(0.14 * sr))
        c[i0:i1] = crack_depth
        c = np.convolve(c, np.hanning(int(0.05 * sr)), mode="same")
        f0 = f0 * (1.0 - c)

    a = np.clip(t / dur, 0, 1)
    F = np.stack([
        (860 - 170 * a * vowel_shift),
        (1500 - 330 * a * vowel_shift),
        (2820 - 280 * a * vowel_shift),
        (3720 - 220 * a * vowel_shift),
        (4650 - 320 * a * vowel_shift),
    ]) * formant_scale
    B = np.array(bw, dtype=float)[:, None] * np.ones(N)

    f0c = np.clip(f0, 55.0, sr * 0.42)
    K = int(math.ceil(fmax / max(30.0, f0c.min())))
    ph = np.cumsum(f0c) / sr
    out = np.zeros(N)
    for k in range(1, K + 1):
        fk = k * f0c
        E = np.zeros(N)
        for i in range(5):
            E += amps[i] * res_mag(fk, F[i], B[i])
        E /= (1.0 + (fk / tilt) ** 2)
        E *= (fk < sr * 0.45)
        out += E * np.sin(2 * np.pi * k * ph + rng.uniform(0, 2 * np.pi))

    if sub > 0:
        g = np.clip((t - dur * 0.30) / (dur * 0.55), 0, 1)
        out += sub * 0.65 * g * np.sin(2 * np.pi * 0.5 * ph + 0.7)
        out += sub * 0.28 * g * np.sin(2 * np.pi * 1.5 * ph + 1.9)

    # vocal-fold fry / subglottal roughness
    r1 = smooth_noise(N, rng, 23.0, sr)
    r2 = smooth_noise(N, rng, 41.0, sr)
    am = 1.0 - rough * 0.48 * np.clip(0.55 * r1 + 0.30 * r2, -1.0, 1.0)
    out *= lp(am, 90.0)

    # subtle formant-locked glottal aspiration (kept strictly below harmonic tone)
    if breath > 0:
        nz = noise(N, rng)
        nzr = (resonator(nz, F[0] * 1.05, 150.0, sr) * 0.45
               + resonator(nz, F[1] * 1.02, 190.0, sr) * 0.40
               + resonator(nz, F[2], 260.0, sr) * 0.32)
        out = out + breath * nzr * 0.065 * lp(am, 60.0)

    if tear_at is not None:
        # brief glottal diplophonia / subharmonic tear instead of broadband white noise
        gp = np.ones(N)
        i0 = int(tear_at * dur * sr)
        for off in (0.0, 0.036, 0.074):
            j0 = min(N - 1, i0 + int(off * sr))
            j1 = min(N, j0 + int(0.020 * sr))
            gp[j0:j1] *= 0.24
        gp = np.convolve(gp, np.hanning(int(0.008 * sr)), mode="same")
        sub_tear = np.sin(2 * np.pi * 0.333 * ph) + 0.6 * np.sin(2 * np.pi * 0.667 * ph)
        out = out * gp + sub_tear * (1.0 - gp) * 0.45

    out = np.tanh(out * drive)
    out = hp(out, 90.0)
    out = out + 0.30 * bp(out, 2000.0, 5200.0)
    out *= env_ad(N, attack, release, sr)
    return normalise(out)


def pitch_arc(f_start, f_peak, f_end, rise=0.09, fall=0.62):
    def shape(t, dur):
        r = np.clip(t / rise, 0, 1) ** 0.55
        f = np.clip((t - dur * fall) / (dur * (1 - fall)), 0, 1) ** 1.7
        return f_start + (f_peak - f_start) * r + (f_end - f_peak) * f
    return shape


# --------------------------------------------------------------------------- #
# physical & tonal horror layers (no broadband noise washes)
# --------------------------------------------------------------------------- #
def shriek(dur=0.9, f_lo=1900.0, f_hi=4200.0, seed=5, sr=SR):
    """Inharmonic bowed/torn steel plate partials (pure FM + modal ratios, no white hiss)."""
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    sweep = f_lo + (f_hi - f_lo) * (1 - np.exp(-t * 15.0))
    mod = np.sin(2 * np.pi * (131.0 + 37.0 * t) * t) * (3.8 * np.exp(-t * 1.3) + 0.7)
    # Inharmonic Chladni plate ratios: 1.00, 1.59, 2.14, 2.65, 3.41
    car = np.zeros(n, dtype=np.float64)
    for ratio, amp in [(1.00, 1.0), (1.59, 0.68), (2.14, 0.48), (2.65, 0.32), (3.41, 0.20)]:
        f_inst = np.clip(sweep * ratio, 40.0, sr * 0.45)
        mask = (sweep * ratio < sr * 0.44).astype(np.float64)
        car += amp * mask * np.sin(2 * np.pi * np.cumsum(f_inst) / sr + mod * (1.8 / ratio) + rng.uniform(0, 6.28))
    x = np.tanh(car * 1.35)
    x *= np.exp(-t * 3.4) * np.clip(t / 0.012, 0, 1)
    return normalise(x)


def sub_impact(dur=1.2, seed=3, sr=SR, f_top=130.0, f_bot=24.0):
    """Deep chest-cavity / drumhead modal impact without sustained noise tail."""
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    f = f_bot + (f_top - f_bot) * np.exp(-t * 8.5)
    ph = 2 * np.pi * np.cumsum(f) / sr
    body = np.sin(ph) * np.exp(-t * 3.0)
    body += 0.38 * np.sin(ph * 1.59) * np.exp(-t * 6.2)   # circular membrane (0,1)->(1,1) mode
    body += 0.22 * np.sin(ph * 2.14 + 0.8) * np.exp(-t * 9.5)
    body += 0.14 * np.sin(ph * 2.65 + 1.7) * np.exp(-t * 14.0)
    # 3 ms transient mallet snap (modal, not noise wash)
    snap = modal_ping(n, [
        (380.0, 95.0, 0.35, rng.uniform(0, 6.28)),
        (820.0, 150.0, 0.24, rng.uniform(0, 6.28)),
        (1640.0, 240.0, 0.16, rng.uniform(0, 6.28)),
    ], sr, bend=-0.18)
    x = np.tanh((body + snap) * 1.35)
    return normalise(x)


def riser(dur=0.42, seed=11, sr=SR, f0=220.0, f1=2800.0, shape=2.4):
    """Bowed dissonant waterphone / string-glissando riser (harmonic cluster, not noise)."""
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    u = t / dur
    y = np.zeros(n, dtype=np.float64)
    # 6 diverging microtonal / tritone rods gliding upward
    ratios = [1.0, 1.059, 1.414, 1.500, 2.118, 2.828]
    for k, r in enumerate(ratios):
        f_curve = np.clip((f0 * r) * ((f1 / f0) ** (u ** (0.85 + 0.08 * k))), 40.0, sr * 0.44)
        trem = 0.72 + 0.28 * np.sin(2 * np.pi * (9.0 + 2.3 * k) * t + rng.uniform(0, 6.28))
        y += (0.85 ** k) * trem * np.sin(2 * np.pi * np.cumsum(f_curve) / sr + rng.uniform(0, 6.28))
    y *= (u ** shape) * np.clip((dur - t) / 0.015, 0, 1)
    return normalise(y)


def gasp(dur=0.5, seed=21, sr=SR):
    """Sharp human vocal-tract inhale: narrow tracheal formants + soft laryngeal wheeze."""
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    a = t / dur
    one = np.ones(n)
    # Narrow open-throat / tracheal resonances (high Q so it sounds tubular, not white hiss)
    F = np.stack([560 + 210 * (1 - a), 1380 - 260 * a, 2480 - 220 * a, 3520 * one])
    B = np.stack([85 + 55 * a, 115 + 70 * a, 165 * one, 230 * one])
    nz = noise(n, rng)
    y = np.zeros(n, dtype=np.float32)
    for i in range(4):
        y += (1.0 - 0.22 * i) * resonator(nz, F[i], B[i], sr)
    # Faint involuntary vocal-cord wheeze during fast intake of breath
    f_wheeze = 255.0 + 75.0 * np.sin(math.pi * a) - 45.0 * a
    ph_w = 2 * np.pi * np.cumsum(f_wheeze) / sr
    wheeze = (0.38 * np.sin(ph_w) + 0.22 * np.sin(2 * ph_w + 0.6) + 0.11 * np.sin(3 * ph_w + 1.4))
    y = y * 0.68 + wheeze.astype(np.float32) * 0.34
    y *= np.clip(t / 0.035, 0, 1) ** 0.85 * np.clip((dur - t) / 0.16, 0, 1) ** 0.9
    y = hp(y, 170.0)
    return normalise(y)


def whisper(dur=2.2, seed=31, sr=SR, syllables=6):
    """Articulated whispered syllables: narrow vowel formants + alveolar/plosive consonants."""
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    vowels = [(710, 1120, 2460), (290, 2240, 2960), (320, 880, 2260),
              (520, 1820, 2490), (580, 860, 2410), (650, 1690, 2430)]
    order = rng.integers(0, len(vowels), syllables)
    F1 = np.zeros(n); F2 = np.zeros(n); F3 = np.zeros(n)
    amp = np.zeros(n)
    seg = dur / syllables
    for i, v in enumerate(order):
        i0, i1 = int(i * seg * sr), min(n, int((i + 1) * seg * sr))
        k = i1 - i0
        if k <= 0:
            continue
        ramp = np.ones(k)
        hold = max(2, int(k * 0.20))
        tail = max(2, int(k * 0.44))
        ramp[:hold] = np.linspace(0, 1, hold) ** 0.6
        ramp[-tail:] *= np.linspace(1, 0, tail) ** 0.9
        F1[i0:i1] = vowels[v][0]; F2[i0:i1] = vowels[v][1]; F3[i0:i1] = vowels[v][2]
        amp[i0:i1] = ramp * rng.uniform(0.60, 1.0)
    for arr in (F1, F2, F3):
        arr[:] = np.convolve(arr, np.ones(360) / 360, mode="same")
    nz = noise(n, rng)
    # Tight vowel bandwidths (70-140 Hz) + faint phantom undertows so vowels read as words
    y = (resonator(nz, np.maximum(180, F1), 72, sr) * 1.0
         + resonator(nz, np.maximum(450, F2), 105, sr) * 0.82
         + resonator(nz, np.maximum(1400, F3), 145, sr) * 0.50)
    t = np.arange(n) / sr
    undertone = 0.14 * np.sin(2 * np.pi * (108.0 + 9.0 * np.sin(2 * np.pi * 1.3 * t)) * t)
    undertone += 0.09 * np.sin(2 * np.pi * 216.0 * t + 0.8)
    y = (y + undertone.astype(np.float32)) * amp
    # Crisp tongue/lip consonant clicks at syllable onsets
    for i in range(syllables):
        i0 = int(i * seg * sr) - int(0.010 * sr)
        if 0 < i0 < n - 300:
            cons = modal_ping(260, [
                (1850 + 240 * (i % 3), 260.0, 0.45, 0.0),
                (3400 + 380 * (i % 2), 340.0, 0.35, 1.1),
                (4950, 420.0, 0.25, 2.3),
            ], sr)
            add_at(y, cons, i0, 0.55)
    y = hp(lp(y, 6200.0), 220.0)
    return normalise(y)


# --------------------------------------------------------------------------- #
# space + mixing (multi-tap early reflections + modal FDN-style room tail)
# --------------------------------------------------------------------------- #
def reverb_ir(dur=1.8, decay=0.62, seed=13, sr=SR, tilt=3000.0, predelay=0.012):
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    ir = np.zeros(n, dtype=np.float32)
    # Dense Velvet-noise sparse reflection train (avoids flat Gaussian hiss coloration)
    grid = max(6, int(sr / 1850))
    for g_idx in range(int(predelay * sr), n, grid):
        j = min(n - 1, g_idx + int(rng.integers(0, grid)))
        sign = 1.0 if rng.random() > 0.5 else -1.0
        ir[j] = sign * math.exp(-t[j] / decay) * rng.uniform(0.5, 1.0)
    ir = hp(lp(ir, tilt), 150.0)
    for d, g in [(0.011, 0.58), (0.019, -0.44), (0.031, 0.36), (0.047, -0.28), (0.067, 0.21)]:
        i = int((d + predelay) * sr)
        if i < n:
            ir[i] += g
    ir[: int(predelay * sr)] = 0.0
    return normalise(ir)


def reverb(x, wet=0.4, dur=1.8, decay=0.62, seed=13, sr=SR):
    ir = reverb_ir(dur, decay, seed, sr)
    w = fftconvolve(x, ir)[: len(x) + int(0.06 * sr)]
    w = normalise(w, np.max(np.abs(x)) + 1e-9)
    out = np.zeros(len(w), dtype=np.float32)
    out[: len(x)] += x * (1.0 - wet)
    out += w * wet
    return out


def place(dst, src, at, gain=1.0, sr=SR):
    i = int(at * sr)
    if i >= len(dst):
        return dst
    ln = min(len(src), len(dst) - i)
    dst[i:i + ln] += src[:ln] * gain
    return dst


def fade(x, a=0.003, b=0.05, sr=SR):
    n = len(x)
    na, nb = int(a * sr), int(b * sr)
    if na:
        x[:na] *= np.linspace(0, 1, na) ** 1.5
    if nb:
        x[-nb:] *= np.linspace(1, 0, nb) ** 1.5
    return x


def limit(x, drive=1.0, peak=0.97):
    x = np.tanh(x * drive)
    return normalise(x, peak)


def crossfade_loop(x, sr=SR, fade_s=1.5):
    n = int(fade_s * sr)
    if n * 2 >= len(x):
        return x
    head = x[:n].copy()
    tail = x[-n:].copy()
    ramp = np.linspace(0, 1, n, dtype=np.float32)
    y = x[:-n].copy()
    y[:n] = tail * (1 - ramp) + head * ramp
    return y


def write_ogg(path, data, sr=SR):
    data = np.clip(np.asarray(data, dtype=np.float32), -1, 1)
    if data.ndim == 2 and data.shape[1] == 1:
        data = data[:, 0]
    sf.write(path, data, sr, format="OGG", subtype="VORBIS", compression_level=0.25)
    ch = 1 if data.ndim == 1 else data.shape[1]
    print("  %-22s %5.2fs %d ch" % (os.path.basename(path), len(data) / sr, ch))


# --------------------------------------------------------------------------- #
# ambient beds (Aeolian wind, pure tonal minor-2nd drone, VHS static, heartbeat, wire hum)
# --------------------------------------------------------------------------- #
def bed_wind(sr=SR, seed=1):
    """Cold night wind singing through bare branches: sweeping Aeolian vortex whistles."""
    rng = np.random.default_rng(seed)
    n = sr * 10
    t = np.arange(n) / sr
    # Smooth gust contour locked to the 10s cycle
    gust = (0.50 + 0.30 * np.sin(2 * math.pi * t / 10.0 + 0.3)
            + 0.18 * np.sin(2 * math.pi * 2.0 * t / 10.0 + 1.4)
            + 0.10 * np.sin(2 * math.pi * 3.0 * t / 10.0 + 2.5))
    gust = np.clip(gust, 0.15, 1.15)

    # Aeolian Strouhal tones (f ~ 0.2 * U / d) for 3 branch diameters -> hollow whistling wind
    src = noise(n, rng)
    w1 = resonator(src, 165.0 + 145.0 * gust, 28.0 + 18.0 * gust, sr) * 0.95
    w2 = resonator(src, 340.0 + 260.0 * gust, 38.0 + 26.0 * gust, sr) * 0.62
    w3 = resonator(src, 610.0 + 390.0 * (gust ** 1.3), 55.0 + 35.0 * gust, sr) * 0.32
    # Deep low-frequency canopy pressure (< 105 Hz)
    sub_air = lp(noise(n, rng), 95.0) * (0.45 + 0.55 * gust) * 0.85

    # Faint distant dry-twig ticks during peak gusts
    twigs = np.zeros(n, dtype=np.float32)
    for _ in range(18):
        idx = int(rng.integers(0, n - 900))
        if gust[idx] < 0.62:
            continue
        f0 = rng.uniform(520.0, 1250.0)
        ping = modal_ping(750, [
            (f0, 140.0, 0.35, 0.0),
            (f0 * 2.71, 220.0, 0.22, 1.2),
            (f0 * 4.95, 310.0, 0.12, 2.4),
        ], sr)
        add_at(twigs, ping, idx, rng.uniform(0.06, 0.14))

    wind = (w1 + w2 + w3) * (0.45 + 0.65 * gust) + sub_air + twigs
    wind = normalise(wind, 0.55)
    return crossfade_loop(wind, sr, 1.5)


def bed_drone(sr=SR, seed=2):
    """Pure bowed dark sub-harmonic & minor-second pipe/string dread (zero noise wash)."""
    n = sr * 16
    t = np.arange(n) / sr
    drone = np.zeros(n, dtype=np.float64)
    # 41.0 Hz (E1) & 43.65 Hz (F1) minor-second beating + bowed harmonic overtones
    partials = [
        (41.00, 0.52, 0.0, 0.0625),
        (43.65, 0.34, 1.1, 0.0625),
        (61.50, 0.28, 2.2, 0.125),
        (82.00, 0.22, 0.4, 0.125),
        (87.31, 0.14, 1.9, 0.1875),
        (123.00, 0.11, 1.7, 0.125),
        (130.81, 0.08, 2.6, 0.25),
        (164.00, 0.05, 2.9, 0.1875),
        (184.99, 0.04, 0.8, 0.25),
        (246.94, 0.025, 1.5, 0.3125),
    ]
    for f, a, ph, swell_hz in partials:
        swell = 0.62 + 0.38 * np.sin(2 * math.pi * swell_hz * t + ph * 0.7)
        pm = 0.45 * np.sin(2 * math.pi * 0.0625 * t + ph)
        drone += a * swell * np.sin(2 * math.pi * f * t + pm + ph)
    drone = np.tanh(drone * 1.28)
    drone = normalise(drone.astype(np.float32), 0.42)
    return crossfade_loop(drone, sr, 2.0)


def bed_static(sr=SR, seed=3):
    """Damaged analog camcorder / VHS tape tracking tear + 60 Hz CRT sync + RF whistle."""
    rng = np.random.default_rng(seed)
    n = sr * 3
    t = np.arange(n) / sr
    # 1) 60 Hz CRT vertical-sync buzz + clipped harmonics (pulsing with frame tear)
    sync = np.zeros(n, dtype=np.float64)
    for k in range(1, 12):
        sync += (0.70 ** k) * np.sin(2 * math.pi * 60.0 * k * t + 0.3 * k)
    sync = np.tanh(sync * 2.0) * (0.35 + 0.65 * (np.sin(2 * math.pi * 4.0 * t) ** 2))

    # 2) Unstable tape-flutter RF heterodyne whistles (~2.9 kHz & ~5.85 kHz)
    wow = np.sin(2 * math.pi * 4.0 * t) * 0.028 + smooth_noise(n, rng, 18.0, sr) * 0.04
    rf1 = np.sin(2 * math.pi * np.cumsum(2920.0 * (1.0 + wow)) / sr) * 0.13
    rf2 = np.sin(2 * math.pi * np.cumsum(5840.0 * (1.0 - 0.8 * wow)) / sr) * 0.08

    # 3) Choppy VHS head-switching & magnetic tape tracking tear (gated, swept, crackling)
    gate = np.clip(0.18 + 0.95 * smooth_noise(n, rng, 42.0, sr), 0.02, 1.0) ** 2.1
    raw = noise(n, rng)
    sweep_f = 1950.0 + 1250.0 * smooth_noise(n, rng, 26.0, sr)
    scan_tear = resonator(raw, sweep_f, 520.0, sr) * 0.75 + hp(raw, 2600.0) * 0.32
    arc_pops = np.zeros(n, dtype=np.float32)
    for _ in range(58):
        idx = int(rng.integers(0, n - 240))
        pop = modal_ping(200, [
            (rng.uniform(1300, 3200), 210.0, 0.75, 0.0),
            (rng.uniform(3600, 7200), 310.0, 0.55, 1.3),
        ], sr)
        add_at(arc_pops, pop, idx, rng.uniform(0.40, 0.95))

    out = sync.astype(np.float32) * 0.24 + (rf1 + rf2).astype(np.float32) + scan_tear * gate * 0.78 + arc_pops * 0.52
    out = normalise(np.tanh(out * 1.45), 0.80)
    return crossfade_loop(out, sr, 0.5)


def bed_heartbeat(sr=SR, seed=4):
    """Two visceral lub-dub cardiac valve thumps (pure membrane/blood-column modes)."""
    n = sr * 2
    beat = np.zeros(n, dtype=np.float32)
    for start, amp, pitch in [(0.02, 1.0, 48.0), (0.315, 0.62, 43.0)]:
        i0 = int(start * sr)
        ln = min(int(0.30 * sr), n - i0)
        tt = np.arange(ln) / sr
        f_inst = pitch + 26.0 * np.exp(-tt * 28.0)
        ph = 2 * math.pi * np.cumsum(f_inst) / sr
        thump = np.sin(ph) * np.exp(-tt * 14.0)
        thump += 0.38 * np.sin(ph * 1.82 + 0.4) * np.exp(-tt * 24.0)
        thump += 0.22 * np.sin(2 * math.pi * 27.5 * tt) * np.exp(-tt * 26.0)
        beat[i0:i0 + ln] += (np.tanh(thump * 1.25) * amp).astype(np.float32)[:ln]
    beat = lp(beat, 260)
    return normalise(beat, 0.85)


def bed_wire_hum(sr=SR, seed=10):
    """50 Hz transformer magnetostriction buzz + AC-peak-locked porcelain corona arcs."""
    rng = np.random.default_rng(seed)
    n = int(sr * 5.2)
    t = np.arange(n) / sr
    hum = np.zeros(n, dtype=np.float64)
    for f, a, ph in [(50.0, 0.34, 0.0), (100.0, 0.46, 0.7), (150.0, 0.30, 1.5),
                     (200.0, 0.16, 2.1), (250.0, 0.13, 0.3), (300.0, 0.18, 1.9),
                     (400.0, 0.07, 1.1), (500.0, 0.06, 2.4), (600.0, 0.04, 0.9)]:
        wob = 1.0 + 0.15 * np.sin(2 * math.pi * (0.20 + 0.04 * (f / 100.0)) * t + ph)
        hum += a * wob * np.sin(2 * math.pi * f * t + ph)

    # Real AC corona physics: micro-discharges fire near |sin(2*pi*50*t)| > 0.88 peaks
    arcs = np.zeros(n, dtype=np.float32)
    ac_mag = np.abs(np.sin(2 * math.pi * 50.0 * t))
    for window_start, window_len in [(0.58, 0.18), (1.74, 0.14), (2.92, 0.22), (3.86, 0.15)]:
        i0 = int(window_start * sr)
        i1 = min(n - 180, int((window_start + window_len) * sr))
        peak_idxs = np.nonzero(ac_mag[i0:i1] > 0.90)[0] + i0
        if len(peak_idxs) == 0:
            continue
        chosen = rng.choice(peak_idxs, size=min(len(peak_idxs), int(rng.integers(10, 22))), replace=False)
        for idx in chosen:
            f_arc = rng.uniform(2150.0, 3400.0)
            spark = modal_ping(160, [
                (f_arc, 340.0, 0.65, 0.0),
                (f_arc * 1.53, 440.0, 0.48, 0.9),
                (f_arc * 2.18, 560.0, 0.32, 2.1),
            ], sr, bend=-0.12)
            add_at(arcs, spark, int(idx), rng.uniform(0.18, 0.42))

    out = normalise(hum.astype(np.float32) * 0.62 + arcs, 0.65)
    return crossfade_loop(out, sr, 0.7)


# --------------------------------------------------------------------------- #
# physical-modeling foley (leaves, twigs, stone boots, paper tear, branch, switch)
# --------------------------------------------------------------------------- #
def foley_steps(sr=SR, seed=5):
    """Forest footsteps: damped soil thud + discrete dry-leaf crinkles & twig snaps."""
    rng = np.random.default_rng(seed)
    out = []
    for i in range(4):
        n = int(sr * 0.34)
        s = np.zeros(n, dtype=np.float32)
        # 1) Heel soil compression (0 ms) + boot leather flex
        heel = modal_ping(n, [
            (66.0 - i * 4.5, 32.0, 0.85, 0.0),
            (124.0 + i * 7.0, 48.0, 0.42, 0.6),
            (215.0 - i * 9.0, 72.0, 0.24, 1.3),
        ], sr, bend=-0.26)
        add_at(s, heel, 0, 1.0)

        # 2) Toe-off earth roll (54-68 ms)
        toe_at = int((0.054 + 0.004 * i) * sr)
        toe = modal_ping(n - toe_at, [
            (54.0 + i * 3.0, 38.0, 0.48, 0.2),
            (142.0 - i * 5.0, 66.0, 0.22, 1.1),
        ], sr, bend=-0.18)
        add_at(s, toe, toe_at, 0.85)

        # 3) 22 discrete dry-leaf / pine-needle buckling micro-events (NOT continuous white noise!)
        n_leaves = 20 + i * 2
        for k in range(n_leaves):
            # Cluster around heel impact (4-48 ms) and toe roll (55-135 ms)
            if k < n_leaves * 0.58:
                at_s = rng.beta(1.5, 4.2) * 0.065 + 0.002
            else:
                at_s = 0.052 + rng.beta(1.6, 3.4) * 0.115
            idx = int(at_s * sr)
            f_leaf = rng.uniform(980.0, 2950.0)
            plen = int(rng.uniform(0.004, 0.011) * sr)
            crinkle = modal_ping(plen, [
                (f_leaf, rng.uniform(340.0, 620.0), 0.70, rng.uniform(0, 6.28)),
                (f_leaf * rng.uniform(1.48, 1.82), rng.uniform(440.0, 760.0), 0.52, rng.uniform(0, 6.28)),
                (min(sr * 0.44, f_leaf * rng.uniform(2.25, 2.95)), rng.uniform(550.0, 920.0), 0.34, rng.uniform(0, 6.28)),
            ], sr, bend=rng.uniform(-0.14, 0.14))
            add_at(s, crinkle, idx, rng.uniform(0.16, 0.42))

        # 4) 1-2 tiny dry-twig snaps under the sole (Euler-Bernoulli wood modes)
        for tw in range(1 + (i % 2)):
            idx = int(rng.uniform(0.012, 0.088) * sr)
            f_tw = rng.uniform(460.0, 860.0)
            twig = modal_ping(int(0.028 * sr), [
                (f_tw, 155.0, 0.55, 0.0),
                (f_tw * 2.76, 240.0, 0.38, 0.8),
                (min(sr * 0.44, f_tw * 5.40), 340.0, 0.22, 1.9),
            ], sr, bend=-0.08)
            add_at(s, twig, idx, rng.uniform(0.22, 0.38))

        s = fade(np.tanh(s * 1.25), 0.0015, 0.035, sr)
        out.append(normalise(s, 0.58))
    return out


def foley_stone_steps(sr=SR, seed=9):
    """Hard rubber/leather boot on cold labyrinth flagstone: slab/sole modes + discrete grit."""
    rng = np.random.default_rng(seed)
    out = []
    for i in range(4):
        n = int(sr * 0.28)
        s = np.zeros(n, dtype=np.float32)
        p_shift = 1.0 + (i - 1.5) * 0.055

        # 1) Hard heel impact on flagstone (0 ms): stone slab + hollow boot heel modes
        heel = modal_ping(n, [
            (98.0 * p_shift, 46.0, 0.72, 0.0),
            (196.0 * p_shift, 68.0, 0.54, 0.4),
            (372.0 * p_shift, 95.0, 0.46, 1.1),
            (745.0 * p_shift, 135.0, 0.42, 1.9),
            (1460.0 * p_shift, 185.0, 0.36, 0.7),
            (2580.0 * p_shift, 250.0, 0.28, 2.3),
            (3840.0 * p_shift, 330.0, 0.18, 1.5),
        ], sr, bend=-0.10)
        # Sub-2ms leather/stone contact transient
        heel[:42] += np.hanning(42).astype(np.float32) * 0.55
        add_at(s, heel, 0, 1.0)

        # 2) Forefoot sole slap (44-58 ms later)
        d0 = int((0.044 + 0.0045 * i) * sr)
        sole = modal_ping(n - d0, [
            (138.0 * p_shift, 58.0, 0.45, 0.2),
            (315.0 * p_shift, 88.0, 0.42, 1.0),
            (685.0 * p_shift, 128.0, 0.38, 2.1),
            (1620.0 * p_shift, 195.0, 0.32, 0.5),
            (2940.0 * p_shift, 275.0, 0.22, 1.8),
        ], sr, bend=-0.06)
        sole[:32] += np.hanning(32).astype(np.float32) * 0.38
        add_at(s, sole, d0, 0.86)

        # 3) 8 discrete sand/grit grains crushing between rubber sole and stone
        for _ in range(8):
            idx = int(rng.uniform(0.004, 0.085) * sr)
            fg = rng.uniform(2400.0, 4600.0)
            grain = modal_ping(95, [
                (fg, 480.0, 0.55, rng.uniform(0, 6.28)),
                (min(sr * 0.44, fg * 1.47), 620.0, 0.38, rng.uniform(0, 6.28)),
            ], sr)
            add_at(s, grain, idx, rng.uniform(0.10, 0.24))

        s = fade(np.tanh(s * 1.3), 0.001, 0.035, sr)
        out.append(normalise(s, 0.64))
    return out


def foley_page(sr=SR, seed=6):
    """Tearing & folding a stiff parchment page off a landmark + eerie breath behind you."""
    rng = np.random.default_rng(seed)
    n = int(sr * 1.3)
    s = np.zeros(n, dtype=np.float32)

    # 1) Pin release & taut paper sheet snap (t = 0.025 s)
    snap = modal_ping(int(0.18 * sr), [
        (158.0, 26.0, 0.52, 0.0),
        (264.0, 34.0, 0.46, 0.8),
        (435.0, 48.0, 0.38, 1.7),
        (740.0, 68.0, 0.30, 2.4),
        (1280.0, 105.0, 0.24, 0.5),
    ], sr, bend=0.16)
    add_at(s, snap, int(0.025 * sr), 0.72)

    # 2) Fiber-tear zipper cascade (t = 0.045 .. 0.235 s): accelerating cellulose fiber snaps
    t_cur = 0.045
    step_idx = 0
    while t_cur < 0.235:
        prog = (t_cur - 0.045) / 0.190
        f_sheet = 780.0 + 1950.0 * (prog ** 1.2) + rng.uniform(-90.0, 90.0)
        fib = modal_ping(int(0.009 * sr), [
            (f_sheet, 360.0, 0.65, rng.uniform(0, 6.28)),
            (f_sheet * 1.63, 470.0, 0.48, rng.uniform(0, 6.28)),
            (min(sr * 0.44, f_sheet * 2.52), 620.0, 0.32, rng.uniform(0, 6.28)),
        ], sr, bend=0.10)
        env_w = math.sin(math.pi * prog) ** 0.7
        add_at(s, fib, int(t_cur * sr), env_w * rng.uniform(0.24, 0.48))
        t_cur += rng.uniform(0.0022, 0.0058) * (1.15 - 0.45 * prog)
        step_idx += 1

    # 3) Three crisp parchment fold / crinkle clusters as you pull the note up to read
    for cluster_t, c_gain, n_cr in [(0.27, 0.85, 13), (0.43, 0.62, 10), (0.61, 0.38, 7)]:
        for _ in range(n_cr):
            at_s = cluster_t + rng.normal(0.0, 0.026)
            idx = max(0, int(at_s * sr))
            fc = rng.uniform(620.0, 2450.0)
            cr = modal_ping(int(0.012 * sr), [
                (fc, 280.0, 0.62, rng.uniform(0, 6.28)),
                (fc * 1.74, 390.0, 0.46, rng.uniform(0, 6.28)),
                (min(sr * 0.44, fc * 2.88), 520.0, 0.30, rng.uniform(0, 6.28)),
            ], sr, bend=rng.uniform(-0.16, 0.18))
            add_at(s, cr, idx, c_gain * rng.uniform(0.18, 0.38))

    # 4) Quiet human throat breath right behind your ear (t = 0.42 s)
    inh = gasp(0.55, seed + 1, sr) * 0.28
    add_at(s, inh, int(0.42 * sr), 1.0)

    s = fade(np.tanh(s * 1.25), 0.003, 0.08, sr)
    return normalise(s, 0.80)


def foley_branch(sr=SR, seed=7):
    """Dead wood limb snapping in the dark: pre-fracture creaks + beam crack + tree echoes."""
    rng = np.random.default_rng(seed)
    n = int(sr * 1.45)
    dry = np.zeros(n, dtype=np.float32)

    # 1) Pre-break wood-grain tension creaks (slip-stick ticks at 12..78 ms)
    for at_s, f_c, g_c in [(0.014, 310.0, 0.18), (0.033, 355.0, 0.24),
                           (0.051, 410.0, 0.30), (0.068, 470.0, 0.36), (0.080, 535.0, 0.44)]:
        creak = modal_ping(int(0.022 * sr), [
            (f_c, 150.0, 0.65, 0.0),
            (f_c * 2.42, 230.0, 0.42, 0.9),
            (f_c * 4.35, 340.0, 0.24, 1.8),
        ], sr, bend=0.08)
        add_at(dry, creak, int(at_s * sr), g_c)

    # 2) Main brittle wood fracture (t = 0.090 s): Euler-Bernoulli beam bending modes
    f1 = 228.0
    crack = modal_ping(int(0.24 * sr), [
        (f1 * 1.00, 34.0, 0.85, 0.0),
        (f1 * 2.14, 52.0, 0.68, 0.5),
        (f1 * 2.76, 68.0, 0.74, 1.3),
        (f1 * 4.18, 96.0, 0.55, 2.0),
        (f1 * 5.40, 128.0, 0.48, 0.8),
        (f1 * 7.65, 175.0, 0.36, 1.6),
        (f1 * 11.2, 240.0, 0.26, 2.5),
        (f1 * 15.6, 320.0, 0.18, 0.3),
    ], sr, bend=-0.09)
    crack[:28] += np.hanning(28).astype(np.float32) * 0.85
    add_at(dry, crack, int(0.090 * sr), 1.0)

    # 3) Secondary splinter snaps (124 ms & 168 ms)
    for at_s, fs, gs in [(0.124, 415.0, 0.48), (0.168, 590.0, 0.30)]:
        spl = modal_ping(int(0.07 * sr), [
            (fs, 85.0, 0.65, rng.uniform(0, 6.28)),
            (fs * 2.76, 145.0, 0.45, rng.uniform(0, 6.28)),
            (fs * 5.40, 230.0, 0.28, rng.uniform(0, 6.28)),
        ], sr, bend=-0.06)
        add_at(dry, spl, int(at_s * sr), gs)

    # 4) Discrete air-absorbed slapback echoes off surrounding tree trunks across the dark woods
    out = dry.copy()
    for delay_s, gain, cutoff in [(0.135, 0.34, 2400.0), (0.265, 0.21, 1650.0),
                                  (0.430, 0.13, 1150.0), (0.640, 0.075, 820.0)]:
        echo = lp(dry, cutoff)
        add_at(out, echo, int(delay_s * sr), gain)

    out = fade(np.tanh(out * 1.35), 0.002, 0.12, sr)
    return normalise(out, 0.74)


def foley_click(sr=SR, seed=8):
    """Crisp two-stage mechanical switch / metal flashlight latch (zero noise tail)."""
    n = int(sr * 0.085)
    s = np.zeros(n, dtype=np.float32)
    # Stage 1 (0 ms): plunger press + metal barrel modes
    p1 = modal_ping(n, [
        (580.0, 180.0, 0.55, 0.0),
        (1340.0, 240.0, 0.72, 0.4),
        (2680.0, 320.0, 0.52, 1.2),
        (4180.0, 420.0, 0.32, 2.0),
    ], sr, bend=-0.08)
    p1[:18] += np.hanning(18).astype(np.float32) * 0.65
    add_at(s, p1, 0, 0.82)

    # Stage 2 (13.5 ms): spring-detent catch click
    d2 = int(0.0135 * sr)
    p2 = modal_ping(n - d2, [
        (890.0, 210.0, 0.50, 0.2),
        (1960.0, 270.0, 0.85, 0.9),
        (3540.0, 360.0, 0.58, 1.7),
        (5120.0, 460.0, 0.30, 0.5),
    ], sr, bend=0.05)
    p2[:16] += np.hanning(16).astype(np.float32) * 0.70
    add_at(s, p2, d2, 1.0)

    s = fade(np.tanh(s * 1.3), 0.0008, 0.018, sr)
    return normalise(s, 0.48)


# --------------------------------------------------------------------------- #
# helpers for multi-layer stereo scenes
# --------------------------------------------------------------------------- #
def scene(dur, sr=SR):
    n = int(dur * sr)
    return np.zeros(n, dtype=np.float32), np.zeros(n, dtype=np.float32)


def finish(L, R, sr=SR, peak=0.95, drive=1.0, fade_in=0.003, fade_out=0.2):
    for ch in (L, R):
        fade(ch, fade_in, fade_out, sr)
    st = limit(np.stack([L, R], axis=1), drive, peak)
    mono = np.abs(st).max(axis=1)
    thr = mono.max() * 0.004
    idx = np.nonzero(mono > thr)[0]
    if len(idx):
        end = min(st.shape[0], idx[-1] + int(0.25 * sr))
        st = st[:end]
        st[-int(0.2 * sr):] *= np.linspace(1, 0, int(0.2 * sr))[:, None] ** 1.5
    return st


# --------------------------------------------------------------------------- #
# 1) death sting — the scream
# --------------------------------------------------------------------------- #
def make_jumpscare(sr=SR):
    L, R = scene(3.15, sr)
    hit = 0.115

    lead = vocal(2.45, pitch_arc(470, 960, 300), sr, seed=101,
                 formant_scale=1.06, rough=0.44, breath=0.32, sub=0.30,
                 crack_at=0.55, crack_depth=0.32, tear_at=0.42,
                 attack=0.02, release=0.42)
    growl = vocal(2.60, pitch_arc(168, 268, 96), sr, seed=102,
                  formant_scale=0.74, rough=0.72, breath=0.40, sub=0.88,
                  tilt=2400.0, attack=0.03, release=0.45)
    nerve = vocal(1.95, pitch_arc(760, 1290, 520), sr, seed=103,
                  formant_scale=1.28, rough=0.34, breath=0.36, sub=0.12,
                  tilt=5200.0, attack=0.02, release=0.35)

    place(L, reverb(lead, 0.34, seed=21), hit, 1.00)
    place(R, reverb(lead, 0.38, seed=22), hit + 0.010, 0.96)
    place(L, reverb(growl, 0.42, 2.0, 0.66, seed=23), hit + 0.045, 0.64)
    place(R, reverb(growl, 0.46, 2.0, 0.66, seed=24), hit + 0.032, 0.68)
    place(L, reverb(nerve, 0.30, seed=25), hit - 0.02, 0.30)
    place(R, reverb(nerve, 0.34, seed=26), hit - 0.01, 0.26)

    place(L, shriek(0.95, 1750, 4400, 4), hit - 0.01, 0.20)
    place(R, shriek(0.95, 1750, 4400, 5), hit + 0.006, 0.19)
    place(L, sub_impact(1.4, 3), hit - 0.005, 0.82)
    place(R, sub_impact(1.4, 4), hit - 0.005, 0.82)

    place(L, riser(0.28, 11, sr, 240, 3400, 2.4), 0.0, 0.20)
    place(R, riser(0.28, 12, sr, 240, 3400, 2.4), 0.004, 0.20)
    place(L, gasp(0.22, 21), 0.02, 0.16)
    place(R, gasp(0.22, 22), 0.026, 0.16)

    return finish(L, R, sr, 0.95, 1.0, 0.002, 0.30)


# --------------------------------------------------------------------------- #
# 2) apparition stingers — heard from the tree line
# --------------------------------------------------------------------------- #
def make_appear(seed=201, variant=0, sr=SR):
    """A distant, wrong voice arriving: reverse waterphone pull -> moan -> metallic sting."""
    L, R = scene(3.0, sr)
    rng = np.random.default_rng(seed)

    f0a = [150, 126, 190][variant % 3]
    moan = vocal(1.55, pitch_arc(f0a, f0a * 1.55, f0a * 0.72, rise=0.30, fall=0.72),
                 sr, seed=seed, formant_scale=0.82, rough=0.55, breath=0.38, sub=0.58,
                 tilt=1900.0, attack=0.16, release=0.55)
    moan = lp(moan, 1850.0)
    wet = 0.68
    place(L, reverb(moan, wet, 2.6, 0.82, seed + 1), 0.75, 0.58)
    place(R, reverb(moan, wet, 2.6, 0.82, seed + 2), 0.79, 0.60)

    # Reverse bowed-rod glissando pulling the ear toward him
    pre = riser(0.62, seed + 3, sr, 140, 1850, 3.0)[::-1].copy()
    place(L, reverb(pre, 0.28, seed=seed + 4), 0.10, 0.28)
    place(R, reverb(pre, 0.28, seed=seed + 5), 0.13, 0.28)

    # Dissonant bowed-wire / bone-snap transient at the moment of recognition (no noise burst)
    crack_t = 0.72
    base_f = [620.0, 540.0, 710.0][variant % 3]
    for ch, g, det in ((L, 1.0, 1.0), (R, 0.92, 1.018)):
        sting = modal_ping(int(0.48 * sr), [
            (base_f * det, 7.5, 0.55, 0.0),
            (base_f * 1.414 * det, 9.0, 0.46, 0.9),   # tritone rod
            (base_f * 2.38 * det, 14.0, 0.34, 1.7),
            (base_f * 3.91 * det, 22.0, 0.22, 2.5),
        ], sr, bend=-0.04)
        place(ch, sting, crack_t, 0.24 * g)
    place(L, gasp(0.45, seed + 6), 0.68, 0.22)
    place(R, gasp(0.45, seed + 7), 0.71, 0.20)

    imp = sub_impact(1.6, seed + 8, sr, 70, 22)
    place(L, imp, 0.70, 0.44)
    place(R, imp, 0.70, 0.44)

    return finish(L, R, sr, 0.85, 1.0, 0.02, 0.5)


def make_appear_near(seed=301, sr=SR):
    """He is standing right behind you: close articulated whisper, breath, coat-leather creak."""
    L, R = scene(2.8, sr)
    rng = np.random.default_rng(seed)

    wh = whisper(2.2, seed, sr, syllables=7)
    place(L, reverb(wh, 0.26, 1.3, 0.46, seed + 1), 0.28, 0.58)
    place(R, reverb(wh, 0.30, 1.3, 0.46, seed + 2), 0.33, 0.55)

    place(L, gasp(0.55, seed + 3, sr), 0.05, 0.42)
    place(R, gasp(0.55, seed + 4, sr), 0.09, 0.40)

    # Low 43 Hz presence pressure wave
    n = int(2.8 * sr)
    t = np.arange(n) / sr
    tone = np.sin(2 * np.pi * 43.0 * t + 0.4 * np.sin(2 * np.pi * 0.7 * t))
    tone += 0.35 * np.sin(2 * np.pi * 64.5 * t + 1.1)
    tone *= np.clip(t / 0.8, 0, 1) * np.exp(-np.maximum(0, t - 1.0) * 1.4)
    place(L, tone.astype(np.float32) * 0.28, 0.0, 1.0)
    place(R, tone.astype(np.float32) * 0.28, 0.006, 1.0)

    # Subtle close coat-leather / tendon slip-stick creak (replaces 0.7s white-noise swell)
    for ch, t_base in ((L, 0.54), (R, 0.61)):
        for k in range(11):
            at_s = t_base + k * 0.028 + rng.uniform(-0.006, 0.006)
            fc = 310.0 + 28.0 * k + rng.uniform(-18.0, 18.0)
            tick = modal_ping(int(0.018 * sr), [
                (fc, 165.0, 0.60, 0.0),
                (fc * 2.15, 240.0, 0.38, 1.2),
                (fc * 3.60, 340.0, 0.20, 2.1),
            ], sr, bend=0.06)
            env_k = math.sin(math.pi * (k + 0.5) / 11.0)
            place(ch, tick, at_s, 0.16 * env_k)

    return finish(L, R, sr, 0.8, 1.0, 0.02, 0.5)


# --------------------------------------------------------------------------- #
# 3) chase start — it stops watching and comes for you
# --------------------------------------------------------------------------- #
def make_chase(seed=401, sr=SR):
    L, R = scene(2.8, sr)

    roar = vocal(2.35, pitch_arc(118, 205, 74, rise=0.06, fall=0.55), sr, seed=seed,
                 formant_scale=0.62, rough=0.76, breath=0.45, sub=1.0,
                 tilt=2100.0, attack=0.025, release=0.5, drive=1.45)
    scream = vocal(2.2, pitch_arc(560, 1080, 380, rise=0.05, fall=0.6), sr, seed=seed + 1,
                   formant_scale=1.12, rough=0.48, breath=0.35, sub=0.22,
                   crack_at=0.62, crack_depth=0.30, attack=0.02, release=0.45)

    place(L, reverb(roar, 0.36, 2.2, 0.68, seed + 2), 0.02, 0.95)
    place(R, reverb(roar, 0.40, 2.2, 0.68, seed + 3), 0.035, 0.95)
    place(L, reverb(scream, 0.38, seed + 4), 0.10, 0.44)
    place(R, reverb(scream, 0.42, seed + 5), 0.115, 0.42)

    place(L, shriek(1.2, 700, 3200, seed + 6), 0.06, 0.16)
    place(R, shriek(1.2, 700, 3200, seed + 7), 0.07, 0.15)
    place(L, sub_impact(1.8, seed + 8, sr, 160, 26), 0.0, 0.9)
    place(R, sub_impact(1.8, seed + 9, sr, 160, 26), 0.0, 0.9)

    # Heavy charging footfalls + snapping dry wood (replaces 4 hp(noise) puffs)
    steps = foley_steps(sr, seed + 20)
    for i, (at, g) in enumerate([(0.06, 0.42), (0.31, 0.34), (0.58, 0.28), (0.88, 0.22)]):
        st_i = steps[i % len(steps)]
        place(L, st_i, at, g)
        place(R, st_i, at + 0.010, g * 0.88)

    return finish(L, R, sr, 0.95, 1.05, 0.003, 0.4)


# --------------------------------------------------------------------------- #
# 4) strained sprinting breathing loop (narrow tracheal resonances + voiced sigh)
# --------------------------------------------------------------------------- #
def make_breath(sr=SR, dur=7.0, seed=501):
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    x = np.zeros(n, dtype=np.float32)

    def breath_hit(start, length, wet, gain, pitch=1.0, exhale=False):
        i0 = int(start * sr)
        ln = min(int(length * sr), n - i0)
        if ln <= 0:
            return
        tt = np.arange(ln) / sr
        a = tt / (ln / sr)
        # Narrow tubular pharyngeal/tracheal formants (Q ~ 6-10, not broadband pink noise)
        F = np.stack([
            (620 - 180 * a) * pitch,
            (1380 - 280 * a) * pitch,
            (2420 - 220 * a) * pitch,
            np.full(ln, 3420.0 * pitch),
        ])
        B = np.stack([
            85 + 65 * a,
            120 + 80 * a,
            np.full(ln, 175.0),
            np.full(ln, 250.0),
        ])
        nz = noise(ln, rng)
        y = np.zeros(ln, dtype=np.float32)
        for i in range(4):
            y += (1.0 - 0.22 * i) * resonator(nz, F[i], B[i], sr)

        # Exhausted voiced laryngeal sigh/moan on exhales & shuddering inhales
        f0 = (138.0 - 34.0 * a) * pitch if exhale else (182.0 + 36.0 * np.sin(math.pi * a)) * pitch
        ph = 2 * np.pi * np.cumsum(f0) / sr
        sigh = (0.48 * np.sin(ph) + 0.28 * np.sin(2 * ph + 0.7)
                + 0.15 * np.sin(3 * ph + 1.5) + 0.07 * np.sin(4 * ph + 2.2))
        sigh_env = np.exp(-a * 2.4) if exhale else np.sin(math.pi * a) ** 1.4
        sigh_gain = 0.42 if exhale else 0.22

        y = np.tanh((y * 0.66 + sigh.astype(np.float32) * sigh_env * sigh_gain) * 1.25)
        e = np.clip(tt / 0.10, 0, 1) ** 1.15 * np.clip((ln / sr - tt) / 0.22, 0, 1) ** 0.85
        x[i0:i0 + ln] += (y * e * wet * gain).astype(np.float32)

    # Exhausted cycle: inhale -> voiced exhale -> shudder -> inhale -> voiced exhale -> catch
    breath_hit(0.05, 1.02, 1.00, 0.88, 1.00, exhale=False)
    breath_hit(0.96, 1.28, 0.90, 0.76, 0.88, exhale=True)
    breath_hit(2.40, 0.55, 0.75, 0.36, 1.14, exhale=False)
    breath_hit(3.10, 1.08, 1.00, 0.84, 0.99, exhale=False)
    breath_hit(4.06, 1.32, 0.90, 0.74, 0.86, exhale=True)
    breath_hit(5.55, 0.62, 0.78, 0.40, 1.18, exhale=False)

    # Subtle low chest-cavity pulse (no broadband room-noise hiss)
    chest = 0.035 * np.sin(2 * np.pi * 52.0 * t) * (0.6 + 0.4 * np.sin(2 * np.pi * 0.28 * t))
    x += chest.astype(np.float32)

    x = hp(lp(x, 5400.0), 95.0)
    return normalise(x, 0.9)


def make_breath_loop(sr=SR):
    x = make_breath(sr)
    y = crossfade_loop(x, sr, 1.2)
    return normalise(y, 0.85)


# --------------------------------------------------------------------------- #
# 5) win — relief that is not safe (pure open-fifth chord + voiced sigh)
# --------------------------------------------------------------------------- #
def make_win(sr=SR):
    n = int(5.5 * sr)
    t = np.arange(n) / sr
    out = np.zeros(n, dtype=np.float32)

    for f, a, det in [(98.0, 0.30, 0.0), (196.0, 0.22, 0.15), (293.66, 0.16, -0.2),
                      (392.0, 0.12, 0.25), (587.33, 0.07, -0.3), (783.99, 0.035, 0.18)]:
        vib = 1.0 + 0.0018 * np.sin(2 * np.pi * (0.7 + f / 400.0) * t)
        out += a * np.sin(2 * np.pi * (f * vib + det) * t) * np.exp(-t * 0.30)
    out *= np.clip(t / 1.1, 0, 1) ** 1.3

    out += 0.22 * np.sin(2 * np.pi * 46.0 * t) * (0.6 + 0.4 * np.sin(2 * np.pi * 0.13 * t))
    out += 0.08 * np.sin(2 * np.pi * 65.4 * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.09 * t + 1.2))

    ex = lp(gasp(1.1, 601, sr), 1500.0)
    ex *= np.clip(np.arange(len(ex)) / (0.25 * sr), 0, 1)
    out[:len(ex)] += ex * 0.14

    out *= np.clip(t / 0.5, 0, 1) ** 1.5
    out *= np.clip((n / sr - t) / 1.2, 0, 1) ** 1.2
    return normalise(out, 0.8)


# --------------------------------------------------------------------------- #
# everything
# --------------------------------------------------------------------------- #
def generate(audio_dir=AUDIO, sr=SR):
    os.makedirs(audio_dir, exist_ok=True)
    p = lambda name: os.path.join(audio_dir, name)  # noqa: E731

    write_ogg(p("wind_loop.ogg"), bed_wind(sr))
    write_ogg(p("drone_loop.ogg"), bed_drone(sr))
    write_ogg(p("static_loop.ogg"), bed_static(sr))
    write_ogg(p("heartbeat_loop.ogg"), bed_heartbeat(sr))
    write_ogg(p("breath_loop.ogg"), make_breath_loop(sr))
    write_ogg(p("wire_hum_loop.ogg"), bed_wire_hum(sr))

    for i, s in enumerate(foley_steps(sr)):
        write_ogg(p("step_%d.ogg" % i), s)
    for i, s in enumerate(foley_stone_steps(sr)):
        write_ogg(p("stone_step_%d.ogg" % i), s)
    write_ogg(p("page.ogg"), foley_page(sr))
    write_ogg(p("branch.ogg"), foley_branch(sr))
    write_ogg(p("ui_click.ogg"), foley_click(sr))

    write_ogg(p("jumpscare.ogg"), make_jumpscare(sr))
    write_ogg(p("appear_near.ogg"), make_appear_near(301, sr))
    write_ogg(p("chase.ogg"), make_chase(401, sr))
    write_ogg(p("win.ogg"), make_win(sr))
    for v in range(3):
        write_ogg(p("appear_%d.ogg" % v), make_appear(201 + 10 * v, v, sr))


if __name__ == "__main__":
    generate()
    print("audio done ->", AUDIO)
