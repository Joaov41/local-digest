#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Change to script directory
cd "$SCRIPT_DIR"

VENV_DIR="$SCRIPT_DIR/venv"
PYTHON="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

# Ensure virtual environment exists
if [ ! -x "$PYTHON" ]; then
    echo "⚠️  Virtual environment not found."
    echo "Create it with:"
    echo "  /opt/homebrew/bin/python3 -m venv venv"
    echo "  ./venv/bin/pip install -r requirements.txt"
    echo ""
    exit 1
fi

# Check if mlx-lm is installed (Apple Silicon only)
if ! "$PYTHON" - <<'PY' >/dev/null 2>&1; then
import mlx_lm  # noqa: F401
PY
    echo "⚠️  mlx-lm is not installed!"
    echo "Install with: pip install mlx mlx-lm"
    echo ""
    read -p "Press Enter to continue anyway, or Ctrl+C to exit..."
fi

# Kill any process using port 5001
echo "Checking for processes on port 5001..."
if lsof -ti:5001 > /dev/null 2>&1; then
    echo "Killing process on port 5001..."
    kill -9 $(lsof -ti:5001) 2>/dev/null || true
    sleep 1
fi

# Start the Flask app
echo "Starting Email Summarizer (MLX local models)..."
echo "Open http://localhost:5001 in your browser"
echo ""
"$PYTHON" app.py
