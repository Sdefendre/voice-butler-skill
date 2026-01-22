# Voice Butler

A British butler voice notification skill for Claude Code and OpenAI Codex. Get spoken summaries when your AI assistant finishes responding.

> "Splendid, sir. The changes have been applied. Shall I refine it further?"

## Features

- **British Butler Persona**: A distinguished voice (bm_george) delivers updates with proper butler etiquette
- **Random Openers**: 12 pre-cached phrases like "Very good, sir", "Splendid, sir", "Indeed, sir"
- **Context-Aware Closers**: Adapts based on what was done (file created, edited, error fixed, search results)
- **Smart Summaries**: Extracts key information, limited to 40 words for concise delivery
- **Optimized Performance**: Pre-cached openers for instant playback, 1.5x speed for snappy delivery
- **Cross-Platform**: Works with both Claude Code and OpenAI Codex CLI

## Installation

### Quick Install

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/voice-butler-skill.git
cd voice-butler-skill

# Run the installer
./scripts/install.sh
```

### Manual Install

1. Copy the skill to your Claude skills directory:
   ```bash
   cp -r . ~/.claude/skills/voice-butler/
   ```

2. Install the Kokoro TTS engine:
   ```bash
   pip3 install mlx-audio
   ```

3. Generate cached openers:
   ```bash
   python3 ~/.claude/skills/voice-butler/scripts/generate-openers.py
   ```

4. Copy the hook:
   ```bash
   cp hooks/voice-hook.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/voice-hook.sh
   ```

5. Add the hook to `~/.claude/settings.json`:
   ```json
   {
     "hooks": {
       "stop": [
         {
           "command": "~/.claude/hooks/voice-hook.sh",
           "timeout": 30000
         }
       ]
     }
   }
   ```

## Usage

Toggle voice notifications on or off:

```
/voice
```

When enabled, the butler will speak a summary whenever Claude finishes responding.

### Manual Control

```bash
# Enable voice
touch ~/.claude/voice-enabled

# Disable voice
rm ~/.claude/voice-enabled

# Check status
[ -f ~/.claude/voice-enabled ] && echo "enabled" || echo "disabled"
```

## OpenAI Codex Integration

To use with OpenAI Codex CLI, add this to `~/.codex/config.toml`:

```toml
notify = ["bash", "-c", "~/.claude/hooks/voice-hook.sh \"$0\""]
```

## How It Works

1. **Toggle**: `/voice` creates or deletes `~/.claude/voice-enabled`
2. **Hook**: When Claude finishes, the stop hook checks if voice is enabled
3. **Summarize**: Extracts first + last sentences, strips markdown, limits to 40 words
4. **Generate**: Uses Kokoro TTS with British voice (bm_george) at 1.3x speed
5. **Concatenate**: Combines pre-cached opener with generated summary
6. **Play**: Plays audio at 1.5x speed for snappy delivery

## Requirements

- macOS (uses `afplay` for audio playback)
- Python 3.8+
- Apple Silicon Mac (for mlx-audio) or modify for other TTS engines

## File Structure

```
voice-butler-skill/
├── SKILL.md                  # Skill definition for Claude Code
├── README.md                 # This file
├── hooks/
│   └── voice-hook.sh         # Main hook script
└── scripts/
    ├── install.sh            # Automated installer
    └── generate-openers.py   # Generates cached butler openers
```

## Customization

### Change the Voice

Edit `hooks/voice-hook.sh` and `scripts/generate-openers.py` to use a different Kokoro voice:
- `af_bella` - American female
- `af_nicole` - American female
- `am_adam` - American male
- `bf_emma` - British female
- `bm_george` - British male (default)

### Add Custom Openers

Edit `scripts/generate-openers.py` to add your own butler phrases, then regenerate:
```bash
python3 ~/.claude/skills/voice-butler/scripts/generate-openers.py
```

### Adjust Playback Speed

Edit `hooks/voice-hook.sh` and change the `-r 1.5` parameter to your preferred speed.

## License

MIT License - Feel free to modify and share!

## Credits

- [Kokoro TTS](https://github.com/ml-explore/mlx-examples) - Fast local TTS via MLX
- British butler persona inspired by classic British service
