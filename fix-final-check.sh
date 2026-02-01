#!/bin/bash
# Fix the final verification check to always verify after a delay

# Find the else branch in the final verification
sed -i.bak '/^else$/,/^fi$/ {
    /^else$/ {
        a\
    echo "   ✅ wlan0 status: $FINAL_STATUS"\
    echo "   🔍 Waiting 3 seconds and checking again (NetworkManager might change it)..."\
    sleep 3\
    FINAL_CHECK_AGAIN=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" | awk '\''{print $3}'\'' || echo "unknown")\
    if [ "$FINAL_CHECK_AGAIN" = "unmanaged" ] || [ "$FINAL_CHECK_AGAIN" = "unavailable" ]; then\
        echo "   ⚠️  wlan0 became unmanaged after delay! Fixing..."\
        ensure_nm_config_correct\
        sudo nmcli general reload 2>/dev/null || true\
        sleep 2\
        for i in 1 2 3 4 5 6 7 8 9 10; do\
            sudo nmcli device set $ONBOARD_WIFI managed yes 2>/dev/null || true\
            sudo nmcli radio wifi on 2>/dev/null || true\
            sleep 0.3\
        done\
        sleep 2\
        FINAL_AFTER_DELAY=$(nmcli device status 2>/dev/null | grep "^$ONBOARD_WIFI" | awk '\''{print $3}'\'' || echo "unknown")\
        if [ "$FINAL_AFTER_DELAY" != "unmanaged" ] && [ "$FINAL_AFTER_DELAY" != "unavailable" ]; then\
            echo "   ✅ Fixed after delay! wlan0 is now: $FINAL_AFTER_DELAY"\
        else\
            echo "   ⚠️  Still unmanaged - restarting NetworkManager..."\
            ensure_nm_wlan0_managed\
            sudo systemctl restart NetworkManager 2>/dev/null || true\
            force_wlan0_managed_after_restart\
        fi\
    else\
        echo "   ✅ wlan0 stayed managed: $FINAL_CHECK_AGAIN"\
    fi
        d
    }
}' tunnel.sh

echo "Fixed final verification check"
