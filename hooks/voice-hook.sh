#!/bin/bash
# Voice notification hook for Claude Code and OpenAI Codex
# Configurable TTS: Pocket TTS (fast) or Kokoro (butler voice)
# Set CLAUDE_TTS_MODEL=kokoro for British butler voice
# Plays summary at 1.5x speed

[ ! -f ~/.claude/voice-enabled ] && exit 0

TMPFILE=$(mktemp)

# Handle input from either stdin (Claude Code) or command arg (Codex)
if [ -n "$1" ] && [ "$1" != "-" ]; then
    # Codex passes JSON as first argument
    echo "$1" > "$TMPFILE"
else
    # Claude Code pipes JSON to stdin
    cat > "$TMPFILE"
fi

# Single Python script: get summary, generate TTS, play - all in one for speed
/opt/homebrew/bin/python3.11 - "$TMPFILE" << 'PY'
import sys, json, re, random, subprocess, os, tempfile

# Configurable settings via environment variables
# TTS_MODEL: "pocket" (default, fast) or "kokoro" (butler voice)
TTS_MODEL = os.environ.get('CLAUDE_TTS_MODEL', 'pocket').lower()
# Voice settings per model
POCKET_VOICE = os.environ.get('CLAUDE_POCKET_VOICE', 'jean')
KOKORO_VOICE = os.environ.get('CLAUDE_KOKORO_VOICE', 'bm_george')
KOKORO_SPEED = float(os.environ.get('CLAUDE_KOKORO_SPEED', '1.3'))
PLAYBACK_SPEED = float(os.environ.get('CLAUDE_PLAYBACK_SPEED', '1.5'))
MAX_SUMMARY_WORDS = int(os.environ.get('CLAUDE_SUMMARY_WORDS', '100'))

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
    """Smart summarization: build a comprehensive summary of the whole output."""
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
        r"I can see (?:that )?.*?\.",
        r"Based on (?:the|my).*?\.",
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
    action_patterns = [
        r'\b(created|wrote|generated|added|implemented)\b',
        r'\b(edited|updated|modified|changed|refactored)\b',
        r'\b(fixed|resolved|corrected|repaired)\b',
        r'\b(deleted|removed|cleared)\b',
        r'\b(found|located|discovered|identified)\b',
        r'\b(installed|configured|set up)\b',
        r'\b(tested|verified|confirmed|validated)\b',
        r'\b(moved|renamed|copied)\b',
        r'\b(pushed|committed|deployed|merged)\b',
        r'\b(completed|finished|done)\b',
    ]

    # Score each sentence by importance
    def score_sentence(sent):
        sent_lower = sent.lower()
        score = 0
        # Higher score for action verbs (earlier in list = more important)
        for i, pattern in enumerate(action_patterns):
            if re.search(pattern, sent_lower):
                score += (len(action_patterns) - i) * 10
        # Bonus for sentences with file paths or specific details
        if re.search(r'[\w/]+\.\w+', sent):  # file paths
            score += 5
        # Penalty for questions or meta-commentary
        if sent.endswith('?') or 'would you like' in sent_lower or 'let me know' in sent_lower:
            score -= 20
        return score

    # Score and sort sentences
    scored = [(score_sentence(s), i, s) for i, s in enumerate(sentences)]
    scored.sort(key=lambda x: (-x[0], x[1]))  # Sort by score desc, then original order

    # Build summary by collecting top sentences up to max_words
    summary_sentences = []
    word_count = 0
    used_indices = set()

    for score, idx, sent in scored:
        if score < 0:
            continue  # Skip low-quality sentences
        sent_words = len(sent.split())
        if word_count + sent_words <= max_words:
            summary_sentences.append((idx, sent))
            used_indices.add(idx)
            word_count += sent_words
        if word_count >= max_words * 0.8:
            break

    # If we have nothing, use first sentence
    if not summary_sentences:
        summary_sentences = [(0, sentences[0])]

    # Sort by original order for coherent flow
    summary_sentences.sort(key=lambda x: x[0])
    summary = ' '.join(s for _, s in summary_sentences)

    # Ensure ends with punctuation
    if summary and summary[-1] not in '.!?':
        summary += '.'

    return summary

def detect_platform(data):
    """Detect if input is from Codex or Claude Code"""
    if "last-assistant-message" in data or "last_assistant_message" in data:
        return "codex"
    if data.get("type") == "agent-turn-complete":
        return "codex"
    if data.get('transcript_path'):
        return "claude"
    return "unknown"

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

def generate_tts(text, output_prefix):
    """Generate TTS audio using configured model"""
    if TTS_MODEL == 'kokoro':
        # Kokoro with British butler voice (slower but distinctive)
        debug(f"Using Kokoro ({KOKORO_VOICE})")
        return subprocess.run([
            "/opt/homebrew/bin/python3.11", "-m", "mlx_audio.tts.generate",
            "--model", "mlx-community/Kokoro-82M-bf16",
            "--text", text,
            "--voice", KOKORO_VOICE,
            "--lang_code", "b",
            "--speed", str(KOKORO_SPEED),
            "--file_prefix", output_prefix
        ], capture_output=True, text=True)
    else:
        # Pocket TTS (default - fast, low latency)
        debug(f"Using Pocket TTS ({POCKET_VOICE})")
        return subprocess.run([
            "/opt/homebrew/bin/python3.11", "-m", "mlx_audio.tts.generate",
            "--model", "mlx-community/pocket-tts",
            "--text", text,
            "--voice", POCKET_VOICE,
            "--file_prefix", output_prefix
        ], capture_output=True, text=True)

try:
    input_file = sys.argv[1]
    debug(f"Starting voice hook with input: {input_file}")

    with open(input_file) as f:
        data = json.load(f)

    # Detect platform (codex or claude)
    platform = detect_platform(data)
    debug(f"Detected platform: {platform}")

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

    # Generate TTS
    result = generate_tts(summary_text, summary_prefix)

    if result.returncode != 0:
        debug(f"TTS error: {result.stderr}")

    summary_file = f"{summary_prefix}_000.wav"

    # Play the generated audio
    if os.path.exists(summary_file):
        debug(f"Playing audio at {PLAYBACK_SPEED}x")
        subprocess.run(["afplay", "-r", str(PLAYBACK_SPEED), summary_file])
    else:
        debug("No audio file generated")

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
