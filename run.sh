#!/bin/bash

APP=".build/arm64-apple-macosx/debug/CodeBubble"
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null
        wait "$APP_PID" 2>/dev/null
    fi
    APP_PID=""
}

# Kill any stale CodeBubble debug instances from previous runs
killall -q CodeBubble 2>/dev/null
sleep 0.2

build_and_run() {
    cleanup
    echo ""
    echo "=========================================="
    echo "  Building CodeBubble..."
    echo "=========================================="
    if ! ./build.sh --debug; then
        echo "  BUILD FAILED — press R to retry, Q to quit"
        return 1
    fi
    echo ""
    echo "=========================================="
    echo "  Running CodeBubble  (R = rebuild, Q = quit)"
    echo "=========================================="
    "$APP" &
    APP_PID=$!
    disown "$APP_PID"
}

trap cleanup EXIT

build_and_run

while true; do
    read -rsn1 key 2>/dev/null || continue
    case "$key" in
        r|R)
            echo ""
            echo ">>> Restarting..."
            build_and_run
            ;;
        q|Q)
            echo ""
            echo ">>> Quitting..."
            exit 0
            ;;
    esac
done
