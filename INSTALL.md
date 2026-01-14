# Local Digest Install Guide (New Machine)

This guide covers:
- Installing dependencies
- Building the launcher app (`MessagesPython.app`)
- Building Apple Foundation Models bridge (optional)
- Granting macOS permissions

---

## 1) Copy the project

Copy the full `local-digest` folder to the new Mac. Keep all files inside it.

---

## 2) Set up Python + dependencies

Open Terminal:
```bash
cd /path/to/local-digest
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
```

---

## 3) Build the launcher app (MessagesPython.app)

This is the “packed app” that starts the server and opens the browser.

```bash
cd /path/to/local-digest
mkdir -p MessagesPython.app/Contents/MacOS
```

Create the launcher script:
```bash
cat > MessagesPython.app/Contents/MacOS/MessagesPython <<'SH'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_DIR="$(cd "$APP_DIR/.." && pwd)"
VENV_PY="$PROJECT_DIR/venv/bin/python"
APP_PY="$PROJECT_DIR/app.py"
LOG_FILE="$HOME/Library/Logs/MessagesPython.log"

export LOCAL_DIGEST_DEBUG=0
export LOCAL_DIGEST_RELOAD=0

if [ ! -x "$VENV_PY" ]; then
  echo "venv python not found at $VENV_PY" >&2
  exit 1
fi

if [ ! -f "$APP_PY" ]; then
  echo "app.py not found at $APP_PY" >&2
  exit 1
fi

cd "$PROJECT_DIR" || exit 1

if lsof -ti :5001 >/dev/null 2>&1; then
  open "http://127.0.0.1:5001"
  while lsof -ti :5001 >/dev/null 2>&1; do
    sleep 2
  done
  exit 0
fi

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

"$VENV_PY" "$APP_PY" >>"$LOG_FILE" 2>&1 &
SERVER_PID=$!

trap 'kill "$SERVER_PID" >/dev/null 2>&1 || true; exit 0' INT TERM

while kill -0 "$SERVER_PID" >/dev/null 2>&1; do
  sleep 1
done
SH
```

Make it executable:
```bash
chmod +x MessagesPython.app/Contents/MacOS/MessagesPython
```

Create the `Info.plist`:
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

Launch the app:
```bash
open /path/to/local-digest/MessagesPython.app
```

---

## 4) Build Apple Foundation Models bridge (optional)

Requirements:
- macOS 26+
- Apple Intelligence enabled
- Xcode 16+

Build:
```bash
cd /path/to/local-digest
./scripts/build_apple_foundation_bridge.sh
```

Check status:
```bash
./bin/apple_foundation_bridge --status
```

---

## 5) Grant macOS permissions

System Settings -> Privacy & Security -> Full Disk Access  
Add: `MessagesPython.app`

macOS will also prompt for Mail, Calendar, Reminders, and Messages access.

### Messages permissions (important)

To read Messages/iMessage content, macOS needs explicit access:

1) System Settings -> Privacy & Security -> Full Disk Access  
2) Add `MessagesPython.app` (not Terminal)
3) Launch the app once so macOS shows the Messages permission prompt
4) Click **Allow**

---

## 6) Close the app

Use the **Close App** button in the web UI.
