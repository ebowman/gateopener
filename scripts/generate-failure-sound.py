#!/usr/bin/env python3
"""Generates iOS/Resources/gate-failed.caf, the notification sound for a
failed gate open: a short (~0.6s) two-tone DESCENDING pair, clearly unlike
the default chime. Writes a WAV to a temp dir, then converts with afconvert.

Usage: python3 scripts/generate-failure-sound.py   (macOS only: needs afconvert)
"""
import math, os, struct, subprocess, tempfile, wave

RATE = 44100
# (frequency Hz, duration s): high tone then lower tone.
TONES = [(880.0, 0.28), (587.33, 0.32)]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "iOS", "Resources", "gate-failed.caf")

def tone(freq, dur):
    n = int(RATE * dur)
    attack, release = int(RATE * 0.01), int(RATE * 0.08)
    out = []
    for i in range(n):
        env = min(1.0, i / attack, (n - i) / release)
        s = math.sin(2 * math.pi * freq * i / RATE) + 0.3 * math.sin(4 * math.pi * freq * i / RATE)
        out.append(int(max(-1, min(1, 0.45 * env * s / 1.3)) * 32767))
    return out

samples = []
for f, d in TONES:
    samples += tone(f, d)

with tempfile.TemporaryDirectory() as tmp:
    wav = os.path.join(tmp, "gate-failed.wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", s) for s in samples))
    subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", wav, os.path.normpath(OUT)], check=True)
print("wrote", os.path.normpath(OUT))
