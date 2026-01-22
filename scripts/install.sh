#!/bin/bash
# Voice Butler Skill Installer
# Installs the voice notification hook and generates cached audio files

set -e

echo "Installing Voice Butler Skill..."
echo "================================"

# Get the script's directory (where the skill is located)
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
CACHE_DIR="$CLAUDE_DIR/voice-cache"

# Create directories
mkdir -p "$HOOKS_DIR"
mkdir -p "$CACHE_DIR"

# Copy hook script
echo "Installing voice hook..."
cp "$SKILL_DIR/hooks/voice-hook.sh" "$HOOKS_DIR/voice-hook.sh"
chmod +x "$HOOKS_DIR/voice-hook.sh"

# Check for Python and install mlx-audio if needed
echo "Checking dependencies..."
if ! python3 -c "import mlx_audio" 2>/dev/null; then
    echo "Installing mlx-audio (Kokoro TTS)..."
    pip3 install mlx-audio
fi

# Copy and run opener generator
echo "Generating cached butler openers..."
cp "$SKILL_DIR/scripts/generate-openers.py" "$CACHE_DIR/generate-openers.py"
python3 "$CACHE_DIR/generate-openers.py"

# Configure Claude Code hook in settings.json
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
echo "Configuring Claude Code hook..."

if [ -f "$SETTINGS_FILE" ]; then
    # Check if hook already exists
    if grep -q "voice-hook.sh" "$SETTINGS_FILE"; then
        echo "Hook already configured in settings.json"
    else
        # Add hook to existing settings
        python3 << 'PYCONFIG'
import json
import os

settings_file = os.path.expanduser("~/.claude/settings.json")
with open(settings_file, 'r') as f:
    settings = json.load(f)

# Add stop hook if not present
if 'hooks' not in settings:
    settings['hooks'] = {}
if 'stop' not in settings['hooks']:
    settings['hooks']['stop'] = []

# Check if hook already exists
hook_cmd = "~/.claude/hooks/voice-hook.sh"
hook_exists = any(
    (isinstance(h, dict) and h.get('command') == hook_cmd) or
    (isinstance(h, str) and hook_cmd in h)
    for h in settings['hooks']['stop']
)

if not hook_exists:
    settings['hooks']['stop'].append({
        "command": hook_cmd,
        "timeout": 30000
    })
    with open(settings_file, 'w') as f:
        json.dump(settings, f, indent=2)
    print("Hook added to settings.json")
else:
    print("Hook already configured")
PYCONFIG
    fi
else
    # Create new settings file with hook
    cat > "$SETTINGS_FILE" << 'JSON'
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
JSON
    echo "Created settings.json with hook configuration"
fi

echo ""
echo "Installation complete!"
echo "======================"
echo ""
echo "Usage:"
echo "  /voice         - Toggle voice notifications on/off"
echo "  The butler will speak when Claude finishes responding."
echo ""
echo "To also enable for OpenAI Codex, add this to ~/.codex/config.toml:"
echo '  notify = ["bash", "-c", "~/.claude/hooks/voice-hook.sh \"$0\""]'
echo ""
