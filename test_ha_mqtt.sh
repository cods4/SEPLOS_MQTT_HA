#!/bin/bash
# Offline checks for Home Assistant discovery payloads and the MQTT publisher.
set -euo pipefail
export LC_ALL=C

cd "$(dirname "$0")"
SCRIPT_DIR=$(pwd)

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_eq() {
	local actual="$1" expected="$2" label="$3"
	if [ "$actual" != "$expected" ]; then
		printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$label" "$expected" "$actual" >&2
		exit 1
	fi
}

command -v bc >/dev/null || fail "bc is required"
command -v python3 >/dev/null || fail "python3 is required"

assert_json() {
	local payload="$1" expr="$2" label="$3"
	if ! python3 -c "$expr" "$payload"; then
		echo "FAIL: $label" >&2
		echo "$payload" >&2
		exit 1
	fi
}

python3 "$SCRIPT_DIR/mqtt_batch.py" --self-test

# shellcheck source=ha_mqtt.sh
source "$SCRIPT_DIR/ha_mqtt.sh"
# shellcheck source=bms_poll.sh
source "$SCRIPT_DIR/bms_poll.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/config.ini" <<'EOF'
# TOPIC=wrong
DEV=/dev/ttyUSB0
MQTTHOST=127.0.0.1
TOPIC=seplos
MQTTUSER=mqttuser
MQTTPASWD=mqttpassword
TELEPERIOD=10
id_prefix=364715398511
MAXSIZE=2000000
CELL_MIN_VOLT=2500
CELL_MAX_VOLT=3800
DEVICE_NAME=Seplos BMS
DISCOVERY_PREFIX=homeassistant
MQTTPORT=1883
DISCOVERY_INTERVAL=3600
PACK_CAPACITY_AH=570
EOF

load_config "$tmp/config.ini"
assert_eq "$TOPIC" "seplos" "commented TOPIC must be ignored"
assert_eq "$DEV" "/dev/ttyUSB0" "serial device"
STAMP_FILE="$tmp/stamp"
LOGNAME="$tmp/bms.log"
MQTT_DRY_RUN=1
touch "$LOGNAME"
ha_mqtt_init
assert_eq "$DEVICE_ID" "seplos_364715398511" "device id"
assert_eq "$EXPIRE_AFTER" "120" "default expire_after"

sample='NCELL=2
CELL_1=3334
CELL_2=3336
NTEMP=4
TEMP_1=31.7
TEMP_2=32.2
TEMP_3=36.5
TEMP_4=33.7
CURRENT=26.01
VOLTAGE=53.35
RESIDUAL_AH=273.97
FULL_AH=280.00
SOC=97.8
RATED_AH=280.00
CYCLES=12
SOH=100.0
PORT_VOLTAGE=54.45'

parse_bms_kv "$sample"
validate_bms_reading
publish_bms_reading > "$tmp/first.txt"

state_of() {
	awk -F '\t' -v topic="$1" '$1 == "0" && $2 == topic { print $3; exit }' "$2"
}

disc_of() {
	awk -F '\t' -v topic="$1" '$1 == "1" && $2 == topic { print $3; exit }' "$2"
}

base=seplos_364715398511
state_json=$(state_of "$base/state" "$tmp/first.txt")
[ -n "$state_json" ] || fail "missing shared state payload"
assert_json "$state_json" '
import json, sys
p = json.loads(sys.argv[1])
assert p["cell01"] == 3334 and p["cell02"] == 3336
assert p["lowest_cell_v"] == 3334 and p["highest_cell_v"] == 3336
assert p["lowest_cell_n"] == 1 and p["highest_cell_n"] == 2
assert p["difference"] == 2 and p["cell_average"] == 3335 and p["cell_median"] == 3335
assert p["cell_temp1"] == 31.7 and p["cell_temp2"] == 32.2
assert p["env_temp"] == 36.5 and p["power_temp"] == 33.7
assert round(p["charge_discharge"], 2) == 26.01
assert round(p["total_voltage"], 2) == 53.35
assert round(p["residual_capacity"], 2) == 273.97
assert round(p["rated_capacity"], 2) == 280.00
assert round(p["soc"], 1) == 97.8
' "shared state payload"

disc_json=$(disc_of "homeassistant/device/$base/config" "$tmp/first.txt")
[ -n "$disc_json" ] || fail "missing device discovery"
assert_json "$disc_json" '
import json, sys
p = json.loads(sys.argv[1])
assert p["state_topic"] == "seplos_364715398511/state"
assert p["dev"]["ids"] == ["seplos_364715398511"]
assert p["dev"]["name"] == "Seplos BMS"
assert p["dev"]["mf"] == "Seplos"
assert p["o"]["name"] == "SEPLOS MQTT"
cell = p["cmps"]["seplos_364715398511_cell01"]
assert cell["platform"] == "sensor"
assert cell["unique_id"] == "seplos_364715398511_cell01"
assert cell["default_entity_id"] == "sensor.bms_cell_01"
assert cell["name"] == "Cell 01"
assert cell["value_template"] == "{{ value_json.cell01 }}"
assert cell["device_class"] == "voltage"
assert cell["unit_of_measurement"] == "mV"
assert cell["expire_after"] == 120
soc = p["cmps"]["seplos_364715398511_soc"]
assert soc["device_class"] == "battery" and soc["unique_id"] == "seplos_364715398511_soc"
status = p["cmps"]["bmsseplosstatus66"]
assert status["default_entity_id"] == "sensor.bms_battery_status"
assert status["unique_id"] == "bmsseplosstatus66"
assert "Charging" in status["value_template"] and "Discharge" in status["value_template"] and "Standby" in status["value_template"]
power = p["cmps"]["bms_power_75432"]
assert power["device_class"] == "power" and power["unit_of_measurement"] == "W"
assert "round(0)" in power["value_template"]
assert power["default_entity_id"] == "sensor.bms_power"
discharge = p["cmps"]["bms_discharge_capacity_kwh999"]
assert discharge["device_class"] == "energy" and discharge["unique_id"] == "bms_discharge_capacity_kwh999"
assert "round(1)" in discharge["value_template"]
charge = p["cmps"]["bms_charge_capacity_kwh999"]
assert "570" in charge["value_template"] and charge["default_entity_id"] == "sensor.bms_charge_capacity"
binary = p["cmps"]["seplos_364715398511_battery_charging"]
assert binary["platform"] == "binary_sensor" and binary["device_class"] == "battery_charging"
' "device discovery payload"

grep -q "Published Home Assistant MQTT discovery" "$LOGNAME" || fail "discovery was not logged"

publish_bms_reading > "$tmp/second.txt"
if awk -F '\t' '$1 == "1" { found=1 } END { exit !found }' "$tmp/second.txt"; then
	fail "discovery was sent again inside the interval"
fi
assert_json "$(state_of "$base/state" "$tmp/second.txt")" '
import json, sys
p = json.loads(sys.argv[1])
assert round(p["total_voltage"], 2) == 53.35
' "voltage still published"
states_first=$(awk -F '\t' '$1 == "0" { c++ } END { print c+0 }' "$tmp/first.txt")
states_second=$(awk -F '\t' 'END { print NR+0 }' "$tmp/second.txt")
assert_eq "$states_second" "$states_first" "second publish is state only"

discharge=${sample/CURRENT=26.01/CURRENT=-10.00}
parse_bms_kv "$discharge"
validate_bms_reading
publish_bms_reading > "$tmp/discharge.txt"
assert_json "$(state_of "$base/state" "$tmp/discharge.txt")" '
import json, sys
p = json.loads(sys.argv[1])
assert round(p["charge_discharge"], 2) == -10.00
' "negative current"

if parse_bms_kv "Error code 01"; then
	fail "error text was accepted"
fi

bad='NCELL=1
CELL_1=1000
NTEMP=0
CURRENT=1
VOLTAGE=50
RESIDUAL_AH=10
FULL_AH=100
SOC=50
RATED_AH=100
CYCLES=1
SOH=100
PORT_VOLTAGE=50'
parse_bms_kv "$bad"
if validate_bms_reading; then
	fail "out of range cell was accepted"
fi
grep -q "not between" "$LOGNAME" || fail "range warning was not logged"

# One MQTT connection publishes every queued message, including a payload
# longer than 127 bytes so the remaining-length encoding is exercised.
python3 - "$tmp/pubs.txt" "$tmp/port" <<'PY' &
import socket, struct, sys
pub_path, port_path = sys.argv[1], sys.argv[2]

def read_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf

def read_packet(conn):
    header = read_exact(conn, 1)[0]
    value = 0
    mult = 1
    while True:
        digit = read_exact(conn, 1)[0]
        value += (digit & 0x7F) * mult
        if digit & 0x80 == 0:
            break
        mult *= 128
    body = read_exact(conn, value) if value else b""
    return header, body

def dec_str(buf, i):
    n = struct.unpack("!H", buf[i:i + 2])[0]
    return buf[i + 2:i + 2 + n].decode(), i + 2 + n

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(1)
srv.settimeout(5)
with open(port_path, "w", encoding="utf-8") as fh:
    fh.write(str(srv.getsockname()[1]))
conn, _ = srv.accept()
conn.settimeout(5)
lines = []
try:
    while True:
        header, body = read_packet(conn)
        kind = header >> 4
        if kind == 1:
            proto, i = dec_str(body, 0)
            i += 2  # protocol level and flags
            flags = body[i - 1]
            i += 2  # keepalive
            _cid, i = dec_str(body, i)
            user = password = ""
            if flags & 0x80:
                user, i = dec_str(body, i)
            if flags & 0x40:
                password, i = dec_str(body, i)
            lines.append(f"AUTH\t{user}\t{password}")
            conn.sendall(bytes([0x20, 0x02, 0x00, 0x00]))
        elif kind == 3:
            topic, i = dec_str(body, 0)
            payload = body[i:].decode()
            lines.append(f"PUB\t{header & 1}\t{topic}\t{payload}")
        elif kind == 14:
            break
except EOFError:
    pass
finally:
    conn.close()
    srv.close()
with open(pub_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
PY
server_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	[ -s "$tmp/port" ] && break
	sleep 0.05
done
[ -s "$tmp/port" ] || fail "fake broker did not start"
port=$(cat "$tmp/port")
long_json=$(python3 -c 'print("{" + "\"k\":\"" + ("x" * 180) + "\"}")')
{
	printf '0\tseplos_364715398511/soc/total_voltage\t53.35\n'
	printf '1\thomeassistant/sensor/seplos_364715398511/bms_total_voltage/config\t%s\n' "$long_json"
	printf '1\thomeassistant/sensor/seplos_364715398511/bms_cell_03/config\t\n'
} | MQTT_HOST=127.0.0.1 MQTT_PORT="$port" MQTT_USER=mqttuser MQTT_PASSWORD=mqttpassword \
	python3 "$SCRIPT_DIR/mqtt_batch.py"
wait "$server_pid"

assert_eq "$(awk -F '\t' '$1 == "AUTH" { print $2 ":" $3 }' "$tmp/pubs.txt")" "mqttuser:mqttpassword" "mqtt auth"
assert_eq "$(awk -F '\t' '$1 == "PUB" && $3 ~ /total_voltage$/ { print $2 ":" $4 }' "$tmp/pubs.txt")" "0:53.35" "state publish"
got_long=$(awk -F '\t' '$1 == "PUB" && $3 ~ /bms_total_voltage/ { print $2 ":" $4 }' "$tmp/pubs.txt")
assert_eq "${got_long%%:*}" "1" "discovery retain flag"
assert_eq "${got_long#*:}" "$long_json" "long discovery payload"
cleared_pub=$(awk -F '\t' '$1 == "PUB" && $3 ~ /bms_cell_03/ { print $2 ":" $4 }' "$tmp/pubs.txt")
assert_eq "$cleared_pub" "1:" "retained empty discovery removes the entity"

echo "OK"
