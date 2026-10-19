"""Starts auto_renew.sh. The login agent runs this through Homebrew's python3, which already
has access to ~/Downloads (macOS blocks /bin/zsh there when it runs in the background)."""
import subprocess
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.exit(subprocess.run(["/bin/zsh", str(here / "auto_renew.sh")], cwd=here).returncode)
