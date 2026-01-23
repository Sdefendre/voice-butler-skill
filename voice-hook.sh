#!/bin/bash
# Voice notification hook - reads and summarizes assistant output
# Runs in background for zero latency

[ ! -f ~/.claude/voice-enabled ] && exit 0

TMPFILE=$(mktemp)
DEBOUNCE_MS="${VOICE_DEBOUNCE_MS:-300}"
DEBOUNCE_STATE="${VOICE_DEBOUNCE_FILE:-/tmp/voice-hook.debounce}"
DEBUG_LOG="/tmp/voice-hook-debug.log"
MAX_LOG_SIZE="${VOICE_LOG_MAX_KB:-100}"  # KB, default 100KB

# Rotate log if too large (keep last 50 lines)
if [ -f "$DEBUG_LOG" ] && [ "$(stat -f%z "$DEBUG_LOG" 2>/dev/null || echo 0)" -gt "$((MAX_LOG_SIZE * 1024))" ]; then
    tail -50 "$DEBUG_LOG" > "${DEBUG_LOG}.tmp" && mv "${DEBUG_LOG}.tmp" "$DEBUG_LOG"
fi

# Handle input from stdin (Claude Code) or command arg (Codex)
if [ -n "$1" ] && [ "$1" != "-" ]; then
    echo "$1" > "$TMPFILE"
    echo "[$(date)] Received via arg: $1" >> "$DEBUG_LOG"
else
    cat > "$TMPFILE"
    echo "[$(date)] Received via stdin:" >> "$DEBUG_LOG"
    cat "$TMPFILE" >> "$DEBUG_LOG"
    echo "" >> "$DEBUG_LOG"
fi

run_tts() {
/opt/homebrew/bin/python3.11 - "$TMPFILE" << 'PY'
import sys, json, re, subprocess, os, tempfile

MAX_WORDS = int(os.getenv("MAX_WORDS", "30"))  # Shorter = faster
PLAYBACK_SPEED = float(os.getenv("SPEED", "1.5"))
VOICE = os.getenv("VOICE", "jean")

def get_message(data):
    """Extract assistant message from Claude Code or Codex"""
    # Codex format
    for key in ["last-assistant-message", "last_assistant_message"]:
        if key in data:
            return data[key]
    if data.get("type") == "agent-turn-complete":
        return data.get("last-assistant-message", "") or data.get("last_assistant_message", "")

    # Claude Code format - read transcript
    tp = data.get('transcript_path', '')
    if tp and os.path.exists(tp):
        def has_text_content(event):
            """Check if assistant event has actual text content (not just tool_use/thinking)."""
            for b in event.get('message', {}).get('content', []):
                if b.get('type') == 'text' and b.get('text', '').strip():
                    return True
            return False

        def last_assistant_event_with_text(path):
            """Scan from end of JSONL transcript to find most recent assistant event WITH text."""
            with open(path, 'rb') as f:
                f.seek(0, os.SEEK_END)
                pos = f.tell()
                buf = b''
                while pos > 0:
                    read_size = min(4096, pos)
                    pos -= read_size
                    f.seek(pos)
                    chunk = f.read(read_size)
                    buf = chunk + buf
                    lines = buf.split(b'\n')
                    buf = lines[0]
                    for line in reversed(lines[1:]):
                        if not line.strip():
                            continue
                        try:
                            e = json.loads(line.decode('utf-8', 'ignore'))
                        except:
                            continue
                        # Only return assistant events that have text content
                        if e.get('type') == 'assistant' and has_text_content(e):
                            return e
                if buf.strip():
                    try:
                        e = json.loads(buf.decode('utf-8', 'ignore'))
                        if e.get('type') == 'assistant' and has_text_content(e):
                            return e
                    except:
                        pass
            return None

        e = last_assistant_event_with_text(tp)
        if e:
            texts = []
            for b in e.get('message', {}).get('content', []):
                if b.get('type') == 'text' and b.get('text', '').strip():
                    texts.append(b['text'].strip())
            if texts:
                return ' '.join(texts)
    return None

def summarize(text):
    """Clean and summarize the output for speech"""
    if not text or not text.strip():
        return "Done."

    # Remove preamble and filler phrases
    for pat in [
        r"Let me (?:read|check|look at|search|run|examine|inspect|review)[^.]*\.",
        r"I'll (?:read|check|look at|search|run)[^.]*\.",
        r"Reading (?:the )?file[^.]*\.",
        r"Looking at[^.]*\.",
        r"^I (?:have |'ve )?",  # "I have updated" -> "updated"
        r"^I'm ",
        r"^The file has been ",
        r"^This ",
    ]:
        text = re.sub(pat, '', text, flags=re.IGNORECASE | re.MULTILINE)

    # Strip markdown
    text = re.sub(r'```[\s\S]*?```', '', text)  # code blocks
    text = re.sub(r'`([^`]+)`', r'\1', text)    # inline code
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)  # links
    text = re.sub(r'\*\*([^*]+)\*\*', r'\1', text)  # bold
    text = re.sub(r'\*([^*]+)\*', r'\1', text)  # italic
    text = re.sub(r'^#+\s+', '', text, flags=re.MULTILINE)  # headers
    text = re.sub(r'^\s*[-*]\s+', '', text, flags=re.MULTILINE)  # bullets
    text = re.sub(r'\n+', ' ', text)  # newlines
    text = re.sub(r'\s+', ' ', text).strip()  # whitespace

    if not text:
        return "Task completed."

    if len(text) < 10:
        # Keep short messages as-is (after cleanup)
        summary = text
        if summary and summary[-1] not in '.!?':
            summary += '.'
        return summary

    # Cut off suggestion/next-step sections
    for cut in ["next steps", "suggestions", "if you want", "would you like", "want me to"]:
        idx = text.lower().find(cut)
        if idx != -1:
            text = text[:idx].strip()
            break

    # Split into sentences
    sentences = re.split(r'(?<=[.!?])\s+', text)
    sentences = [s.strip() for s in sentences if s.strip() and len(s) > 5]

    # Remove questions
    sentences = [s for s in sentences if not s.endswith('?')]

    if not sentences:
        return "Task completed."

    # Prioritize action sentences (created, updated, fixed, etc.)
    action_words = r'\b(created|updated|fixed|added|removed|installed|configured|pushed|committed|completed|edited|modified|resolved)\b'
    action_sentences = [s for s in sentences if re.search(action_words, s, re.I)]
    other_sentences = [s for s in sentences if not re.search(action_words, s, re.I)]

    # Speak only the first action sentence when available
    ordered = action_sentences if action_sentences else (action_sentences + other_sentences)
    summary = ordered[0] if ordered else sentences[0]

    # Enforce word limit on the single sentence
    words = summary.split()
    if len(words) > MAX_WORDS:
        summary = ' '.join(words[:MAX_WORDS])

    # Capitalize first letter
    if summary:
        summary = summary[0].upper() + summary[1:]

    if summary and summary[-1] not in '.!?':
        summary += '.'

    return summary

try:
    with open(sys.argv[1]) as f:
        raw = f.read()

    message = None
    try:
        data = json.loads(raw)
        message = get_message(data)
    except json.JSONDecodeError:
        message = raw.strip()

    if not message and raw.strip():
        message = raw.strip()

    text = summarize(message) if message else "Done."

    # Debug logging
    debug_log = "/tmp/voice-hook-debug.log"
    with open(debug_log, "a") as f:
        f.write(f"[TTS] raw message: {message[:200] if message else 'None'}...\n")
        f.write(f"[TTS] summarized to: {text}\n")

    # Generate to temp file and play with afplay (--play/--stream hang)
    with tempfile.TemporaryDirectory() as tdir:
        out_file = os.path.join(tdir, "voice.wav")
        subprocess.run([
            "/opt/homebrew/bin/python3.11", "-m", "mlx_audio.tts.generate",
            "--model", "mlx-community/pocket-tts",
            "--text", text,
            "--voice", VOICE,
            "--speed", str(PLAYBACK_SPEED),
            "--output_path", tdir,
            "--file_prefix", "voice"
        ], capture_output=True, cwd=tdir)
        wav_file = os.path.join(tdir, "voice_000.wav")
        if os.path.exists(wav_file):
            subprocess.run(["afplay", wav_file])

except:
    subprocess.run(["say", "Done."])
PY
}

# Run in background so stop hook returns immediately
if [ "${VOICE_ASYNC:-1}" = "1" ]; then
    TOKEN="$(date +%s%N)-$$"
    printf "%s" "$TOKEN" > "$DEBOUNCE_STATE" 2>/dev/null || true
    (
        echo "[$(date)] Starting background TTS process, token=$TOKEN"
        if [ "${DEBOUNCE_MS:-0}" != "0" ] && [ "${DEBOUNCE_MS:-0}" != "0.0" ]; then
            sleep "$(awk "BEGIN { printf \"%.3f\", ${DEBOUNCE_MS}/1000 }")"
            CURRENT_TOKEN="$(cat "$DEBOUNCE_STATE" 2>/dev/null)"
            if [ "$CURRENT_TOKEN" != "$TOKEN" ]; then
                echo "[$(date)] Debounce: token mismatch, exiting (expected=$TOKEN, got=$CURRENT_TOKEN)"
                exit 0
            fi
        fi
        echo "[$(date)] Running TTS..."
        run_tts
        echo "[$(date)] TTS completed"
        rm -f "$TMPFILE"
    ) >>"$DEBUG_LOG" 2>&1 </dev/null &
    disown || true
else
    run_tts
    rm -f "$TMPFILE"
fi

exit 0
