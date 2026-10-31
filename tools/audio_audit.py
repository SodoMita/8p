#!/usr/bin/env python3
"""Objective audit of every generated sound in assets/audio.

Run it after `python3 tools/gen_sfx.py`:

    python3 tools/audio_audit.py                # table for all streams
    python3 tools/audio_audit.py --json out.json
    python3 tools/audio_audit.py --diff <git-ref>   # compare against a commit

Every metric here answers a question a listener would ask, but in a way a
script can check on every regeneration:

  SFM      spectral flatness (0..1). Near 1 = the spectrum is flat, i.e. it is
           noise. Voices, valves, wood, stone and strings all live well under
           0.35; only an interference/static cue may sit higher.
  TONAL    peak of the normalised autocorrelation over 40-1800 Hz lags. High
           means a stable periodic structure (a pitch, a ringing mode).
  CENTROID spectral centroid in Hz - how bright the cue is.
  CREST    peak / RMS, in dB. Impacts are peaky (12-30 dB), beds are not.
  KURT     excess-free kurtosis of the waveform. Gaussian noise is 3.0;
           transient foley is far above it.
  ENV_CV   coefficient of variation of the 10 ms RMS envelope: how much the
           cue moves. A stationary bed is near 0.
  DC       mean sample value; anything above 1e-3 is an offset bug.
  SEAM     worst sample-to-sample jump inside the last/first 20 ms of a loop,
           relative to the loudest jump in the file. Loops must be < 0.30 or
           they click every time they wrap.
  LRA      loudness range over 100 ms windows, in dB.

Exit code is 1 when a hard rule is broken, so it can gate regeneration.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

import numpy as np
import soundfile as sf
from scipy.signal import stft

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO = os.path.join(ROOT, "assets", "audio")

# cues that are allowed to be noisy by nature, and how noisy they may be
NOISE_OK = {
    # interference on a camcorder tape is the one cue that *is* noise - but even
    # it must be modulated (structured dropouts), never a stationary hiss
    "static_loop.ogg": {"sfm_max": 0.85, "env_cv_min": 0.12},
}
# everything else is an object, a body, an instrument or an electrical machine
SFM_MAX_DEFAULT = 0.45
# looping beds must wrap without a click
LOOPS = {
    "wind_loop.ogg", "drone_loop.ogg", "static_loop.ogg", "heartbeat_loop.ogg",
    "breath_loop.ogg", "wire_hum_loop.ogg",
}


def analyse(path: str) -> dict:
    x, sr = sf.read(path)
    if x.ndim == 2:
        mono = x.mean(axis=1)
    else:
        mono = x
    n = len(mono)
    peak = float(np.max(np.abs(mono)) + 1e-12)
    rms = float(np.sqrt(np.mean(mono ** 2)) + 1e-12)

    f, _, Z = stft(mono, fs=sr, nperseg=512, noverlap=384)
    P = np.abs(Z) ** 2 + 1e-12
    band = (f >= 60) & (f <= 10000)
    Pb = P[band]
    fb = f[band]
    frame_e = Pb.sum(axis=0)
    thr = np.percentile(frame_e, 30) * 0.2 + 1e-12
    act = frame_e > thr
    if not act.any():
        act = np.ones_like(frame_e, dtype=bool)
    Pa = Pb[:, act]
    sfm = float(np.median(np.exp(np.mean(np.log(Pa), axis=0)) / np.mean(Pa, axis=0)))
    centroid = float(np.median((fb[:, None] * Pb[:, act]).sum(axis=0) / (Pb[:, act].sum(axis=0) + 1e-12)))

    w = min(n, 4096)
    best_i = max(range(0, max(1, n - w + 1), max(1, w // 4)),
                 key=lambda i: float(np.sum(mono[i:i + w] ** 2)))
    seg = mono[best_i:best_i + w] - float(np.mean(mono[best_i:best_i + w]))
    c = np.correlate(seg, seg, mode="full")[len(seg) - 1:]
    lo, hi = int(sr / 1800), min(len(c), int(sr / 40))
    tonal = float(np.max(c[lo:hi]) / (c[0] + 1e-9)) if hi > lo else 0.0

    crest = float(20.0 * np.log10(peak / rms))
    kurt = float(np.mean((mono / rms) ** 4))
    dc = float(np.mean(mono))

    win = max(1, int(0.010 * sr))
    frames = mono[:(n // win) * win].reshape(-1, win)
    env = np.sqrt(np.mean(frames ** 2, axis=1))
    env_cv = float(np.std(env) / (np.mean(env) + 1e-9))
    db = 20.0 * np.log10(env + 1e-9)
    lra = float(np.percentile(db, 95) - np.percentile(db, 10))

    # Loop seam: the jump from the last sample back to the first, measured
    # against an ordinary sample-to-sample step in the same file. 1.0 means the
    # wrap is indistinguishable from the signal continuing; anything above ~3
    # is an audible tick once per loop.
    d = np.abs(np.diff(mono))
    typical = float(np.mean(d) + 1e-9)
    seam = float(abs(mono[0] - mono[-1]) / typical)

    return {
        "file": os.path.basename(path),
        "dur": round(n / sr, 2),
        "peak_dbfs": round(20 * np.log10(peak), 1),
        "rms_dbfs": round(20 * np.log10(rms), 1),
        "crest_db": round(crest, 1),
        "lra_db": round(lra, 1),
        "sfm": round(sfm, 3),
        "tonal": round(tonal, 3),
        "centroid_hz": round(centroid, 0),
        "kurt": round(kurt, 1),
        "env_cv": round(env_cv, 2),
        "dc": round(dc, 5),
        "seam": round(seam, 2),
        "loop": os.path.basename(path) in LOOPS,
    }


def heartbeat_report(path: str) -> dict:
    """Physiology check for a heartbeat bed.

    Finds the S1/S2 pairs by onset, then reports the actual heart rate, the
    systolic interval and how much the RR intervals wander (respiratory sinus
    arrhythmia). A metronome scores RSA = 0.0 and an identical S1-S2 gap every
    beat; a real resting heart does not.
    """
    x, sr = sf.read(path)
    mono = x.mean(axis=1) if x.ndim == 2 else x
    # onset envelope: low band energy, 5 ms hops
    env = np.abs(sf_read_filter(mono, sr))
    hop = max(1, int(0.005 * sr))
    frames = env[: (len(env) // hop) * hop].reshape(-1, hop).max(axis=1)
    thresh = frames.max() * 0.22
    idx = np.nonzero(frames > thresh)[0]
    onsets: list[int] = []
    last = -999
    for i in idx:
        if (i - last) * hop > 0.055 * sr:
            onsets.append(i)
        last = i
    times = [i * hop / sr for i in onsets]
    # group into beats: an S1 is any sound that is followed by another within
    # 220-420 ms (the systolic interval); an S2 is one that is not
    beats: list[tuple[float, float]] = []
    k = 0
    while k < len(times):
        if k + 1 < len(times) and 0.16 < times[k + 1] - times[k] < 0.42:
            beats.append((times[k], times[k + 1]))
            k += 2
        else:
            k += 1
    s1 = [b[0] for b in beats]
    systoles = [b[1] - b[0] for b in beats]
    rr = np.diff(s1) if len(s1) > 1 else np.array([0.0])
    hr = 60.0 / float(np.median(rr)) if len(rr) and np.median(rr) > 0 else 0.0
    spec = np.abs(np.fft.rfft(mono))
    f = np.fft.rfftfreq(len(mono), 1.0 / sr)
    centroid = float((f * spec).sum() / (spec.sum() + 1e-9))
    return {
        "beats": len(beats),
        "bpm": round(hr, 1),
        "s1_s2_ms": round(1000 * float(np.median(systoles)), 0) if systoles else 0,
        "systole_spread_ms": round(1000 * float(np.ptp(systoles)), 1) if systoles else 0,
        "rsa_pct": round(100.0 * float(np.std(rr) / (np.mean(rr) + 1e-9)), 1) if len(rr) else 0.0,
        "centroid_hz": round(centroid, 0),
        "energy_below_200hz_pct": round(
            100.0 * float(spec[f <= 200].sum() / (spec.sum() + 1e-9)), 1),
    }


def sf_read_filter(mono, sr):
    """Chest-conducted energy: what a hand on the sternum would feel."""
    from scipy.signal import butter, sosfilt
    sos = butter(2, min(0.9, 180.0 / (sr / 2)), btype="low", output="sos")
    return sosfilt(sos, mono)


def verdict(r: dict) -> list[str]:
    out = []
    rule = NOISE_OK.get(r["file"], {})
    sfm_max = rule.get("sfm_max", SFM_MAX_DEFAULT)
    if r["sfm"] > sfm_max:
        out.append("noisy(SFM %.2f > %.2f)" % (r["sfm"], sfm_max))
    if "env_cv_min" in rule and r["env_cv"] < rule["env_cv_min"]:
        out.append("stationary(ENV_CV %.2f)" % r["env_cv"])
    if abs(r["dc"]) > 1e-3:
        out.append("dc %.4f" % r["dc"])
    if r["loop"] and r["seam"] > 3.0:
        out.append("seam %.2f" % r["seam"])
    if r["peak_dbfs"] > -0.1:
        out.append("clipping")
    if r["loop"] and r["dur"] < 1.0:
        out.append("short loop")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=AUDIO)
    ap.add_argument("--json")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.dir, "*.ogg")))
    if not files:
        print("no .ogg files in", args.dir)
        return 2
    rows = [analyse(p) for p in files]
    bad = 0
    if not args.quiet:
        hdr = ("file", "dur", "rms", "crest", "lra", "SFM", "tonal", "cent", "kurt", "envCV", "seam", "notes")
        print("%-19s %5s %6s %6s %5s %6s %6s %6s %6s %6s %5s  %s" % hdr)
        print("-" * 118)
        for r in rows:
            v = verdict(r)
            bad += 1 if v else 0
            print("%-19s %5.2f %6.1f %6.1f %5.1f %6.3f %6.3f %6.0f %6.1f %6.2f %5.2f  %s"
                  % (r["file"], r["dur"], r["rms_dbfs"], r["crest_db"], r["lra_db"],
                     r["sfm"], r["tonal"], r["centroid_hz"], r["kurt"], r["env_cv"],
                     r["seam"], ", ".join(v)))
        print("-" * 118)
        print("%d streams, %d flagged" % (len(rows), bad))
        for p in files:
            if "heartbeat" in os.path.basename(p):
                hb = heartbeat_report(p)
                print("  %-24s %d beats, %.0f bpm, S1-S2 %.0f ms (+-%.0f ms), RSA %.1f%%, "
                      "centroid %.0f Hz, %.0f%% of the energy below 200 Hz"
                      % (os.path.basename(p), hb["beats"], hb["bpm"], hb["s1_s2_ms"],
                         hb["systole_spread_ms"], hb["rsa_pct"], hb["centroid_hz"],
                         hb["energy_below_200hz_pct"]))
    if args.json:
        with open(args.json, "w") as fp:
            json.dump(rows, fp, indent=2)
        print("wrote", args.json)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
