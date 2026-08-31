#!/bin/bash
set -e
echo "=== SubAgent Setup ==="

# 1. Python sidecar dependencies
cd "$(dirname "$0")/sidecar"
python3 -m venv .venv
.venv/bin/pip install httpx fastapi uvicorn pydantic --quiet
echo "✅ Python dependencies installed"

# 2. Electron dependencies
cd "$(dirname "$0")/renderer"
npm install 2>/dev/null || {
    echo "⚠️ npm not found — try: cd renderer && npm install"
}
echo "✅ npm dependencies checked"

echo ""
echo "=== To start ==="
echo "1. Terminal A: cd sidecar && .venv/bin/python3 start_sidecar.py"
echo "2. Terminal B: cd renderer && npx vite --host 127.0.0.1"
echo "OR run main.js directly with Electron"
