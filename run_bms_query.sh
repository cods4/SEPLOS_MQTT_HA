#!/bin/bash
# Poll the Seplos BMS and publish Home Assistant MQTT discovery plus sensor state.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=ha_mqtt.sh
source "$SCRIPT_DIR/ha_mqtt.sh"
# shellcheck source=bms_poll.sh
source "$SCRIPT_DIR/bms_poll.sh"

load_config "$SCRIPT_DIR/config.ini" || exit 1
ha_mqtt_init || exit 1

LOGNAME="$SCRIPT_DIR/BMS_error.log"
NOUPFILE="$SCRIPT_DIR/nohup.out"
touch "$LOGNAME" "$NOUPFILE"

if ! acquire_poll_lock; then
	log_msg "Previous poll still running, skipping"
	exit 0
fi

# A restart should publish discovery again. Deleting the device in Home
# Assistant removes the retained config, and this stamp would otherwise
# suppress a new one until DISCOVERY_INTERVAL elapses.
rm -f "$STAMP_FILE"
log_msg "Script started"
while true; do
	rotate_file "$LOGNAME"
	rotate_file "$NOUPFILE" truncate
	poll_once
	sleep "$TELEPERIOD"
done
