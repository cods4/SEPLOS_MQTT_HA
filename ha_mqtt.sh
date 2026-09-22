#!/bin/bash
# Home Assistant MQTT device discovery and state publishing.
# One retained discovery payload lists every entity, including value_template
# sensors that Home Assistant evaluates from the shared JSON state message.

trim() {
	local s="$1"
	s=${s%$'\r'}
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

load_config() {
	local file="$1" line key value example
	if [ ! -f "$file" ]; then
		echo "Config not found: $file" >&2
		example="$(dirname "$file")/config.example.ini"
		if [ "$(basename "$file")" = "config.ini" ] && [ -f "$example" ]; then
			echo "Copy config.example.ini to config.ini and edit it." >&2
		fi
		return 1
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(trim "$line")
		case "$line" in
			''|\#*) continue ;;
		esac
		key=$(trim "${line%%=*}")
		value=$(trim "${line#*=}")
		case "$key" in
			MQTTHOST|TOPIC|MQTTUSER|MQTTPASWD|TELEPERIOD|id_prefix|MAXSIZE|\
			CELL_MIN_VOLT|CELL_MAX_VOLT|DEVICE_NAME|DISCOVERY_PREFIX|MQTTPORT|\
			EXPIRE_AFTER|DISCOVERY_INTERVAL|PACK_CAPACITY_AH|DEV|LOG_FRAMES)
				printf -v "$key" '%s' "$value"
				;;
		esac
	done < "$file"
}

ha_mqtt_init() {
	export LC_ALL=C
	command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; return 1; }
	command -v bc >/dev/null 2>&1 || { echo "bc is required (apt-get install bc)" >&2; return 1; }
	if [ -z "${MQTTHOST:-}" ] || [ -z "${TOPIC:-}" ]; then
		echo "Set MQTTHOST and TOPIC in config.ini" >&2
		return 1
	fi

	DISCOVERY_PREFIX=${DISCOVERY_PREFIX:-homeassistant}
	MQTTPORT=${MQTTPORT:-1883}
	DEVICE_NAME=${DEVICE_NAME:-Seplos BMS}
	TELEPERIOD=${TELEPERIOD:-10}
	DISCOVERY_INTERVAL=${DISCOVERY_INTERVAL:-3600}
	MAXSIZE=${MAXSIZE:-2000000}
	CELL_MIN_VOLT=${CELL_MIN_VOLT:-2500}
	CELL_MAX_VOLT=${CELL_MAX_VOLT:-3800}
	if [ -z "${EXPIRE_AFTER:-}" ]; then
		EXPIRE_AFTER=$((TELEPERIOD * 6))
		[ "$EXPIRE_AFTER" -lt 120 ] && EXPIRE_AFTER=120
	fi
	case "$MQTTPORT" in
		''|*[!0-9]*) echo "MQTTPORT must be a number" >&2; return 1 ;;
	esac
	case "$EXPIRE_AFTER" in
		''|*[!0-9]*) echo "EXPIRE_AFTER must be a number" >&2; return 1 ;;
	esac
	case "$DISCOVERY_INTERVAL" in
		''|*[!0-9]*) echo "DISCOVERY_INTERVAL must be a number" >&2; return 1 ;;
	esac

	if [ -n "${id_prefix:-}" ]; then
		DEVICE_ID=$(printf '%s' "${TOPIC}_${id_prefix}" | tr -c 'A-Za-z0-9_-' '_')
	else
		DEVICE_ID=$(printf '%s' "$TOPIC" | tr -c 'A-Za-z0-9_-' '_')
	fi
	BASE_TOPIC=$DEVICE_ID
	STAMP_FILE=${STAMP_FILE:-/tmp/seplos_ha_${DEVICE_ID}.stamp}
	MQTT_QUEUE=()
}

# Return success when discovery should be sent again.
ha_discovery_due() {
	local sig="$1" old_epoch="" old_sig="" now
	DISCOVERY_DUE=1
	if [ -f "$STAMP_FILE" ]; then
		read -r old_epoch old_sig < "$STAMP_FILE" || true
		now=$(date +%s)
		if [ -n "$old_epoch" ] && [ "$old_sig" = "$sig" ] && [ $((now - old_epoch)) -lt "$DISCOVERY_INTERVAL" ]; then
			DISCOVERY_DUE=0
		fi
	fi
	[ "$DISCOVERY_DUE" = 1 ]
}

mqtt_queue() {
	local topic="$1" payload="$2" retain="${3:-0}"
	MQTT_QUEUE+=("${retain}"$'\t'"${topic}"$'\t'"${payload}")
}

mqtt_flush() {
	local rc=0
	[ ${#MQTT_QUEUE[@]} -eq 0 ] && return 0
	if [ "${MQTT_DRY_RUN:-0}" = "1" ]; then
		printf '%s\n' "${MQTT_QUEUE[@]}"
		MQTT_QUEUE=()
		return 0
	fi
	printf '%s\n' "${MQTT_QUEUE[@]}" | \
		MQTT_HOST="$MQTTHOST" \
		MQTT_PORT="$MQTTPORT" \
		MQTT_USER="${MQTTUSER:-}" \
		MQTT_PASSWORD="${MQTTPASWD:-}" \
		python3 "$SCRIPT_DIR/mqtt_batch.py" || rc=$?
	MQTT_QUEUE=()
	return "$rc"
}
