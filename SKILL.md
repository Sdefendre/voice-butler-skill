---
name: voice-butler
description: Toggle voice notifications with a British butler persona. Use /voice to enable or disable spoken summaries when Claude finishes responding. When enabled, a butler voice speaks a concise summary of completed tasks. Works with both Claude Code and OpenAI Codex CLI.
user-invocable: true
---

# Voice Butler - British Butler Voice Notifications

A British butler voice delivers concise summaries when Claude finishes responding, creating a hands-free coding experience.

## Instructions

When the user invokes `/voice`, toggle the voice notification feature:

1. Check the current state by looking for the file `~/.claude/voice-enabled`
2. Toggle the state:
   - If the file exists, delete it (disable voice)
   - If the file doesn't exist, create it (enable voice)
3. Confirm the new status to the user

## Implementation

Use the Bash tool to:
- Check: `[ -f ~/.claude/voice-enabled ] && echo "enabled" || echo "disabled"`
- Enable: `touch ~/.claude/voice-enabled`
- Disable: `rm ~/.claude/voice-enabled`

After toggling, tell the user:
- **Enabled:** "Voice notifications enabled. You'll hear a British butler speak a summary when I finish responding."
- **Disabled:** "Voice notifications disabled."

## Features

- **Random Butler Openers**: 12 pre-cached phrases like "Very good, sir", "Splendid, sir", "Indeed, sir"
- **Context-Aware Closers**: Adapts based on what was done (file created, edited, error fixed, search results)
- **Smart Summaries**: Extracts first and last sentences, limited to 40 words
- **Optimized Playback**: 1.5x speed for snappy delivery

## Requirements

This skill requires the voice-butler hook to be installed. If not installed, run:

```bash
# Run the installer from this skill's directory
~/.claude/skills/voice-butler/scripts/install.sh
```

Or install manually:
1. Copy `hooks/voice-hook.sh` to `~/.claude/hooks/`
2. Install Kokoro TTS: `pip install mlx-audio`
3. Generate cached openers: `python3 ~/.claude/skills/voice-butler/scripts/generate-openers.py`
4. Add hook to `~/.claude/settings.json`

## Use Cases

- **Multitasking**: Work on other tasks while Claude processes long requests
- **Accessibility**: Audio feedback for users who prefer spoken output
- **Long-running tasks**: Get notified when builds, tests, or complex operations complete
- **Hands-free workflow**: Ideal when you're away from the keyboard
