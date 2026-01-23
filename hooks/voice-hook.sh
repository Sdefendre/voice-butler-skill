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

# Configurable settings via environment variables
VOICE = os.environ.get('CLAUDE_VOICE', 'bm_george')
SPEED = float(os.environ.get('CLAUDE_VOICE_SPEED', '1.3'))
PLAYBACK_SPEED = float(os.environ.get('CLAUDE_PLAYBACK_SPEED', '1.5'))
MAX_SUMMARY_WORDS = int(os.environ.get('CLAUDE_SUMMARY_WORDS', '100'))
OPENER_COUNT = int(os.environ.get('CLAUDE_OPENER_COUNT', '12'))

# Debug logging
DEBUG = os.path.exists(os.path.expanduser('~/.claude/voice-debug'))
def debug(msg):
    if DEBUG:
        with open('/tmp/voice-hook.log', 'a') as f:
            import datetime
            f.write(f"[{datetime.datetime.now().isoformat()}] {msg}\n")

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

def summarize(text, max_words=None):
    """Smart summarization: find key actions and build a coherent summary."""
    if max_words is None:
        max_words = MAX_SUMMARY_WORDS

    # Handle empty/very short messages
    if not text or len(text.strip()) < 10:
        return "Done."

    # Skip redundant tool-related preamble text
    skip_patterns = [
        r"Let me (?:read|check|look at|search|run|examine|inspect|review).*?\.",
        r"I'll (?:read|check|look at|search|run|examine|inspect|review).*?\.",
        r"Reading (?:the )?file.*?\.",
        r"Searching (?:for|the).*?\.",
        r"Looking at.*?\.",
        r"Let me (?:first )?(?:understand|see|find).*?\.",
    ]
    for pat in skip_patterns:
        text = re.sub(pat, '', text, flags=re.IGNORECASE)

    # Handle bullet lists specially before stripping
    bullet_match = re.search(r'(.*?:)?\s*\n?((?:[-*•]\s+.+\n?)+)', text, re.MULTILINE)
    if bullet_match:
        prefix = bullet_match.group(1) or ""
        items_block = bullet_match.group(2)
        items = re.findall(r'[-*•]\s+(.+?)(?:\n|$)', items_block)
        items = [item.strip().rstrip('.') for item in items if item.strip()]
        if items:
            # Join with commas and "and" for natural speech
            if len(items) == 1:
                list_summary = items[0]
            elif len(items) == 2:
                list_summary = f"{items[0]} and {items[1]}"
            else:
                list_summary = ', '.join(items[:-1]) + f', and {items[-1]}'
            # Add prefix if short enough
            if prefix and len(prefix.split()) <= 4:
                return f"{prefix.strip()} {list_summary}."
            return list_summary[0].upper() + list_summary[1:] + '.'

    # Handle numbered lists
    numbered_match = re.search(r'(.*?:)?\s*\n?((?:\d+[.)]\s+.+\n?)+)', text, re.MULTILINE)
    if numbered_match:
        prefix = numbered_match.group(1) or ""
        items_block = numbered_match.group(2)
        items = re.findall(r'\d+[.)]\s+(.+?)(?:\n|$)', items_block)
        items = [item.strip().rstrip('.') for item in items if item.strip()]
        if items:
            if len(items) == 1:
                list_summary = items[0]
            elif len(items) == 2:
                list_summary = f"{items[0]} and {items[1]}"
            else:
                list_summary = ', '.join(items[:-1]) + f', and {items[-1]}'
            if prefix and len(prefix.split()) <= 4:
                return f"{prefix.strip()} {list_summary}."
            return list_summary[0].upper() + list_summary[1:] + '.'

    # Strip markdown formatting
    for pat, rep in [
        (r'```[\s\S]*?```', ''),           # code blocks
        (r'`([^`]+)`', r'\1'),             # inline code -> keep text
        (r'\[([^\]]+)\]\([^)]+\)', r'\1'), # links -> text only
        (r'\*\*([^*]+)\*\*', r'\1'),       # bold
        (r'\*([^*]+)\*', r'\1'),           # italic
        (r'^#+\s+', ''),                   # headers
        (r'^[-*]\s+', ''),                 # list items
        (r'\n+', ' '),                     # newlines to space
        (r'\s+', ' '),                     # collapse whitespace
    ]:
        text = re.sub(pat, rep, text, flags=re.MULTILINE)

    text = text.strip()
    if not text:
        return "Task completed."

    # Split into sentences
    sentences = re.split(r'(?<=[.!?])\s+', text)
    sentences = [s.strip() for s in sentences if s.strip() and len(s) > 5]

    if not sentences:
        return "Task completed."

    # Action verbs ranked by importance (most descriptive first)
    actions = [
        (r'\b(created|wrote|generated|added)\b', 'created'),
        (r'\b(edited|updated|modified|changed|refactored)\b', 'updated'),
        (r'\b(fixed|resolved|corrected|repaired)\b', 'fixed'),
        (r'\b(deleted|removed|cleared)\b', 'removed'),
        (r'\b(found|located|discovered|identified)\b', 'found'),
        (r'\b(installed|configured|set up)\b', 'configured'),
        (r'\b(tested|verified|confirmed|validated)\b', 'verified'),
        (r'\b(moved|renamed|copied)\b', 'moved'),
    ]

    # Find the most important action sentence
    best_sentence = None
    best_priority = len(actions) + 1

    for sent in sentences:
        sent_lower = sent.lower()
        for priority, (pattern, _) in enumerate(actions):
            if re.search(pattern, sent_lower):
                if priority < best_priority:
                    best_priority = priority
                    best_sentence = sent
                break

    # Use action sentence, or fall back to first sentence
    chosen = best_sentence if best_sentence else sentences[0]

    # Trim to max words while keeping coherent
    words = chosen.split()
    if len(words) > max_words:
        # Try to cut at a natural break
        truncated = ' '.join(words[:max_words])
        # Find last comma or conjunction to cut cleanly
        for delim in [', ', ' and ', ' but ', ' or ']:
            if delim in truncated:
                truncated = truncated.rsplit(delim, 1)[0]
                break
        chosen = truncated + '.'

    # Ensure ends with punctuation
    if chosen and chosen[-1] not in '.!?':
        chosen += '.'

    return chosen

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
        last_message_texts = []
        with open(tp) as f:
            for line in f:
                try:
                    e = json.loads(line.strip())
                    if e.get('type') == 'assistant':
                        # New assistant message - reset and collect all text blocks
                        last_message_texts = []
                        for b in e.get('message', {}).get('content', []):
                            if b.get('type') == 'text' and b.get('text', '').strip():
                                last_message_texts.append(b['text'].strip())
                except: pass
        # Join all text blocks from the last assistant message with sentence separator
        if last_message_texts:
            result = ' '.join(last_message_texts)
            debug(f"Extracted message: {result[:200]}...")
            return result

    debug("No assistant message found")
    return None

try:
    input_file = sys.argv[1]
    cache_dir = sys.argv[2]
    debug(f"Starting voice hook with input: {input_file}")

    with open(input_file) as f:
        data = json.load(f)

    opener_idx = random.randint(1, OPENER_COUNT)
    opener_file = os.path.join(cache_dir, f"opener_{opener_idx:02d}_000.wav")

    # Get last assistant message (works for both Claude Code and Codex)
    last = get_assistant_message(data)

    # Build summary text
    if last:
        summary = summarize(last)
        closer = get_closer(last)
        summary_text = f"{summary} {closer}"
        debug(f"Summary: {summary}")
        debug(f"Closer: {closer}")
    else:
        summary_text = get_closer('')
        debug(f"No message, using fallback: {summary_text}")

    # Generate summary audio
    tmp_dir = tempfile.mkdtemp()
    summary_prefix = os.path.join(tmp_dir, "summary")

    debug(f"Generating TTS with voice={VOICE}, speed={SPEED}")
    result = subprocess.run([
        "python3", "-m", "mlx_audio.tts.generate",
        "--model", "mlx-community/Kokoro-82M-bf16",
        "--text", summary_text,
        "--voice", VOICE,
        "--lang_code", "b",
        "--speed", str(SPEED),
        "--file_prefix", summary_prefix
    ], capture_output=True, text=True)

    if result.returncode != 0:
        debug(f"TTS error: {result.stderr}")

    summary_file = f"{summary_prefix}_000.wav"

    # Concatenate opener + summary
    final_audio = os.path.join(tmp_dir, "final.wav")
    if os.path.exists(opener_file) and os.path.exists(summary_file):
        concat_wavs([opener_file, summary_file], final_audio)
        debug(f"Playing concatenated audio at {PLAYBACK_SPEED}x")
        subprocess.run(["afplay", "-r", str(PLAYBACK_SPEED), final_audio])
    elif os.path.exists(summary_file):
        debug(f"Playing summary only at {PLAYBACK_SPEED}x")
        subprocess.run(["afplay", "-r", str(PLAYBACK_SPEED), summary_file])
    else:
        debug("No audio files generated")

    # Cleanup
    import shutil
    shutil.rmtree(tmp_dir, ignore_errors=True)

except Exception as e:
    debug(f"Exception: {type(e).__name__}: {e}")
    import traceback
    debug(traceback.format_exc())
    # Fallback: just say something
    subprocess.run(["say", "-v", "Daniel", "Task complete, sir."])
PY

rm -f "$TMPFILE"
exit 0
