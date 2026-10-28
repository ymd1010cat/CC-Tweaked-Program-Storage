#!/usr/bin/env bash
# Start / stop / inspect the dedicated Fabric server used by the acceptance scripts.
#
#   bash _psh-mc-server.sh status
#   bash _psh-mc-server.sh start      # launches java in the background and waits for RCON
#   bash _psh-mc-server.sh stop       # graceful stop through RCON
#
# The java binary is discovered rather than hard coded: an explicit JAVA wins, then
# JAVA_HOME, then the known install roots.
set -u

RPV="${RPV:-/c/Users/ymd10/Documents/DSHWork/cc_tweaked/rpv1}"
PY="${RPV_PYTHON:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
RCON_PY="$RPV/poc/mc/rcon.py"
SRV="${RPV_MC_SERVER:-$RPV/mc-server-fabric}"
PORT="${RPV_MC_RCON:-25576}"
PASS="rpvtest"
LOG="${RPV_MC_LOG:-$SRV/logs/latest.log}"
ACTION="${1:-status}"

find_java() {
    if [ -n "${JAVA:-}" ] && [ -x "$JAVA" ]; then echo "$JAVA"; return; fi
    local c
    for c in "${JAVA_HOME:-}/bin/java.exe" \
             "/c/Program Files/Java/jdk-21.0.12/bin/java.exe" \
             "/c/Program Files/Java/jdk-25.0.4/bin/java.exe" \
             "/c/Program Files/Microsoft/jdk-25.0.3.9-hotspot/bin/java.exe"; do
        [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
    done
    c="$(ls -1d /c/Program\ Files/Java/jdk-*/bin/java.exe 2>/dev/null | sort -V | tail -1)"
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
    return 1
}

rcon() { "$PY" "$RCON_PY" 127.0.0.1 "$PORT" "$PASS" "$1" 2>&1 | tr -d '\r'; }
is_up() { rcon "list" | grep -q "players online"; }

case "$ACTION" in
    status)
        if is_up; then
            echo "fabric: RUNNING (rcon $PORT) -- $(rcon "list" | tail -1)"
            echo "  log: $LOG"
            echo "  java: $(ps -W 2>/dev/null | grep -c 'bin/java') process line(s)"
        else
            echo "fabric: not reachable on rcon $PORT"
        fi
        ;;
    start)
        if is_up; then echo "fabric: already running"; exit 0; fi
        JAVA_BIN="$(find_java)" || { echo "error: no java.exe found; set JAVA=<path>" >&2; exit 1; }
        [ -f "$SRV/fabric-server-launch.jar" ] || { echo "error: $SRV/fabric-server-launch.jar missing" >&2; exit 1; }
        echo "starting fabric with $JAVA_BIN"
        ( cd "$SRV" && nohup "$JAVA_BIN" -Xmx3G -Xms1G -XX:+UseG1GC -jar fabric-server-launch.jar nogui \
            >"$SRV/server.out.txt" 2>&1 & )
        for i in $(seq 1 36); do
            sleep 5
            if is_up; then echo "fabric: RUNNING after $((i * 5))s"; exit 0; fi
        done
        echo "error: rcon did not come up within 180s; see $SRV/server.out.txt" >&2
        exit 1
        ;;
    stop)
        if ! is_up; then echo "fabric: not running"; exit 0; fi
        echo "stopping: $(rcon "stop" | tail -1)"
        for i in $(seq 1 20); do
            sleep 3
            if ! is_up; then echo "fabric: stopped after $((i * 3))s"; exit 0; fi
        done
        echo "warning: still reachable after 60s" >&2
        exit 1
        ;;
    *)
        echo "usage: $0 [status|start|stop]" >&2
        exit 2
        ;;
esac
