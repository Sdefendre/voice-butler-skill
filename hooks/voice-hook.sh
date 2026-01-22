#!/bin/bash
# Voice notification hook - Kokoro TTS with British butler voice
# Works with both Claude Code and OpenAI Codex
# Optimized: concatenates opener + summary for seamless playback at 1.5x speed

[ ! -f ~/.claude/voice-enabled ] && exit 0

CACHE_DIR="$HOME/.claude/voice-cache"
TMPFILE=$(mktemp)

# Handle input from either stdin (Claude Code) or command arg (Codex)
if [ -n "$1" ] && [ "$1" != "-" ]; then
    # Codex passes JSON as first argument
    echo "$1" > "$TMPFILE"
else
    # Claude Code pipes JSON to stdin
    cat > "$TMPFILE"
fi

# Single Python script: get summary, generate TTS, concatenate, play - all in one for speed
python3 - "$TMPFILE" "$CACHE_DIR" << 'PY'
import sys, json, re, random, subprocess, wave, os, tempfile

OPENER_COUNT = 12

BUTLER_CLOSERS = {
    "default": [
        "Will there be anything else?",
        "Shall I attend to anything further?",
        "Is there anything more you require?",
        "At your service should you need more.",
        "Do let me know if you need anything else.",
        "I remain at your disposal.",
        "Anything else I can assist with?",
    ],
    "file_created": [
        "The file awaits your review.",
        "You'll find it ready for you.",
        "Shall I make any adjustments?",
        "Do review it at your leisure.",
    ],
    "file_edited": [
        "The changes have been applied.",
        "Shall I refine it further?",
        "Do let me know if it needs adjustment.",
    ],
    "error_fixed": [
        "The issue has been resolved.",
        "That should sort things out.",
        "Shall I run any tests to confirm?",
    ],
    "search": [
        "Shall I dig deeper?",
        "Would you like more details on any of these?",
        "I can investigate further if needed.",
    ],
}

def get_closer(text):
    text_lower = text.lower() if text else ""
    if any(w in text_lower for w in ["created", "wrote", "written", "new file"]):
        return random.choice(BUTLER_CLOSERS["file_created"])
    elif any(w in text_lower for w in ["edited", "updated", "modified", "changed"]):
        return random.choice(BUTLER_CLOSERS["file_edited"])
    elif any(w in text_lower for w in ["fixed", "resolved", "corrected", "error", "bug"]):
        return random.choice(BUTLER_CLOSERS["error_fixed"])
    elif any(w in text_lower for w in ["found", "search", "results", "matches", "located"]):
        return random.choice(BUTLER_CLOSERS["search"])
    else:
        return random.choice(BUTLER_CLOSERS["default"])

def summarize(text):
    for pat, rep in [(r'\[([^\]]+)\]\([^)]+\)', r'\1'), (r'\*\*([^*]+)\*\*', r'\1'),
                     (r'\*([^*]+)\*', r'\1'), (r'`[^`]+`', ''), (r'```[\s\S]*?```', ''),
                     (r'^#+\s+', ''), (r'^[-*]\s+', ''), (r'\n+', ' '), (r'\s+', ' ')]:
        text = re.sub(pat, rep, text, flags=re.MULTILINE)
    text = text.strip()
    if not text: return "Task completed."
    sentences = re.split(r'[.!?]+', text)
    sentences = [s.strip() for s in sentences if s.strip()]
    if len(sentences) >= 2:
        summary = f"{sentences[0]}. {sentences[-1]}" if sentences[0] != sentences[-1] else sentences[0]
    elif sentences:
        summary = sentences[0]
    else:
        summary = "Task completed"
    words = summary.split()[:40]
    return ' '.join(words) + ('.' if not summary.endswith('.') else '')

def concat_wavs(wav_files, output_path):
    """Concatenate WAV files into one seamless file"""
    data = []
    params = None
    for wav_file in wav_files:
        with wave.open(wav_file, 'rb') as w:
            if params is None:
                params = w.getparams()
            data.append(w.readframes(w.getnframes()))
    with wave.open(output_path, 'wb') as out:
        out.setparams(params)
        for d in data:
            out.writeframes(d)

def get_assistant_message(data):
    """Extract assistant message from either Claude Code or Codex format"""

    # Codex format: has "last-assistant-message" or "last_assistant_message" directly
    if "last-assistant-message" in data:
        return data["last-assistant-message"]
    if "last_assistant_message" in data:
        return data["last_assistant_message"]

    # Codex format: check for type field
    if data.get("type") == "agent-turn-complete":
        return data.get("last-assistant-message", "") or data.get("last_assistant_message", "")

    # Claude Code format: has transcript_path pointing to JSONL file
    tp = data.get('transcript_path', '')
    if tp and os.path.exists(tp):
        last = None
        with open(tp) as f:
            for line in f:
                try:
                    e = json.loads(line.strip())
                    if e.get('type') == 'assistant':
                        for b in e.get('message', {}).get('content', []):
                            if b.get('type') == 'text' and b.get('text', '').strip():
                                last = b['text'].strip()
                except: pass
        return last

    return None

try:
    input_file = sys.argv[1]
    cache_dir = sys.argv[2]

    with open(input_file) as f:
        data = json.load(f)

    opener_idx = random.randint(1, OPENER_COUNT)
    opener_file = os.path.join(cache_dir, f"opener_{opener_idx:02d}_000.wav")

    # Get last assistant message (works for both Claude Code and Codex)
    last = get_assistant_message(data)

    # Build summary text
    if last:
        summary_text = f"{summarize(last)} {get_closer(last)}"
    else:
        summary_text = get_closer('')

    # Generate summary audio
    tmp_dir = tempfile.mkdtemp()
    summary_prefix = os.path.join(tmp_dir, "summary")

    subprocess.run([
        "python3", "-m", "mlx_audio.tts.generate",
        "--model", "mlx-community/Kokoro-82M-bf16",
        "--text", summary_text,
        "--voice", "bm_george",
        "--lang_code", "b",
        "--speed", "1.3",
        "--file_prefix", summary_prefix
    ], capture_output=True)

    summary_file = f"{summary_prefix}_000.wav"

    # Concatenate opener + summary
    final_audio = os.path.join(tmp_dir, "final.wav")
    if os.path.exists(opener_file) and os.path.exists(summary_file):
        concat_wavs([opener_file, summary_file], final_audio)
        # Play at 1.5x speed for snappiness
        subprocess.run(["afplay", "-r", "1.5", final_audio])
    elif os.path.exists(summary_file):
        subprocess.run(["afplay", "-r", "1.5", summary_file])

    # Cleanup
    import shutil
    shutil.rmtree(tmp_dir, ignore_errors=True)

except Exception as e:
    # Fallback: just say something using system voice
    subprocess.run(["say", "-v", "Daniel", "Task complete, sir."])
PY

rm -f "$TMPFILE"
exit 0
