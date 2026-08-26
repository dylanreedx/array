#!/usr/bin/env python3
"""Deterministically synthesize Array's short, original agent sound library."""

from __future__ import annotations

import json
import argparse
import io
import math
import random
import struct
import wave
from pathlib import Path

RATE = 44_100
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Resources" / "AgentSounds"

# id, display name, family, duration, base Hz, recipe, semitone phrase
SOUNDS = [
    ("prism", "Prism", "glass", 0.72, 784.0, "glass", [0, 7, 12]),
    ("dewdrop", "Dewdrop", "glass", 0.46, 988.0, "drop", [0, -5]),
    ("aurora", "Aurora", "glass", 0.96, 523.25, "shimmer", [0, 4, 7, 12]),
    ("beacon", "Beacon", "glass", 0.64, 659.25, "pulse", [0, 0, 7]),
    ("sprout", "Sprout", "organic", 0.42, 392.0, "pluck", [0, 4]),
    ("acorn", "Acorn", "organic", 0.36, 329.63, "wood", [0]),
    ("pluck", "Pluck", "organic", 0.52, 440.0, "pluck", [0, 7, 12]),
    ("marimba", "Marimba", "organic", 0.78, 261.63, "wood", [0, 7, 12]),
    ("pixel", "Pixel", "digital", 0.30, 880.0, "square", [0, 12]),
    ("orbit", "Orbit", "digital", 0.70, 440.0, "orbit", [0, 7, 12]),
    ("warp", "Warp", "digital", 0.88, 220.0, "sweep", [0, 12]),
    ("radar", "Radar", "digital", 0.82, 587.33, "pulse", [0, -3, -7]),
    ("cloud", "Cloud", "soft", 0.88, 329.63, "soft", [0, 7]),
    ("pebble", "Pebble", "soft", 0.34, 523.25, "drop", [0]),
    ("ripple", "Ripple", "soft", 1.05, 392.0, "ripple", [0, 4, 7]),
    ("hush", "Hush", "soft", 0.58, 293.66, "hush", [0]),
    ("pop", "Pop", "energetic", 0.27, 523.25, "pop", [0]),
    ("spark", "Spark", "energetic", 0.44, 659.25, "spark", [0, 12]),
    ("bloom", "Bloom", "energetic", 0.82, 523.25, "bloom", [0, 4, 7, 12]),
    ("victory", "Victory", "energetic", 1.16, 392.0, "bloom", [0, 4, 7, 12, 16]),
]


def envelope(t: float, duration: float, attack: float = 0.012, decay: float = 3.2) -> float:
    return min(1.0, t / attack) * math.exp(-decay * t / duration)


def synth(sound_id: str, duration: float, base: float, recipe: str, phrase: list[int]) -> list[float]:
    count = int(duration * RATE)
    rng = random.Random(sound_id)
    out: list[float] = []
    phrase_span = duration / len(phrase)
    phase = 0.0
    for index in range(count):
        t = index / RATE
        note_index = min(len(phrase) - 1, int(t / phrase_span))
        local = t - note_index * phrase_span
        hz = base * (2 ** (phrase[note_index] / 12))
        env = envelope(local, phrase_span, decay=3.0 if recipe not in {"soft", "hush", "ripple"} else 1.7)
        phase += 2 * math.pi * hz / RATE
        sine = math.sin(phase)
        if recipe == "glass":
            value = env * (0.70 * sine + 0.22 * math.sin(phase * 2.01) + 0.08 * math.sin(phase * 3.98))
        elif recipe == "drop":
            bend = 1.0 + 1.1 * math.exp(-local * 28)
            value = env * math.sin(phase * bend)
        elif recipe == "shimmer":
            value = env * (0.62 * sine + 0.22 * math.sin(phase * 2.5) + 0.12 * math.sin(phase * 4.1))
        elif recipe == "pulse":
            tremolo = 0.55 + 0.45 * math.sin(2 * math.pi * 5.5 * local) ** 2
            value = env * tremolo * (0.82 * sine + 0.18 * math.sin(phase * 2))
        elif recipe == "pluck":
            value = env * (0.72 * sine + 0.20 * math.sin(phase * 2) + 0.08 * math.sin(phase * 3))
        elif recipe == "wood":
            value = env * (0.78 * sine + 0.16 * math.sin(phase * 3.02) + 0.04 * (rng.random() * 2 - 1))
        elif recipe == "square":
            value = env * (0.70 * (1 if sine >= 0 else -1) + 0.30 * math.sin(phase * 0.5))
        elif recipe == "orbit":
            pan = math.sin(2 * math.pi * 2.2 * t)
            value = env * (0.72 * math.sin(phase + pan) + 0.28 * math.sin(phase * 1.5 - pan))
        elif recipe == "sweep":
            swept = phase * (0.55 + 1.5 * t / duration)
            value = envelope(t, duration, decay=1.3) * (0.8 * math.sin(swept) + 0.2 * math.sin(swept * 2))
        elif recipe == "soft":
            value = env * (0.86 * sine + 0.14 * math.sin(phase * 0.5))
        elif recipe == "ripple":
            value = env * sine * (0.65 + 0.35 * math.cos(2 * math.pi * 6 * local))
        elif recipe == "hush":
            noise = (rng.random() * 2 - 1) * math.exp(-4 * t / duration)
            value = 0.65 * env * sine + 0.18 * noise
        elif recipe == "pop":
            value = env * math.sin(phase * (1.8 - 1.1 * t / duration))
        elif recipe == "spark":
            noise = (rng.random() * 2 - 1) * math.exp(-16 * local)
            value = env * (0.75 * sine + 0.25 * noise)
        else:  # bloom
            value = env * (0.66 * sine + 0.24 * math.sin(phase * 2) + 0.10 * math.sin(phase * 3))
        out.append(value)

    fade = int(0.010 * RATE)
    for i in range(fade):
        out[i] *= i / fade
        out[-1 - i] *= i / fade
    peak = max(abs(sample) for sample in out) or 1.0
    return [sample * 0.86 / peak for sample in out]


def write_wave(path: Path, samples: list[float]) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(b"".join(struct.pack("<h", round(sample * 32767)) for sample in samples))


def wave_bytes(samples: list[float]) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(b"".join(struct.pack("<h", round(sample * 32767)) for sample in samples))
    return buffer.getvalue()


def verify(directory: Path) -> None:
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    expected_ids = [sound[0] for sound in SOUNDS]
    assert [entry["id"] for entry in manifest] == expected_ids, "sound manifest IDs/order drifted"
    assert len(list(directory.glob("*.wav"))) == len(SOUNDS), "sound asset count drifted"
    for sound_id, name, family, duration, base, recipe, phrase in SOUNDS:
        entry = next(item for item in manifest if item["id"] == sound_id)
        assert entry["name"] == name and entry["family"] == family
        path = directory / entry["filename"]
        expected = wave_bytes(synth(sound_id, duration, base, recipe, phrase))
        assert path.read_bytes() == expected, f"{sound_id} is not reproducible"
        with wave.open(str(path), "rb") as source:
            assert source.getnchannels() == 1 and source.getsampwidth() == 2
            assert source.getframerate() == RATE
            actual_duration = source.getnframes() / RATE
            assert 0.25 <= actual_duration <= 1.2
            frames = source.readframes(source.getnframes())
            samples = struct.unpack(f"<{len(frames) // 2}h", frames)
            assert max(abs(value) for value in samples) < 32767
            assert abs(samples[0]) <= 1 and abs(samples[-1]) <= 1
    print(f"Verified {len(SOUNDS)} reproducible sounds in {directory}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", type=Path, metavar="DIRECTORY")
    args = parser.parse_args()
    if args.check:
        verify(args.check)
        return
    OUTPUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for sound_id, name, family, duration, base, recipe, phrase in SOUNDS:
        filename = f"{sound_id}.wav"
        write_wave(OUTPUT / filename, synth(sound_id, duration, base, recipe, phrase))
        manifest.append({
            "id": sound_id,
            "name": name,
            "family": family,
            "filename": filename,
            "duration": duration,
            "imported": False,
        })
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {len(manifest)} sounds in {OUTPUT}")


if __name__ == "__main__":
    main()
