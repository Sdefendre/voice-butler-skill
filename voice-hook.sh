#!/bin/bash
# Voice hook - reads output aloud using Kokoro TTS
# Works with Claude Code, OpenAI Codex, and Gemini CLI

[ ! -f ~/.claude/voice-enabled ] && exit 0

TMPFILE=$(mktemp)

# Codex passes JSON as argv[1], Claude Code and Gemini pipe to stdin
if [ -n "$1" ] && [ "$1" != "-" ]; then
    echo "$1" > "$TMPFILE"
else
    cat > "$TMPFILE"
fi

/opt/homebrew/bin/python3.11 - "$TMPFILE" << 'PY'
import sys, json, os, re, subprocess, tempfile, shutil

def get_text_and_source(data):
    # Codex: direct field
    for key in ("last-assistant-message", "last_assistant_message"):
        if data.get(key):
            return data[key], "codex"

    # Gemini: direct field
    if data.get("prompt_response"):
        return data["prompt_response"], "gemini"

    # Claude Code: parse transcript JSONL
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
        return last, "claude"
    return None, None

def clean(text):
    for pat, rep in [(r'```[\s\S]*?```', ''), (r'\[([^\]]+)\]\([^)]+\)', r'\1'),
                     (r'\*\*([^*]+)\*\*', r'\1'), (r'\*([^*]+)\*', r'\1'),
                     (r'`[^`]+`', ''), (r'^#+\s+', ''), (r'^[-*]\s+', ''),
                     (r'\n+', ' '), (r'\s+', ' ')]:
        text = re.sub(pat, rep, text, flags=re.MULTILINE)
    return text.strip()

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)

    text, source = get_text_and_source(data)
    if not text:
        sys.exit(0)

    text = clean(text)
    if not text:
        sys.exit(0)

    # Different voice per CLI
    if source == "codex":
        voice, lang = "am_adam", "a"
    else:
        voice, lang = "bm_george", "b"

    tmp_dir = tempfile.mkdtemp()
    prefix = os.path.join(tmp_dir, "out")

    subprocess.run([
        "/opt/homebrew/bin/python3.11", "-m", "mlx_audio.tts.generate",
        "--model", "mlx-community/Kokoro-82M-bf16",
        "--text", text,
        "--voice", voice,
        "--lang_code", lang,
        "--speed", "1.3",
        "--file_prefix", prefix
    ], capture_output=True)

    wav = f"{prefix}_000.wav"
    if os.path.exists(wav):
        subprocess.run(["afplay", "-r", "1.5", wav])

    shutil.rmtree(tmp_dir, ignore_errors=True)
except:
    pass
PY

rm -f "$TMPFILE"
exit 0
