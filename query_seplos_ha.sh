#!/bin/bash
export LC_ALL=C
# Read one Seplos BMS telemetry frame from the RS485 port.
# Usage: query_seplos_ha.sh 4201 [text|kv]
#   text  one value per line (default, unchanged manual output)
#   kv    KEY=value lines for the Home Assistant publisher
# The serial device is DEV in config.ini.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=ha_mqtt.sh
source "$SCRIPT_DIR/ha_mqtt.sh"

ADDR=00
OUTMODE=text

# Get a 4 ASCII digit number and divide by $1, precision $2 ( or 2dp. ) $3 == 1 for signed.
get_div()
{
	N=${rdata:$OFFSET:4}
	OFFSET=$((OFFSET + 4))
	local P=${2:-2}

	N=$(printf "%d" 0x$N)
	[ "$3" = "1" -a $N -gt 32767 ] && N=$((N - 65536))
	N=$(bc <<< "scale = $P; $N / $1")
}

read_serdata()
{
	local len rdata tries=2 rd2

	while [ "${rdata:0:1}" != "~" ]
	do
		tries=$((tries - 1))
		[ $tries -le 0 ] && { echo "Failed to read start of input char (~), read \"$rdata\"" 1>&2 ; exit 1; }
		read -r -t5 rdata <"$DEV"
	done

	len=${rdata:10:3}
	len=$((0x$len))

	while [ ${#rdata} -lt $((len + 17)) ]
	do
		read -r -t5 rd2 <"$DEV"
		[ -z "$rd2" ] && { echo "Failed to read whole response." ; exit 2; }
		rdata="$rdata$rd2"
	done

	if [ "$RQCODE" = "42" ]
	then
		OFFSET=19
		[ "${rdata:7:2}" != "00" ] && { echo "Error code ${rdata:7:2}"; exit 3; }
		
		local l NCELL=$(printf "%d" 0x${rdata:17:2})

		[ "$OUTMODE" = "kv" ] && printf 'NCELL=%s\n' "$NCELL"

		for l in $(seq 1 $NCELL)
		do
			local V=$(printf "%d" 0x${rdata:$OFFSET:4})
			OFFSET=$((OFFSET + 4))
			emit_value "CELL_$l" "$V"
		done

		local NTEMPS=$(printf "%d" 0x${rdata:$OFFSET:2})
		OFFSET=$((OFFSET + 2))

		[ "$OUTMODE" = "kv" ] && printf 'NTEMP=%s\n' "$NTEMPS"

		# The Seplos frame ends the temperature list with environmental temp, then power temp.
		for l in $(seq 1 $NTEMPS)
		do
			local T=$(printf "%d" 0x${rdata:$OFFSET:4})
			OFFSET=$((OFFSET + 4))
			T=$(bc <<< "scale = 1; ($T - 2731)/10")
			emit_value "TEMP_$l" "$T"
		done

		get_div 100 2 1		# Can't use $() because that creates a subshell
		emit_value CURRENT "$N"
		get_div 100
		emit_value VOLTAGE "$N"
		get_div 100
		emit_value RESIDUAL_AH "$N"
		OFFSET=$((OFFSET + 2))
		get_div 100
		emit_value FULL_AH "$N"
		get_div 10 1
		emit_value SOC "$N"
		get_div 100
		emit_value RATED_AH "$N"
		get_div 1 0
		emit_value CYCLES "$N"
		get_div 10 1
		emit_value SOH "$N"
		get_div 100 2
		emit_value PORT_VOLTAGE "$N"
	else
		echo "Response: \"$rdata\""
	fi

}

# $1 key, $2 value. Text mode prints the value only, so manual output stays the same.
emit_value()
{
	if [ "$OUTMODE" = "kv" ]; then
		printf '%s=%s\n' "$1" "$2"
	else
		printf '%s\n' "$2"
	fi
}

# Todo... calculate length checksum and insert in send string.

export OUTMODE=${2:-text}
if [ "$OUTMODE" != "text" ] && [ "$OUTMODE" != "kv" ]; then
	echo "Unknown output mode: $OUTMODE" >&2
	exit 1
fi

load_config "$SCRIPT_DIR/config.ini" || exit 1
if [ -z "${DEV:-}" ]; then
	echo "Set DEV in $SCRIPT_DIR/config.ini (for example DEV=/dev/ttyUSB0)" >&2
	exit 1
fi

stty -F "$DEV" sane -echo -echoe -echok 19200

SUM=0

export RQCODE=${1:0:2}
RQ="20${ADDR}46$1"
CMD=${RQ:0:8}
DATA=${RQ:8}
LEN=${#DATA}
LEN=$(printf "%03X" $LEN)
LENSUM=$((~(${LEN:0:1} + ${LEN:1:1} + ${LEN:2:1})))
LENSUM=$(printf "%X" $LENSUM)
LENSUM=${LENSUM:0-1:1}
LENSUM=$((0x$LENSUM + 1))
LENSUM=$(printf "%X" $LENSUM)
LENSUM=${LENSUM:0-1:1}
SEND=$CMD$LENSUM$LEN$DATA

for d in $(echo -n "$SEND" | od -An -td1)
do
	SUM=$((SUM + $d))
done

SUM=$((~$SUM))
SUM="$(printf "%04X" $SUM)"
SUM="${SUM:0-4:4}"
SUM=$((0x$SUM + 1))
SUM=$(printf "%04X" $SUM)
SUM="${SUM:0-4:4}"
SEND="~$SEND$SUM\r"
#echo "Sending \"$SEND\""
read_serdata &
sleep 0.2
echo -ne "$SEND" >"$DEV"
wait

