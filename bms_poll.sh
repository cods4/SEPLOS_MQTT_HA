#!/bin/bash
# One BMS read: parse the query output, reject bad frames, publish MQTT state
# and (periodically) Home Assistant discovery.

log_msg() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOGNAME"
}

is_num() {
	[[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

is_uint() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

acquire_poll_lock() {
	local lock="/tmp/seplos_poll_${DEVICE_ID}.lock"
	exec 9>"$lock" || return 1
	if command -v flock >/dev/null 2>&1; then
		flock -n 9
		return $?
	fi
	return 0
}

rotate_file() {
	local file="$1" mode="$2" size
	[ -f "$file" ] || return 0
	size=$(wc -c < "$file" | tr -d '[:space:]')
	[ "$size" -ge "$MAXSIZE" ] || return 0
	if [ "$mode" = "truncate" ]; then
		cp "$file" "$file.old"
		: > "$file"
	else
		mv "$file" "$file.old"
	fi
}

parse_bms_kv() {
	local data="$1" line key val i req
	PARSE_ERROR=
	NCELL=0
	NTEMP=0
	CELL=()
	TEMP=()
	CURRENT=
	VOLTAGE=
	RESIDUAL_AH=
	FULL_AH=
	SOC=
	RATED_AH=
	CYCLES=
	SOH=
	PORT_VOLTAGE=
	CELL_TEMP_COUNT=0
	ENV_TEMP=
	POWER_TEMP=

	while IFS= read -r line || [ -n "$line" ]; do
		line=$(trim "$line")
		[ -z "$line" ] && continue
		if [[ "$line" != *=* ]]; then
			PARSE_ERROR=$line
			return 1
		fi
		key=$(trim "${line%%=*}")
		val=$(trim "${line#*=}")
		case "$key" in
			NCELL)
				is_uint "$val" && [ "$val" -ge 1 ] && [ "$val" -le 32 ] || { PARSE_ERROR="NCELL"; return 1; }
				NCELL=$val
				;;
			NTEMP)
				is_uint "$val" && [ "$val" -le 16 ] || { PARSE_ERROR="NTEMP"; return 1; }
				NTEMP=$val
				;;
			CELL_*)
				i=${key#CELL_}
				is_uint "$i" && is_uint "$val" || { PARSE_ERROR="$key"; return 1; }
				CELL[i]=$val
				;;
			TEMP_*)
				i=${key#TEMP_}
				is_uint "$i" && is_num "$val" || { PARSE_ERROR="$key"; return 1; }
				TEMP[i]=$val
				;;
			CURRENT|VOLTAGE|RESIDUAL_AH|FULL_AH|SOC|RATED_AH|CYCLES|SOH|PORT_VOLTAGE)
				is_num "$val" || { PARSE_ERROR="$key"; return 1; }
				printf -v "$key" '%s' "$val"
				;;
			*)
				PARSE_ERROR="unknown $key"
				return 1
				;;
		esac
	done <<< "$data"

	[ "$NCELL" -ge 1 ] || { PARSE_ERROR="missing NCELL"; return 1; }
	for ((i = 1; i <= NCELL; i++)); do
		is_uint "${CELL[i]}" || { PARSE_ERROR="missing CELL_$i"; return 1; }
	done
	for ((i = 1; i <= NTEMP; i++)); do
		is_num "${TEMP[i]}" || { PARSE_ERROR="missing TEMP_$i"; return 1; }
	done
	for req in CURRENT VOLTAGE RESIDUAL_AH FULL_AH SOC RATED_AH CYCLES SOH PORT_VOLTAGE; do
		is_num "${!req}" || { PARSE_ERROR="missing $req"; return 1; }
	done

	if [ "$NTEMP" -ge 2 ]; then
		CELL_TEMP_COUNT=$((NTEMP - 2))
		ENV_TEMP=${TEMP[$((NTEMP - 1))]}
		POWER_TEMP=${TEMP[$NTEMP]}
	elif [ "$NTEMP" -eq 1 ]; then
		POWER_TEMP=${TEMP[1]}
	fi
	return 0
}

validate_bms_reading() {
	local i v
	for ((i = 1; i <= NCELL; i++)); do
		v=${CELL[i]}
		if [ "$v" -lt "$CELL_MIN_VOLT" ] || [ "$v" -gt "$CELL_MAX_VOLT" ]; then
			log_msg "Warning: The value $v for cell $i is not between $CELL_MIN_VOLT and $CELL_MAX_VOLT, skip data"
			return 1
		fi
	done
	if [ "$(bc <<< "$SOC > 100")" = 1 ]; then
		log_msg "Warning: SOC value over 100 value=$SOC skip data"
		return 1
	fi
	if [ "$(bc <<< "$SOC < 1")" = 1 ]; then
		log_msg "Warning: SOC value below 1 SOC=$SOC skip data"
		return 1
	fi
	return 0
}

ha_payload() {
	local mode="$1" cells="" temps="" i
	for ((i = 1; i <= NCELL; i++)); do
		cells+="${CELL[i]},"
	done
	for ((i = 1; i <= CELL_TEMP_COUNT; i++)); do
		temps+="${TEMP[i]},"
	done
	HA_DEVICE_ID="$DEVICE_ID" \
		HA_DEVICE_NAME="$DEVICE_NAME" \
		HA_EXPIRE_AFTER="$EXPIRE_AFTER" \
		HA_PACK_AH="${PACK_CAPACITY_AH:-}" \
		HA_CELLS="${cells%,}" \
		HA_CELL_TEMPS="${temps%,}" \
		HA_ENV_TEMP="${ENV_TEMP:-}" \
		HA_POWER_TEMP="${POWER_TEMP:-}" \
		HA_CURRENT="$CURRENT" \
		HA_VOLTAGE="$VOLTAGE" \
		HA_RESIDUAL="$RESIDUAL_AH" \
		HA_FULL="$FULL_AH" \
		HA_RATED="$RATED_AH" \
		HA_SOC="$SOC" \
		HA_SOH="$SOH" \
		HA_CYCLES="$CYCLES" \
		HA_PORT="$PORT_VOLTAGE" \
		python3 "$SCRIPT_DIR/ha_payload.py" "$mode"
}

publish_bms_reading() {
	local discover=0 sig payload

	sig="${NCELL}:${NTEMP}"
	if ha_discovery_due "$sig"; then
		discover=1
	fi

	MQTT_QUEUE=()
	if [ "$discover" = 1 ]; then
		payload=$(ha_payload discovery) || return 1
		mqtt_queue "${DISCOVERY_PREFIX}/device/${DEVICE_ID}/config" "$payload" 1
	fi
	payload=$(ha_payload state) || return 1
	mqtt_queue "${BASE_TOPIC}/state" "$payload" 0

	if ! mqtt_flush; then
		return 1
	fi
	if [ "$discover" = 1 ]; then
		printf '%s %s\n' "$(date +%s)" "$sig" > "$STAMP_FILE"
		log_msg "Published Home Assistant MQTT discovery (${NCELL} cells, ${CELL_TEMP_COUNT} cell temperatures)"
	fi
}

poll_once() {
	local query_output
	if ! query_output=$("$SCRIPT_DIR/query_seplos_ha.sh" 4201 kv 2>&1); then
		log_msg "Warning: BMS query failed: ${query_output//$'\n'/ }"
		return 0
	fi
	if ! parse_bms_kv "$query_output"; then
		log_msg "Warning: ignoring unreadable BMS data${PARSE_ERROR:+: $PARSE_ERROR}"
		return 0
	fi
	if ! validate_bms_reading; then
		return 0
	fi
	if ! publish_bms_reading; then
		log_msg "Warning: MQTT publish failed"
	fi
}
