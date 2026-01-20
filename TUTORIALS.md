# Build Tutorials (Novice Friendly)

This project includes two optional helpers:

1) `MessagesPython.app` (a small launcher app for permissions)
2) Apple Foundation Models bridge (a Swift CLI)

Follow the steps below to build each one on your Mac.

---

## 1) Build `MessagesPython.app`

Why you need it:
- macOS permissions are tied to the app that accesses Messages.
- Granting Full Disk Access to Terminal is broad. This app lets you grant access only to the launcher app.

### Requirements
- macOS
- Python venv already created at `./venv` (from the project root)

### Steps

1. Open Terminal and go to the project folder:
```bash
cd /path/to/local-digest
```

2. Create the app bundle folders:
```bash
mkdir -p MessagesPython.app/Contents/MacOS
```

3. Create the launcher script:
```bash
cat > MessagesPython.app/Contents/MacOS/MessagesPython <<'SH'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_DIR="$(cd "$APP_DIR/.." && pwd)"
VENV_PY="$PROJECT_DIR/venv/bin/python"
APP_PY="$PROJECT_DIR/app.py"
LOG_FILE="$HOME/Library/Logs/MessagesPython.log"

if [ ! -x "$VENV_PY" ]; then
  echo "venv python not found at $VENV_PY" >&2
  exit 1
fi

if [ ! -f "$APP_PY" ]; then
  echo "app.py not found at $APP_PY" >&2
  exit 1
fi

cd "$PROJECT_DIR" || exit 1

(
  for i in {1..30}; do
    if curl -s "http://127.0.0.1:5001/api/status" >/dev/null 2>&1; then
      open "http://127.0.0.1:5001"
      exit 0
    fi
    sleep 0.5
  done
  open "http://127.0.0.1:5001"
) &

exec "$VENV_PY" "$APP_PY" >>"$LOG_FILE" 2>&1
SH
```

4. Make it executable:
```bash
chmod +x MessagesPython.app/Contents/MacOS/MessagesPython
```

5. Create `Info.plist`:
```bash
cat > MessagesPython.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>MessagesPython</string>
  <key>CFBundleIdentifier</key>
  <string>com.localdigest.messagespython</string>
  <key>CFBundleExecutable</key>
  <string>MessagesPython</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
</dict>
</plist>
PLIST
```

6. Launch the app:
```bash
open /path/to/local-digest/MessagesPython.app
```

7. Grant permissions:
- Go to System Settings -> Privacy & Security -> Full Disk Access.
- Add `MessagesPython.app` (not Terminal).

You can now use the Messages tab without giving Full Disk Access to Terminal.

---

## 2) Build the Apple Foundation Models Bridge

Why you need it:
- Apple’s Foundation Models are only accessible via Swift.
- This bridge is a tiny Swift CLI that your Python app calls.

### Requirements
- macOS 26+ with Apple Intelligence enabled
- Xcode 16+ installed

### Steps

1. Open Terminal and go to the project folder:
```bash
cd /path/to/local-digest
```

2. Build the bridge:
```bash
./scripts/build_apple_foundation_bridge.sh
```

3. Verify it runs:
```bash
./bin/apple_foundation_bridge --status
```

Expected output (example):
```json
{"success":true,"text":null,"error":null,"availability":"available"}
```

4. Restart the app and select the Apple model:
- Open the web UI.
- Choose `🍎 Apple Foundation Model` in the model selector.

### Troubleshooting

- If build fails with SDK errors, install Xcode 16+ and make sure macOS 26 SDK is present.
- If availability says `unavailable:appleIntelligenceNotEnabled`, enable Apple Intelligence in System Settings.
- If the binary is in another location, set:
```bash
export APPLE_FM_BRIDGE_PATH=/path/to/apple_foundation_bridge
```
