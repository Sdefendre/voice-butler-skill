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

def summarize(text, max_words=30):
    """Smart summarization: find key actions and build a coherent summary."""
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
    # Fallback: just say something
    subprocess.run(["say", "-v", "Daniel", "Task complete, sir."])
PY

rm -f "$TMPFILE"
exit 0
