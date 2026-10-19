#!/bin/zsh
# Opens the iPhone Location page. The server normally runs by itself (login agent
# <prefix>.locationserver, see install_login_agents.sh); if it isn't running, this starts it in this window.
cd "$(dirname "$0")"
if curl -s -m 3 -o /dev/null http://127.0.0.1:8765/; then
  open http://127.0.0.1:8765
else
  (sleep 1 && open http://127.0.0.1:8765) &
  python3 server.py 8765 --lan
fi
