#!/usr/bin/env python3
"""EIGHT PAGES — procedural horror audio.

Every sample in assets/audio is synthesised here, from nothing.

The core is a small **additive voice engine**: a screaming voice is a stack of
harmonics of the glottal pitch, each harmonic weighted by a five-formant
envelope, with an unstable pitch contour (vibrato + jitter + a break where the
voice gives out) and a torn, aspirated breath layer.  That is what makes a
scream read as a *throat* instead of a hiss of noise.  Everything else —
inharmonic metal shrieks, sub impacts, chirped air risers, wet gasps,
whispered syllables, room reverb — is noise and sine layers on top.

The ambient beds (wind, drone, static, heartbeat) and the small foley sounds
(steps, page, branch, UI) live here too, so the whole audio set is reproducible:

    python3 tools/gen_sfx.py            # writes assets/audio/*.wav
"""
import math
import os
import wave

import numpy as np
from scipy.signal import butter, sosfilt, fftconvolve

SR = 22050
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO = os.path.join(ROOT, "assets", "audio")

# --------------------------------------------------------------------------- #
# basic dsp
# --------------------------------------------------------------------------- #
def lp(x, cutoff, order=2, sr=SR):
    return sosfilt(butter(order, min(0.99, cutoff / (sr / 2)), btype="low", output="sos"), x)


def hp(x, cutoff, order=2, sr=SR):
    return sosfilt(butter(order, min(0.99, cutoff / (sr / 2)), btype="high", output="sos"), x)


def bp(x, lo, hi, order=2, sr=SR):
    sos = butter(order, [lo / (sr / 2), min(0.99, hi / (sr / 2))], btype="band", output="sos")
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


def resonator(x, freq, bw, sr=SR):
    """Time-varying 2-pole resonator, unity gain at centre."""
    n = len(x)
    freq = np.full(n, freq, dtype=np.float64) if np.isscalar(freq) else np.asarray(freq, float)
    bw = np.full(n, bw, dtype=np.float64) if np.isscalar(bw) else np.asarray(bw, float)
    freq = np.clip(freq, 30.0, sr * 0.45)
    bw = np.clip(bw, 25.0, sr * 0.4)
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
# the voice
# --------------------------------------------------------------------------- #
def vocal(dur, f0_shape, sr=SR, seed=0, formant_scale=1.0, amps=(1.0, 0.82, 0.58, 0.38, 0.20),
          bw=(150, 190, 250, 300, 380), rough=0.5, breath=0.6, sub=0.35,
          tilt=4200.0, fmax=6500.0, jitter=0.020, vibrato=(5.3, 0.030, 0.020),
          crack_at=None, crack_depth=0.0, tear_at=None, attack=0.03, release=0.30,
          vowel_shift=1.0, drive=1.15):
    """One voice.  f0_shape(t, dur) -> array of Hz."""
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
        # the voice gives out: pitch sags briefly (smooth, no phase blow-up)
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
        # harmonic phase jitter keeps it from sounding like an organ
        out += E * np.sin(2 * np.pi * k * ph + rng.uniform(0, 2 * np.pi))

    if sub > 0:
        g = np.clip((t - dur * 0.30) / (dur * 0.55), 0, 1)
        out += sub * 0.6 * g * np.sin(2 * np.pi * 0.5 * ph + 0.7)

    # rasp: shallow, aperiodic vocal-fold roughness (fry), not a gate
    r1 = smooth_noise(N, rng, 23.0, sr)
    r2 = smooth_noise(N, rng, 41.0, sr)
    am = 1.0 - rough * 0.55 * np.clip(0.55 * r1 + 0.30 * r2, -1.0, 1.0)
    out *= lp(am, 90.0)

    # torn breath: bright air routed through the throat, kept *under* the tone
    nz = noise(N, rng)
    nzr = (resonator(nz, F[0] * 1.25, 700.0, sr) * 0.35
           + resonator(nz, F[1] * 1.10, 900.0, sr) * 0.35
           + resonator(nz, 4200.0, 800.0, sr) * 0.45
           + resonator(nz, 5900.0, 1100.0, sr) * 0.30)
    out = out + breath * nzr * 0.16 * lp(am, 60.0)

    if tear_at is not None:
        # a couple of cycles are torn out of the throat -> noisy gap in the tone
        gp = np.ones(N)
        i0 = int(tear_at * dur * sr)
        for off in (0.0, 0.035, 0.075):
            j0 = min(N - 1, i0 + int(off * sr))
            j1 = min(N, j0 + int(0.022 * sr))
            gp[j0:j1] *= 0.12
        gp = np.convolve(gp, np.hanning(int(0.008 * sr)), mode="same")
        out *= gp
        burst = bp(noise(N, rng), 900.0, 5200.0) * (1.0 - gp)
        out += burst * 0.35

    out = np.tanh(out * drive)
    out = hp(out, 90.0)
    # presence lift: screams live in 2-5 kHz, this is the "pain" band
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
# layers
# --------------------------------------------------------------------------- #
def shriek(dur=0.9, f_lo=1900.0, f_hi=4200.0, seed=5, sr=SR):
    """Inharmonic metallic scream layer (like steel being torn)."""
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    sweep = f_lo + (f_hi - f_lo) * (1 - np.exp(-t * 15.0))
    mod = np.sin(2 * np.pi * (131.0 + 37.0 * t) * t) * (5.0 * np.exp(-t * 1.1) + 1.0)
    car = np.sin(2 * np.pi * np.cumsum(sweep) / sr + mod * 3.2)
    car += 0.62 * np.sin(2 * np.pi * np.cumsum(sweep * 2.41) / sr + 0.4)
    car += 0.40 * np.sin(2 * np.pi * np.cumsum(sweep * 3.83) / sr + 1.7)
    car += 0.22 * np.sin(2 * np.pi * np.cumsum(sweep * 5.19) / sr + 2.9)
    nz = bp(noise(n, rng), f_lo * 0.55, min(9500.0, f_hi * 1.7))
    x = np.tanh((car * 0.75 + nz * 0.55) * 1.7)
    x *= np.exp(-t * 3.4) * np.clip(t / 0.012, 0, 1)
    return normalise(x)


def sub_impact(dur=1.2, seed=3, sr=SR, f_top=130.0, f_bot=24.0):
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    f = f_bot + (f_top - f_bot) * np.exp(-t * 8.5)
    ph = 2 * np.pi * np.cumsum(f) / sr
    body = np.sin(ph) * np.exp(-t * 3.0)
    body += 0.33 * np.sin(ph * 2.02) * np.exp(-t * 6.5)
    body += 0.16 * np.sin(ph * 3.01 + 1.0) * np.exp(-t * 9.0)
    click = hp(noise(n, rng), 1400) * np.exp(-t * 110.0)
    thud = lp(noise(n, rng), 280) * np.exp(-t * 13.0)
    x = np.tanh((body + click * 0.55 + thud * 0.75) * 1.3)
    return normalise(x)


def riser(dur=0.42, seed=11, sr=SR, f0=260.0, f1=5200.0, shape=2.4):
    """Chirped noise riser — an inhale / a lunge through the air."""
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    x = noise(n, rng)
    chirp = f0 * (f1 / f0) ** (t / dur)
    x = x * np.sin(2 * np.pi * np.cumsum(chirp) / sr * 0.5)
    x = hp(lp(x, 7500.0), 300.0) * (t / dur) ** shape
    return normalise(x)


def gasp(dur=0.5, seed=21, sr=SR):
    """Wet strained inhale through an open throat."""
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    a = t / dur
    one = np.ones(n)
    F = np.stack([900 - 300 * a, 1550 - 400 * a, 2700 - 400 * a, 3600 * one, 4500 * one])
    B = np.stack([260 + 300 * a, 320 + 300 * a, 420 * one, 520 * one, 620 * one])
    nz = noise(n, rng)
    y = np.zeros(n, dtype=np.float32)
    for i in range(4):
        y += (1.0 - .2 * i) * resonator(nz, F[i], B[i], sr)
    y *= np.clip(t / 0.05, 0, 1) * np.clip((dur - t) / 0.18, 0, 1) ** 0.7
    y = hp(y, 220.0)
    return normalise(y)


def whisper(dur=2.2, seed=31, sr=SR, syllables=6):
    """Indistinct whispered speech: noise through moving vowels + consonants."""
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    vowels = [(730, 1090, 2440), (270, 2290, 3010), (300, 870, 2240),
              (530, 1840, 2480), (570, 840, 2410), (660, 1720, 2410)]
    order = rng.integers(0, len(vowels), syllables)
    F1 = np.zeros(n); F2 = np.zeros(n); F3 = np.zeros(n)
    amp = np.zeros(n)
    seg = dur / syllables
    for i, v in enumerate(order):
        i0, i1 = int(i * seg * sr), int((i + 1) * seg * sr)
        i1 = min(i1, n)
        k = i1 - i0
        if k <= 0:
            continue
        ramp = np.ones(k)
        hold = int(k * 0.22)
        ramp[:hold] = np.linspace(0, 1, hold) ** 0.6
        ramp[-int(k * 0.42):] *= np.linspace(1, 0, int(k * 0.42)) ** 0.8
        F1[i0:i1] = vowels[v][0]; F2[i0:i1] = vowels[v][1]; F3[i0:i1] = vowels[v][2]
        amp[i0:i1] = ramp * rng.uniform(0.55, 1.0)
    # smooth the formant tracks between syllables
    for arr in (F1, F2, F3):
        arr[:] = np.convolve(arr, np.ones(400) / 400, mode="same")
    nz = noise(n, rng)
    y = (resonator(nz, F1, 120, sr) * 1.0
         + resonator(nz, F2, 160, sr) * 0.7
         + resonator(nz, F3, 220, sr) * 0.45
         + resonator(nz, 4200, 400, sr) * 0.2)
    y *= amp
    # consonant ticks between syllables
    for i in range(syllables):
        i0 = int(i * seg * sr) - int(0.012 * sr)
        if 0 < i0 < n - 200:
            tick = hp(noise(180, rng), 2500) * np.hanning(180)
            y[i0:i0 + 180] += tick * 0.5
    y = hp(lp(y, 6500.0), 900.0)
    return normalise(y)


# --------------------------------------------------------------------------- #
# space + mixing
# --------------------------------------------------------------------------- #
def reverb_ir(dur=1.8, decay=0.62, seed=13, sr=SR, tilt=3200.0, predelay=0.012):
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    ir = noise(n, rng) * np.exp(-t / decay)
    ir = hp(lp(ir, tilt), 150.0)
    for d, g in [(0.011, 0.55), (0.019, -0.42), (0.031, 0.34), (0.047, -0.26), (0.061, 0.2)]:
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
    """Gentle soft-clip + peak normalise (keeps transients, tames screams)."""
    x = np.tanh(x * drive)
    return normalise(x, peak)


def write_wav(path, data, sr=SR):
    data = np.clip(np.asarray(data, dtype=np.float32), -1, 1)
    if data.ndim == 1:
        data = data[:, None]
    with wave.open(path, "wb") as f:
        f.setnchannels(data.shape[1])
        f.setsampwidth(2)
        f.setframerate(sr)
        f.writeframes((data * 32767.0).astype("<i2").tobytes())
    print("  %-18s %5.2fs %d ch" % (os.path.basename(path), len(data) / sr, data.shape[1]))

# --------------------------------------------------------------------------- #
# ambient beds + foley
# --------------------------------------------------------------------------- #
def bed_wind(sr=SR, seed=1):
    rng = np.random.default_rng(seed)
    n = sr * 10
    white = noise(n, rng)
    wind = lp(white, 700) * 0.9 + lp(noise(n, rng), 180) * 1.4
    t = np.arange(n) / sr
    gust = (0.55 + 0.45 * (0.5 + 0.5 * np.sin(2 * math.pi * t / 10.0 + 0.4))
            * (0.6 + 0.4 * np.sin(2 * math.pi * t / 3.7)))
    wind = normalise(wind * gust, 0.55)
    return crossfade_loop(wind, sr, 1.5)


def bed_drone(sr=SR, seed=2):
    """A cold bed with a minor-second beat that never settles."""
    rng = np.random.default_rng(seed)
    n = sr * 16
    t = np.arange(n) / sr
    drone = np.zeros(n, dtype=np.float32)
    # 41 Hz and 43.6 Hz beat against each other -> slow unease
    for f, a, ph in [(41.0, 0.50, 0.0), (43.6, 0.30, 1.1), (61.5, 0.26, 2.2),
                     (82.0, 0.15, 0.4), (123.0, 0.06, 1.7), (164.0, 0.03, 2.9)]:
        drone += a * np.sin(2 * math.pi * f * t + 0.7 * np.sin(2 * math.pi * 0.05 * t) + ph)
    # a breath of air moving through the drone
    air = lp(noise(n, rng), 400) * (0.35 + 0.65 * (0.5 + 0.5 * np.sin(2 * math.pi * t / 16.0)))
    drone = drone * (0.6 + 0.4 * np.sin(2 * math.pi * t / 16.0)) + air * 0.55
    drone = normalise(drone, 0.40)
    return crossfade_loop(drone, sr, 2.0)


def bed_static(sr=SR, seed=3):
    rng = np.random.default_rng(seed)
    n = sr * 3
    st = noise(n, rng)
    st = hp(st, 900) * 0.7 + lp(st, 120) * 0.8
    crackle = (rng.random(n) > 0.9993).astype(np.float32) * noise(n, rng) * 6.0
    return crossfade_loop(np.clip((st + crackle) * 0.5, -1, 1), sr, 0.5)


def bed_heartbeat(sr=SR, seed=4):
    """Two beats, the second always a little late: panic, not a metronome."""
    rng = np.random.default_rng(seed)
    n = sr * 2
    beat = np.zeros(n, dtype=np.float32)
    for start, amp, pitch in [(0.02, 1.0, 47.0), (0.315, 0.60, 43.0)]:
        i0 = int(start * sr)
        ln = min(int(0.28 * sr), n - i0)
        tt = np.arange(ln) / sr
        thump = np.sin(2 * math.pi * pitch * tt * (1 - tt * 0.8)) * np.exp(-tt * 15.0)
        thump += 0.35 * np.sin(2 * math.pi * pitch * 1.87 * tt) * np.exp(-tt * 26.0)
        thump += 0.18 * np.sin(2 * math.pi * 27.0 * tt) * np.exp(-tt * 30.0)  # sub
        beat[i0:i0 + ln] += (thump * amp)[:ln]
    beat = lp(beat, 300)
    beat += lp(noise(n, rng), 90) * 0.012          # body, not a clean sine
    return normalise(beat, 0.85)


def foley_steps(sr=SR, seed=5):
    rng = np.random.default_rng(seed)
    out = []
    for i in range(4):
        n = int(sr * 0.34)
        t = np.arange(n) / sr
        nz = noise(n, rng)
        body = lp(nz, 900 + i * 120)
        snap = hp(nz, 2500) * 0.25
        thump = np.sin(2 * math.pi * (72 - i * 6) * t) * np.exp(-t * 38)
        s = (body * 0.8 + snap + thump * 0.7) * np.exp(-t * 22)
        out.append(normalise(s, 0.55))
    return out


def foley_stone_steps(sr=SR, seed=9):
    """Cold boot-on-flagstone steps for the labyrinth (dry; room comes from Sfx)."""
    rng = np.random.default_rng(seed)
    out = []
    for i in range(4):
        n = int(sr * 0.30)
        t = np.arange(n) / sr
        nz = noise(n, rng)
        # heel impact at t=0, sole slap ~42-54 ms later + fine grit scrape
        heel = (bp(nz, 1100 + i * 90, 4200) * 0.85 + lp(nz, 420) * 0.55) * np.exp(-t * 62.0)
        heel += 0.55 * np.sin(2 * math.pi * (108 - i * 7) * t) * np.exp(-t * 52.0)
        sole = np.zeros(n, dtype=np.float32)
        d0 = int((0.042 + 0.004 * i) * sr)
        tt = np.arange(n - d0) / sr
        nz2 = noise(n - d0, rng)
        sole[d0:] = (bp(nz2, 900, 3400) * 0.65 + 0.35 * np.sin(2 * math.pi * (195 + i * 14) * tt)) * np.exp(-tt * 48.0)
        grit = bp(noise(n, rng), 2400, 6200) * np.exp(-t * 28.0) * 0.18
        s = fade(heel + sole + grit, 0.002, 0.04, sr)
        out.append(normalise(s, 0.62))
    return out


def foley_page(sr=SR, seed=6):
    """Paper, and under it the sound of something breathing in your ear."""
    rng = np.random.default_rng(seed)
    n = int(sr * 1.3)
    t = np.arange(n) / sr
    nz = noise(n, rng)
    rustle = hp(nz, 1800) * (0.4 + 0.6 * np.abs(np.sin(2 * math.pi * 15 * t)))
    rustle *= np.exp(-((t - 0.18) ** 2) / (2 * 0.13 ** 2)) + 0.25 * np.exp(-t * 3)
    rustle = normalise(rustle, 0.7)
    inh = gasp(0.55, seed + 1, sr) * 0.30
    i0 = int(0.42 * sr)
    ln = min(len(inh), n - i0)
    rustle[i0:i0 + ln] += inh[:ln]
    return normalise(rustle, 0.8)


def foley_branch(sr=SR, seed=7):
    """A branch snapping somewhere out in the dark, with the dark answering."""
    rng = np.random.default_rng(seed)
    n = int(sr * 1.4)
    t = np.arange(n) / sr
    snap = hp(noise(n, rng), 1500) * np.exp(-t * 26)
    snap += np.sin(2 * math.pi * 140 * t) * np.exp(-t * 30) * 0.5
    snap *= np.clip(t / 0.002, 0, 1)
    snap = reverb(normalise(snap, 0.7), 0.45, 1.4, 0.55, seed + 1, sr)
    return normalise(snap[:n], 0.7)


def foley_click(sr=SR, seed=8):
    rng = np.random.default_rng(seed)
    n = int(sr * 0.12)
    t = np.arange(n) / sr
    click = (np.sin(2 * math.pi * 1200 * t) * 0.5 + noise(n, rng) * 0.15) * np.exp(-t * 45)
    return normalise(click, 0.4)

# --------------------------------------------------------------------------- #
# helpers for multi-layer scenes
# --------------------------------------------------------------------------- #
def scene(dur, sr=SR):
    n = int(dur * sr)
    return np.zeros(n, dtype=np.float32), np.zeros(n, dtype=np.float32)


def finish(L, R, sr=SR, peak=0.95, drive=1.0, fade_in=0.003, fade_out=0.2):
    for ch in (L, R):
        fade(ch, fade_in, fade_out, sr)
    st = limit(np.stack([L, R], axis=1), drive, peak)
    # drop digital silence at the tail (keeps one-shots tight)
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
                 formant_scale=1.06, rough=0.46, breath=0.72, sub=0.26,
                 crack_at=0.55, crack_depth=0.32, tear_at=0.42,
                 attack=0.02, release=0.42)
    growl = vocal(2.60, pitch_arc(168, 268, 96), sr, seed=102,
                  formant_scale=0.74, rough=0.80, breath=1.05, sub=0.85,
                  tilt=2400.0, attack=0.03, release=0.45)
    nerve = vocal(1.95, pitch_arc(760, 1290, 520), sr, seed=103,
                  formant_scale=1.28, rough=0.38, breath=0.95, sub=0.10,
                  tilt=5200.0, attack=0.02, release=0.35)

    place(L, reverb(lead, 0.34, seed=21), hit, 1.00)
    place(R, reverb(lead, 0.38, seed=22), hit + 0.010, 0.96)
    place(L, reverb(growl, 0.42, 2.0, 0.66, seed=23), hit + 0.045, 0.62)
    place(R, reverb(growl, 0.46, 2.0, 0.66, seed=24), hit + 0.032, 0.66)
    place(L, reverb(nerve, 0.30, seed=25), hit - 0.02, 0.30)
    place(R, reverb(nerve, 0.34, seed=26), hit - 0.01, 0.26)

    place(L, shriek(0.95, 1750, 4400, 4), hit - 0.01, 0.20)
    place(R, shriek(0.95, 1750, 4400, 5), hit + 0.006, 0.19)
    place(L, sub_impact(1.4, 3), hit - 0.005, 0.80)
    place(R, sub_impact(1.4, 4), hit - 0.005, 0.80)

    place(L, riser(0.30, 11, sr, 250, 5600, 2.6), 0.0, 0.22)
    place(R, riser(0.30, 12, sr, 250, 5600, 2.6), 0.004, 0.22)
    place(L, gasp(0.22, 21), 0.02, 0.16)
    place(R, gasp(0.22, 22), 0.026, 0.16)

    return finish(L, R, sr, 0.95, 1.0, 0.002, 0.30)


# --------------------------------------------------------------------------- #
# 2) apparition stingers — heard from the tree line
# --------------------------------------------------------------------------- #
def make_appear(seed=201, variant=0, sr=SR):
    """A distant, wrong voice arriving: reverse swell -> moan -> static crack."""
    L, R = scene(3.0, sr)
    rng = np.random.default_rng(seed)

    # far-off moan: a short scream fragment, pitched down and drenched in room
    f0a = [150, 126, 190][variant % 3]
    moan = vocal(1.55, pitch_arc(f0a, f0a * 1.55, f0a * 0.72, rise=0.30, fall=0.72),
                 sr, seed=seed, formant_scale=0.82, rough=0.62, breath=1.0, sub=0.55,
                 tilt=1900.0, attack=0.16, release=0.55)
    moan = lp(moan, 1800.0)
    wet = 0.72
    place(L, reverb(moan, wet, 2.8, 0.85, seed + 1), 0.75, 0.55)
    place(R, reverb(moan, wet, 2.8, 0.85, seed + 2), 0.79, 0.58)

    # reverse swell pulling the ear towards it
    pre = riser(0.62, seed + 3, sr, 120, 2600, 3.2)
    pre = pre[::-1].copy()
    place(L, reverb(pre, 0.3, seed=seed + 4), 0.10, 0.30)
    place(R, reverb(pre, 0.3, seed=seed + 5), 0.13, 0.30)

    # the moment it is noticed: a static crack + a breath right by the ear
    crack_t = 0.72
    for ch, g in ((L, 1.0), (R, 0.9)):
        m = int(0.5 * sr)
        cr = bp(noise(m, rng), 1400, 7000) * np.exp(-np.arange(m) / sr * 26.0)
        cr *= np.clip(np.arange(m) / (0.004 * sr), 0, 1)        # 4 ms attack, no click
        place(ch, cr * 0.5, crack_t, 0.22 * g)
    place(L, gasp(0.45, seed + 6), 0.68, 0.22)
    place(R, gasp(0.45, seed + 7), 0.71, 0.20)

    # a sub pulse you feel more than hear
    imp = sub_impact(1.6, seed + 8, sr, 70, 22)
    place(L, imp, 0.70, 0.42)
    place(R, imp, 0.70, 0.42)

    return finish(L, R, sr, 0.85, 1.0, 0.02, 0.5)


def make_appear_near(seed=301, sr=SR):
    """He is standing behind you.  Whisper, cloth, a click in the ear."""
    L, R = scene(2.8, sr)

    wh = whisper(2.2, seed, sr, syllables=7)
    place(L, reverb(wh, 0.30, 1.4, 0.5, seed + 1), 0.28, 0.55)
    place(R, reverb(wh, 0.34, 1.4, 0.5, seed + 2), 0.33, 0.52)

    gasp0 = gasp(0.55, seed + 3, sr)
    place(L, gasp0, 0.05, 0.42)
    place(R, gasp(0.55, seed + 4, sr), 0.09, 0.40)

    # a single low "presence" tone that swells and dies
    n = int(2.8 * sr)
    t = np.arange(n) / sr
    tone = np.sin(2 * np.pi * 43.0 * t + 0.4 * np.sin(2 * np.pi * 0.7 * t))
    tone *= np.clip(t / 0.8, 0, 1) * np.exp(-np.maximum(0, t - 1.0) * 1.4)
    place(L, tone * 0.30, 0.0, 1.0)
    place(R, tone * 0.30, 0.006, 1.0)

    # cloth / skin movement, very close, both ears
    for ch, off in ((L, 0.55), (R, 0.62)):
        nz = bp(noise(int(0.7 * sr), np.random.default_rng(seed + 5)), 700, 3400)
        nz *= np.hanning(len(nz)) ** 2
        place(ch, nz * 0.25, off, 1.0)

    return finish(L, R, sr, 0.8, 1.0, 0.02, 0.5)


# --------------------------------------------------------------------------- #
# 3) chase start — it stops watching and comes for you
# --------------------------------------------------------------------------- #
def make_chase(seed=401, sr=SR):
    L, R = scene(2.8, sr)

    roar = vocal(2.35, pitch_arc(118, 205, 74, rise=0.06, fall=0.55), sr, seed=seed,
                 formant_scale=0.62, rough=0.85, breath=1.25, sub=1.0,
                 tilt=2100.0, attack=0.025, release=0.5, drive=1.5)
    scream = vocal(2.2, pitch_arc(560, 1080, 380, rise=0.05, fall=0.6), sr, seed=seed + 1,
                   formant_scale=1.12, rough=0.55, breath=0.8, sub=0.2,
                   crack_at=0.62, crack_depth=0.30, attack=0.02, release=0.45)

    place(L, reverb(roar, 0.38, 2.2, 0.7, seed + 2), 0.02, 0.95)
    place(R, reverb(roar, 0.42, 2.2, 0.7, seed + 3), 0.035, 0.95)
    place(L, reverb(scream, 0.40, seed + 4), 0.10, 0.42)
    place(R, reverb(scream, 0.44, seed + 5), 0.115, 0.40)

    place(L, shriek(1.2, 700, 3200, seed + 6), 0.06, 0.16)
    place(R, shriek(1.2, 700, 3200, seed + 7), 0.07, 0.15)
    place(L, sub_impact(1.8, seed + 8, sr, 160, 26), 0.0, 0.9)
    place(R, sub_impact(1.8, seed + 9, sr, 160, 26), 0.0, 0.9)
    # the sound of something very large moving fast through brush
    for i, (at, g) in enumerate([(0.05, .30), (0.30, .22), (0.62, .18), (1.0, .12)]):
        n = int(0.30 * sr)
        rng = np.random.default_rng(seed + 20 + i)
        br = hp(noise(n, rng), 900) * np.exp(-np.arange(n) / sr * 20.0)
        br *= np.clip(np.arange(n) / (0.003 * sr), 0, 1)
        place(L, br, at, g)
        place(R, br, at + 0.012, g * 0.8)

    return finish(L, R, sr, 0.95, 1.05, 0.003, 0.4)


# --------------------------------------------------------------------------- #
# 4) strained breathing loop
# --------------------------------------------------------------------------- #
def make_breath(sr=SR, dur=7.0, seed=501):
    rng = np.random.default_rng(seed)
    n = int(dur * sr)
    t = np.arange(n) / sr
    x = np.zeros(n, dtype=np.float32)

    def breath_hit(start, length, wet, gain, pitch=1.0):
        i0 = int(start * sr)
        ln = int(length * sr)
        ln = min(ln, n - i0)
        if ln <= 0:
            return
        tt = np.arange(ln) / sr
        a = tt / (ln / sr)
        F = np.stack([(700 - 250 * a) * pitch, (1450 - 350 * a) * pitch,
                      (2500 - 300 * a) * pitch, np.full(ln, 3300.0), np.full(ln, 4300.0)])
        B = np.stack([260 + 320 * a, 340 + 320 * a, np.full(ln, 420.0),
                      np.full(ln, 520.0), np.full(ln, 640.0)])
        nz = noise(ln, rng)
        y = np.zeros(ln, dtype=np.float32)
        for i in range(5):
            y += (1.0 - 0.18 * i) * resonator(nz, F[i], B[i], sr)
        y = np.tanh(y * 1.4)
        e = np.clip(tt / 0.10, 0, 1) ** 1.2 * np.clip((ln / sr - tt) / 0.22, 0, 1) ** 0.8
        y *= e * wet
        x[i0:i0 + ln] += y * gain

    # exhausted cycle: in ... out ... shudder ... in ... out, never fully silent
    breath_hit(0.05, 1.05, 1.00, 0.90, 1.00)
    breath_hit(0.95, 1.30, 0.85, 0.72, 0.87)
    breath_hit(2.40, 0.55, 0.70, 0.34, 1.16)
    breath_hit(3.10, 1.10, 1.00, 0.84, 0.99)
    breath_hit(4.05, 1.35, 0.85, 0.70, 0.85)
    breath_hit(5.55, 0.62, 0.75, 0.38, 1.20)

    # room tone so the loop never drops to digital silence
    room = lp(noise(n, rng), 700.0) * 0.05
    room += 0.04 * np.sin(2 * np.pi * 52.0 * t) * (0.6 + 0.4 * np.sin(2 * np.pi * 0.17 * t))
    x += room.astype(np.float32)

    # throat rattle under the exhales
    g = np.zeros(n, dtype=np.float32)
    for s0, e0 in [(0.95, 2.25), (4.05, 5.40)]:
        i0, i1 = int(s0 * sr), int(e0 * sr)
        g[i0:i1] = hp(np.abs(np.sin(2 * np.pi * 27.0 * t[i0:i1])), 20) ** 3
    x += g * bp(noise(n, rng), 180, 900) * 0.30

    x = hp(lp(x, 6000.0), 120.0)
    return normalise(x, 0.9)


def make_breath_loop(sr=SR):
    x = make_breath(sr)
    y = crossfade_loop(x, sr, 1.2)
    return normalise(y, 0.85)


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


# --------------------------------------------------------------------------- #
# 5) win — relief that is not safe
# --------------------------------------------------------------------------- #
def make_win(sr=SR):
    n = int(5.5 * sr)
    t = np.arange(n) / sr
    out = np.zeros(n, dtype=np.float32)

    # hollow open fifth stack (no third -> neither happy nor sad), soft attack
    for f, a, det in [(98.0, 0.30, 0.0), (196.0, 0.22, 0.15), (293.66, 0.16, -0.2),
                      (392.0, 0.12, 0.25), (587.33, 0.07, -0.3)]:
        vib = 1.0 + 0.0018 * np.sin(2 * np.pi * (0.7 + f / 400.0) * t)
        out += a * np.sin(2 * np.pi * (f * vib + det) * t) * np.exp(-t * 0.30)
    out *= np.clip(t / 1.1, 0, 1) ** 1.3          # fades in under the exhale

    # a low drone that never resolves
    out += 0.22 * np.sin(2 * np.pi * 46.0 * t) * (0.6 + 0.4 * np.sin(2 * np.pi * 0.13 * t))
    out += 0.08 * np.sin(2 * np.pi * 65.4 * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.09 * t + 1.2))

    # exhausted exhale: the gasp played forward, low-passed, quiet
    ex = lp(gasp(1.1, 601, sr), 1600.0)
    ex *= np.clip(np.arange(len(ex)) / (0.25 * sr), 0, 1)
    out[:len(ex)] += ex * 0.16

    # breathy air over the chord
    rng = np.random.default_rng(602)
    air = lp(noise(n, rng), 2200)
    air *= np.clip(t / 1.2, 0, 1) * np.exp(-t * 0.45)
    out += air * 0.045

    out *= np.clip(t / 0.5, 0, 1) ** 1.5
    out *= np.clip((n / sr - t) / 1.2, 0, 1) ** 1.2
    return normalise(out, 0.8)

# --------------------------------------------------------------------------- #
# everything
# --------------------------------------------------------------------------- #
def generate(audio_dir=AUDIO, sr=SR):
    os.makedirs(audio_dir, exist_ok=True)
    p = lambda name: os.path.join(audio_dir, name)  # noqa: E731

    write_wav(p("wind_loop.wav"), bed_wind(sr))
    write_wav(p("drone_loop.wav"), bed_drone(sr))
    write_wav(p("static_loop.wav"), bed_static(sr))
    write_wav(p("heartbeat_loop.wav"), bed_heartbeat(sr))
    write_wav(p("breath_loop.wav"), make_breath_loop(sr))

    for i, s in enumerate(foley_steps(sr)):
        write_wav(p("step_%d.wav" % i), s)
    for i, s in enumerate(foley_stone_steps(sr)):
        write_wav(p("stone_step_%d.wav" % i), s)
    write_wav(p("page.wav"), foley_page(sr))
    write_wav(p("branch.wav"), foley_branch(sr))
    write_wav(p("ui_click.wav"), foley_click(sr))

    write_wav(p("jumpscare.wav"), make_jumpscare(sr))
    write_wav(p("appear_near.wav"), make_appear_near(301, sr))
    write_wav(p("chase.wav"), make_chase(401, sr))
    write_wav(p("win.wav"), make_win(sr))
    for v in range(3):
        write_wav(p("appear_%d.wav" % v), make_appear(201 + 10 * v, v, sr))


if __name__ == "__main__":
    generate()
    print("audio done ->", AUDIO)
