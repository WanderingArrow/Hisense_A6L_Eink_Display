#!/system/bin/sh
# epd_switch.sh - Hisense A6L dual-screen (LCD/E-ink) state manager
# Unified version with timing buffers, frame stabilization, and hardware reset.

STATE_FILE=/data/local/tmp/epd_state
LOG_FILE=/data/local/tmp/epd_switch.log
LOCK_FILE=/data/local/tmp/epd_switch.lock

FLIP_DEV=/dev/input/event9        # KEY_LEFT_UP, keycode 616

FB1=/sys/class/graphics/fb1       # E-ink Framebuffer base
FB0=/sys/class/graphics/fb0       # LCD Framebuffer base
CTP1=/sys/ctp1/ctp_func/tpenable  # Master Rear Touch Enable Node
BACKLIGHT=/sys/class/leds/epd-backlight/brightness

EINK_BACKLIGHT_LEVEL=0

log() {
    echo "$(date '+%H:%M:%S') $1" >> "$LOG_FILE"
}

get_state() {
    cat "$STATE_FILE" 2>/dev/null || echo "LCD"
}

set_state() {
    echo "$1" > "$STATE_FILE"
    log "state -> $1"
}

activate_eink() {
    log "activate_eink: waking rear panel with clean hardware flush"
    
    # 1. Mount the display interface
    echo 1 > "$FB1/epd_connect"
    echo 0 > "$FB1/blank"
    
    # --- THE HARDWARE PURGE VALVE ---
    echo 0 > "$FB1/epd_display_mode"
    echo 1 > "$FB1/epd_commit_bitmap"
    sleep 0.15
    
    # 2. Lock down the high-speed interactive scrolling path (Mode 6)
    echo 6 > "$FB1/epd_display_mode"
    echo 1 > "$FB1/epd_commit_bitmap"
    
    # 3. Enable touch routing and drop front panel
    echo 1 > "$CTP1"
    echo "$EINK_BACKLIGHT_LEVEL" > "$BACKLIGHT"
    echo 4 > "$FB0/blank"
    
    # --- DYNAMIC GEOMETRY RESCALE ---
    # Force Android's core canvas to match the physical E-ink boundaries natively
    wm size 720x1440
    wm density 213
    
    set_state "EINK"
}

activate_lcd() {
    log "activate_lcd: parking e-ink lanes, waking front panel"
    
    # 1. Kill interaction arrays first to prevent touch collision
    echo 0 > "$CTP1"
    echo 4 > "$FB1/blank"
    
    # --- ANTI-CRASH TIMING BUFFER ---
    sleep 0.3
    
    # 2. Illuminate front glass natively
    echo 0 > "$BACKLIGHT"
    echo 0 > "$FB0/blank"
    
    # --- RESTORE LCD GEOMETRY ---
    # Snap Android back to the full high-resolution smartphone canvas
    wm size 1080x2340
    wm density 480
    
    set_state "LCD"
}

handle_flip_button() {
    state=$(get_state)
    log "flip button pressed, current state=$state"
    case "$state" in
        EINK)
            activate_lcd
            ;;
        LCD|*)
            activate_eink
            ;;
    esac
}

monitor_flip() {
    getevent -l "$FLIP_DEV" | while read -r line; do
        echo "$line" | grep -q "KEY_LEFT_UP" && echo "$line" | grep -q "DOWN" && handle_flip_button
    done
}

# Concurrency Lock Handling
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE")
    if [ -d "/proc/$OLD_PID" ]; then
        echo "epd_switch.sh already running as PID $OLD_PID - refusing to start a second instance."
        exit 1
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Dynamic Hardware Detection on Boot
if [ "$(cat $FB1/blank 2>/dev/null)" = "0" ]; then
    set_state "EINK"
else
    set_state "LCD"
fi

log "epd_switch.sh started cleanly (PID $$)"

# Execute structural monitor loop in foreground
monitor_flip