#!/opt/homebrew/bin/python3.11
"""
Generate pre-cached butler opener audio files for the voice skill.
These are cached for instant playback without TTS latency.
"""

import subprocess
import os

CACHE_DIR = os.path.expanduser("~/.claude/voice-cache")
os.makedirs(CACHE_DIR, exist_ok=True)

OPENERS = [
    "Very good, sir.",
    "All done, sir.",
    "Completed as requested, sir.",
    "That's been taken care of, sir.",
    "Right away, sir. Done.",
    "As you wish, sir.",
    "Splendid, sir.",
    "Indeed, sir.",
    "At once, sir. Finished.",
    "Certainly, sir.",
    "Of course, sir.",
    "Consider it done, sir.",
]

print(f"Generating {len(OPENERS)} butler openers...")
print(f"Cache directory: {CACHE_DIR}")
print()

for idx, opener in enumerate(OPENERS, 1):
    prefix = os.path.join(CACHE_DIR, f"opener_{idx:02d}")
    output_file = f"{prefix}_000.wav"

    if os.path.exists(output_file):
        print(f"  [{idx:02d}] Already exists: {opener}")
        continue

    print(f"  [{idx:02d}] Generating: {opener}")

    try:
        subprocess.run([
            "/opt/homebrew/bin/python3.11", "-m", "mlx_audio.tts.generate",
            "--model", "mlx-community/Kokoro-82M-bf16",
            "--text", opener,
            "--voice", "bm_george",
            "--lang_code", "b",
            "--speed", "1.3",
            "--file_prefix", prefix
        ], capture_output=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"    Error generating opener {idx}: {e}")
    except FileNotFoundError:
        print("    Error: mlx-audio not installed. Run: pip3 install mlx-audio")
        break

print()
print("Done! Cached openers are ready.")
