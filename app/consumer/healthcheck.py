"""Liveness probe: exit 1 if the heartbeat file is missing or older than 30s."""
import os
import sys
import time

path = os.environ.get("HEARTBEAT_FILE", "/tmp/heartbeat")
try:
    sys.exit(0 if time.time() - os.path.getmtime(path) < 30 else 1)
except OSError:
    sys.exit(1)
