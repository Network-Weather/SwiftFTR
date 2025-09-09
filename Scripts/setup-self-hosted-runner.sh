#!/bin/bash

# Script to help set up a self-hosted GitHub Actions runner for SwiftFTR testing
# This runner will be able to perform actual network traces

set -e

echo "SwiftFTR Self-Hosted Runner Setup"
echo "=================================="
echo ""

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ This script is designed for macOS only (SwiftFTR requires macOS)"
    exit 1
fi

# Check for required tools
echo "Checking requirements..."

if ! command -v swift &> /dev/null; then
    echo "❌ Swift is not installed. Please install Xcode or Swift toolchain."
    exit 1
fi

if ! command -v git &> /dev/null; then
    echo "❌ Git is not installed. Please install Xcode Command Line Tools."
    exit 1
fi

echo "✓ Requirements met"
echo ""

# Get runner configuration
echo "GitHub Runner Configuration"
echo "---------------------------"
echo "To set up a self-hosted runner, you need:"
echo "1. Go to your GitHub repository settings"
echo "2. Navigate to Actions > Runners"
echo "3. Click 'New self-hosted runner'"
echo "4. Select 'macOS'"
echo "5. Follow the instructions to get your token"
echo ""

read -p "Enter your GitHub repository (e.g., username/repo): " REPO
read -p "Enter your runner token (from GitHub): " TOKEN
read -p "Enter a name for this runner (e.g., mac-mini-local): " RUNNER_NAME
read -p "Enter runner labels (comma-separated, e.g., self-hosted,macos,traceroute): " LABELS

# Create runner directory
RUNNER_DIR="$HOME/actions-runner-swiftftr"
echo ""
echo "Setting up runner in: $RUNNER_DIR"

if [ -d "$RUNNER_DIR" ]; then
    echo "⚠️  Runner directory already exists. Backing up..."
    mv "$RUNNER_DIR" "$RUNNER_DIR.backup.$(date +%Y%m%d-%H%M%S)"
fi

mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

# Download runner
echo "Downloading GitHub Actions runner..."
RUNNER_VERSION="2.311.0"  # Update this to latest version
curl -o actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz -L \
    https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz

tar xzf ./actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz
rm actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz

# Configure runner
echo "Configuring runner..."
./config.sh \
    --url "https://github.com/$REPO" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$LABELS" \
    --work "_work" \
    --unattended \
    --replace

# Create launch agent for auto-start
echo "Creating launch agent for auto-start..."
PLIST_PATH="$HOME/Library/LaunchAgents/com.swiftftr.actions-runner.plist"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.swiftftr.actions-runner</string>
    <key>ProgramArguments</key>
    <array>
        <string>$RUNNER_DIR/run.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$RUNNER_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$RUNNER_DIR/runner.log</string>
    <key>StandardErrorPath</key>
    <string>$RUNNER_DIR/runner.error.log</string>
</dict>
</plist>
EOF

# Load the launch agent
launchctl load "$PLIST_PATH" 2>/dev/null || true

# Create helper scripts
cat > "$RUNNER_DIR/start-runner.sh" << 'EOF'
#!/bin/bash
launchctl load ~/Library/LaunchAgents/com.swiftftr.actions-runner.plist
echo "Runner started"
EOF

cat > "$RUNNER_DIR/stop-runner.sh" << 'EOF'
#!/bin/bash
launchctl unload ~/Library/LaunchAgents/com.swiftftr.actions-runner.plist
echo "Runner stopped"
EOF

cat > "$RUNNER_DIR/status-runner.sh" << 'EOF'
#!/bin/bash
if launchctl list | grep -q com.swiftftr.actions-runner; then
    echo "Runner is running"
    tail -20 runner.log
else
    echo "Runner is not running"
fi
EOF

chmod +x "$RUNNER_DIR"/*.sh

# Test network capabilities
echo ""
echo "Testing network capabilities..."
if ping -c 1 1.1.1.1 > /dev/null 2>&1; then
    echo "✓ Can reach external networks"
else
    echo "⚠️  Cannot reach external networks - traceroutes may fail"
fi

# Final instructions
echo ""
echo "========================================="
echo "✅ Self-Hosted Runner Setup Complete!"
echo "========================================="
echo ""
echo "Runner installed at: $RUNNER_DIR"
echo "Runner name: $RUNNER_NAME"
echo "Runner labels: $LABELS"
echo ""
echo "Commands:"
echo "  Start runner:  $RUNNER_DIR/start-runner.sh"
echo "  Stop runner:   $RUNNER_DIR/stop-runner.sh"
echo "  Check status:  $RUNNER_DIR/status-runner.sh"
echo ""
echo "The runner is configured to start automatically on login."
echo ""
echo "To test the runner:"
echo "1. Go to your GitHub repository"
echo "2. Navigate to Actions > Runners"
echo "3. Verify the runner appears as 'Idle'"
echo "4. Trigger the 'Local Integration Tests' workflow"
echo ""
echo "Note: The runner will have access to perform network traces"
echo "      and will run tests that require actual network connectivity."