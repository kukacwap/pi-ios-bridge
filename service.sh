#!/bin/bash
# Manage the pi-ios-bridge launchd service.
#   ./service.sh install | uninstall | start | stop | restart | status | logs
set -euo pipefail
LABEL=com.local.pi-ios-bridge
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="gui/$(id -u)"

case "${1:-status}" in
  install)
    cp "$DIR/$LABEL.plist" "$PLIST"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "installed + started: $LABEL"
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "uninstalled: $LABEL"
    ;;
  start)   launchctl kickstart "$DOMAIN/$LABEL"; echo "started" ;;
  stop)    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; echo "stopped" ;;
  restart) launchctl kickstart -k "$DOMAIN/$LABEL"; echo "restarted" ;;
  status)  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state =|pid =" || echo "not loaded" ;;
  logs)    tail -n 40 -f "$DIR/bridge.err.log" ;;
  *) echo "usage: $0 {install|uninstall|start|stop|restart|status|logs}"; exit 1 ;;
esac
