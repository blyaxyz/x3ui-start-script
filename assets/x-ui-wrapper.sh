#!/usr/bin/env bash
set -u

SERVICE=x-ui.service
BINARY=/usr/local/x-ui/x-ui

run_service() {
    systemctl "$1" "$SERVICE"
}

show_menu() {
    cat <<'EOF'
3x-ui management
  1) Start
  2) Stop
  3) Restart
  4) Status
  5) Logs
  6) Show settings
  0) Exit
EOF
    read -r -p "Select: " choice
    case "$choice" in
        1) run_service start ;;
        2) run_service stop ;;
        3) run_service restart ;;
        4) run_service status ;;
        5) journalctl -u "$SERVICE" -e --no-pager ;;
        6) exec "$BINARY" setting -show true ;;
        0) exit 0 ;;
        *) printf '%s\n' "Unknown selection" >&2; exit 2 ;;
    esac
}

[[ -x "$BINARY" ]] || { printf '%s\n' "3x-ui binary is missing: $BINARY" >&2; exit 1; }

case "${1:-}" in
    "")       show_menu ;;
    start)    run_service start ;;
    stop)     run_service stop ;;
    restart)  run_service restart ;;
    status)   run_service status ;;
    enable)   run_service enable ;;
    disable)  run_service disable ;;
    log|logs) journalctl -u "$SERVICE" -e --no-pager ;;
    settings) exec "$BINARY" setting -show true ;;
    update)
        printf '%s\n' "Updates are managed by the verified 3x-ui-pro installer. Rerun start-script.sh with -version X.Y.Z." >&2
        exit 2
        ;;
    uninstall)
        printf '%s\n' "Use: sudo bash start-script.sh -uninstall yes" >&2
        exit 2
        ;;
    *) exec "$BINARY" "$@" ;;
esac
