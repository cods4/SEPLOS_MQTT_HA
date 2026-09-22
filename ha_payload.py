#!/usr/bin/env python3
"""Build the Home Assistant MQTT device-discovery payload and the shared state JSON.

Derived sensors (battery status, power, charge and discharge capacity) are Jinja
value_template entries in the discovery payload. Home Assistant evaluates them
from the one state message, the same role as template sensors in configuration.yaml.
"""

import json
import os
import sys


def optional_number(name):
    raw = os.environ.get(name, "")
    if raw == "":
        return None
    return json.loads(raw)


def number_list(name):
    raw = os.environ.get(name, "")
    if raw == "":
        return []
    return [json.loads(part) for part in raw.split(",") if part != ""]


def cell_stats(cells):
    indexed = list(enumerate(cells, start=1))
    min_i, min_v = min(indexed, key=lambda item: (item[1], item[0]))
    max_i, max_v = max(indexed, key=lambda item: (item[1], -item[0]))
    ordered = sorted(cells)
    count = len(ordered)
    if count % 2:
        median = ordered[count // 2]
    else:
        median = (ordered[count // 2 - 1] + ordered[count // 2]) // 2
    return {
        "lowest_cell_v": min_v,
        "lowest_cell_n": min_i,
        "highest_cell_v": max_v,
        "highest_cell_n": max_i,
        "difference": max_v - min_v,
        "cell_average": sum(cells) // count,
        "cell_median": median,
    }


def reading_from_env():
    cells = number_list("HA_CELLS")
    if not cells:
        raise ValueError("HA_CELLS is empty")
    state = {}
    for index, voltage in enumerate(cells, start=1):
        state[f"cell{index:02d}"] = voltage
    state.update(cell_stats(cells))
    for index, temp in enumerate(number_list("HA_CELL_TEMPS"), start=1):
        state[f"cell_temp{index}"] = temp
    for key, env_name in (
        ("env_temp", "HA_ENV_TEMP"),
        ("power_temp", "HA_POWER_TEMP"),
        ("charge_discharge", "HA_CURRENT"),
        ("total_voltage", "HA_VOLTAGE"),
        ("residual_capacity", "HA_RESIDUAL"),
        ("full_capacity", "HA_FULL"),
        ("rated_capacity", "HA_RATED"),
        ("soc", "HA_SOC"),
        ("soh", "HA_SOH"),
        ("cycles", "HA_CYCLES"),
        ("port_voltage", "HA_PORT"),
    ):
        value = optional_number(env_name)
        if value is not None:
            state[key] = value
    return state


def sensor(unique_id, name, entity_id, value_template, **extra):
    component = {
        "platform": "sensor",
        "name": name,
        "unique_id": unique_id,
        "default_entity_id": entity_id,
        "value_template": value_template,
        "expire_after": int(os.environ["HA_EXPIRE_AFTER"]),
    }
    component.update(extra)
    return component


def discovery_payload(device_id):
    expire = os.environ["HA_EXPIRE_AFTER"]
    pack = os.environ.get("HA_PACK_AH", "")
    if pack:
        json.loads(pack)
        pack_expr = f"({pack})"
    else:
        pack_expr = "(value_json.rated_capacity | float(0))"
    components = {}

    cell_count = len(number_list("HA_CELLS"))
    for index in range(1, cell_count + 1):
        unique_id = f"{device_id}_cell{index:02d}"
        components[unique_id] = sensor(
            unique_id,
            f"BMS Cell {index:02d}",
            f"sensor.bms_cell_{index:02d}",
            f"{{{{ value_json.cell{index:02d} }}}}",
            device_class="voltage",
            state_class="measurement",
            unit_of_measurement="mV",
            suggested_display_precision=0,
            icon="mdi:car-battery",
        )

    plain = (
        ("lowest_cell_v", "BMS Lowest Cell V", "sensor.bms_lowest_cell_v", "voltage", "mV", "mdi:car-battery", 0),
        ("highest_cell_v", "BMS Highest Cell V", "sensor.bms_highest_cell_v", "voltage", "mV", "mdi:car-battery", 0),
        ("difference", "BMS Difference", "sensor.bms_difference", "voltage", "mV", "mdi:vector-difference", 0),
        ("cell_average", "BMS Cell Average", "sensor.bms_cell_average", "voltage", "mV", "mdi:car-battery", 0),
        ("cell_median", "BMS Cell Median", "sensor.bms_cell_median", "voltage", "mV", "mdi:car-battery", 0),
    )
    for key, name, entity_id, device_class, unit, icon, precision in plain:
        unique_id = f"{device_id}_{key}"
        components[unique_id] = sensor(
            unique_id, name, entity_id, f"{{{{ value_json.{key} }}}}",
            device_class=device_class, state_class="measurement",
            unit_of_measurement=unit, suggested_display_precision=precision, icon=icon,
        )
    for key, name, entity_id in (
        ("lowest_cell_n", "BMS Lowest Cell N", "sensor.bms_lowest_cell_n"),
        ("highest_cell_n", "BMS Highest Cell N", "sensor.bms_highest_cell_n"),
    ):
        unique_id = f"{device_id}_{key}"
        components[unique_id] = sensor(
            unique_id, name, entity_id, f"{{{{ value_json.{key} }}}}",
            state_class="measurement", suggested_display_precision=0, icon="mdi:battery-outline",
        )

    temp_count = len(number_list("HA_CELL_TEMPS"))
    for index in range(1, temp_count + 1):
        unique_id = f"{device_id}_cell_temp{index}"
        components[unique_id] = sensor(
            unique_id, f"BMS Cell Temp {index}", f"sensor.bms_cell_temp_{index}",
            f"{{{{ value_json.cell_temp{index} }}}}",
            device_class="temperature", state_class="measurement",
            unit_of_measurement="°C", suggested_display_precision=1,
        )
    if os.environ.get("HA_ENV_TEMP", "") != "":
        components[f"{device_id}_env_temp"] = sensor(
            f"{device_id}_env_temp", "BMS Env Temp", "sensor.bms_env_temp",
            "{{ value_json.env_temp }}",
            device_class="temperature", state_class="measurement",
            unit_of_measurement="°C", suggested_display_precision=1,
        )
    if os.environ.get("HA_POWER_TEMP", "") != "":
        components[f"{device_id}_power_temp"] = sensor(
            f"{device_id}_power_temp", "BMS Power Temp", "sensor.bms_power_temp",
            "{{ value_json.power_temp }}",
            device_class="temperature", state_class="measurement",
            unit_of_measurement="°C", suggested_display_precision=1,
        )

    direct = (
        ("charge_discharge", "BMS Charge Discharge", "sensor.bms_charge_discharge", "current", "A", "mdi:current-dc", 2),
        ("total_voltage", "BMS Total Voltage", "sensor.bms_total_voltage", "voltage", "V", "mdi:sine-wave", 2),
        ("port_voltage", "BMS Port Voltage", "sensor.bms_port_voltage", "voltage", "V", "mdi:sine-wave", 2),
        ("soc", "BMS SOC", "sensor.bms_soc", "battery", "%", "mdi:battery-high", 1),
    )
    for key, name, entity_id, device_class, unit, icon, precision in direct:
        unique_id = f"{device_id}_{key}"
        components[unique_id] = sensor(
            unique_id, name, entity_id, f"{{{{ value_json.{key} }}}}",
            device_class=device_class, state_class="measurement",
            unit_of_measurement=unit, suggested_display_precision=precision, icon=icon,
        )
    for key, name, entity_id, unit, icon, precision in (
        ("residual_capacity", "BMS Residual Capacity", "sensor.bms_residual_capacity", "Ah", "mdi:battery-50", 2),
        ("full_capacity", "BMS Full Capacity", "sensor.bms_full_capacity", "Ah", "mdi:battery-heart-variant", 2),
        ("rated_capacity", "BMS Rated Capacity", "sensor.bms_rated_capacity", "Ah", "mdi:battery-heart-variant", 2),
        ("soh", "BMS SOH", "sensor.bms_soh", "%", "mdi:percent-box", 1),
    ):
        unique_id = f"{device_id}_{key}"
        components[unique_id] = sensor(
            unique_id, name, entity_id, f"{{{{ value_json.{key} }}}}",
            state_class="measurement", unit_of_measurement=unit,
            suggested_display_precision=precision, icon=icon,
        )
    components[f"{device_id}_cycles"] = sensor(
        f"{device_id}_cycles", "BMS Cycles", "sensor.bms_cycles",
        "{{ value_json.cycles }}",
        state_class="measurement", suggested_display_precision=0, icon="mdi:counter",
    )

    # These replace the configuration.yaml template sensors. The Jinja runs in
    # Home Assistant against this device's JSON state message.
    components["bmsseplosstatus66"] = sensor(
        "bmsseplosstatus66", "BMS Battery Status", "sensor.bms_battery_status",
        "{% set status = value_json.charge_discharge | float(0) %}"
        "{% if status > 0 %}Charging"
        "{% elif status < 0 %}Discharge"
        "{% elif status == 0 %}Standby"
        "{% else %}N/A{% endif %}",
        icon="mdi:information-outline",
    )
    components["bms_discharge_capacity_kwh999"] = sensor(
        "bms_discharge_capacity_kwh999", "BMS Discharge Capacity", "sensor.bms_discharge_capacity",
        "{{ (((value_json.residual_capacity | float(0) * value_json.total_voltage | float(0))) | round(3) | float * 0.001) | round(1) }}",
        device_class="energy", unit_of_measurement="kWh",
        suggested_display_precision=1, icon="mdi:home-battery",
    )
    components["bms_charge_capacity_kwh999"] = sensor(
        "bms_charge_capacity_kwh999", "BMS Charge Capacity", "sensor.bms_charge_capacity",
        "{{ (((" + pack_expr + " * (value_json.soh | float(0) / 100)) - value_json.residual_capacity | float(0)) * value_json.total_voltage | float(0) * 0.001) | round(1) }}",
        device_class="energy", unit_of_measurement="kWh",
        suggested_display_precision=1, icon="mdi:home-battery",
    )
    components["bms_power_75432"] = sensor(
        "bms_power_75432", "BMS Power", "sensor.bms_power",
        "{{ (value_json.total_voltage | float(0) * value_json.charge_discharge | float(0)) | round(0) }}",
        device_class="power", state_class="measurement", unit_of_measurement="W",
        suggested_display_precision=0, icon="mdi:flash",
    )
    components[f"{device_id}_battery_charging"] = {
        "platform": "binary_sensor",
        "name": "BMS Charging",
        "unique_id": f"{device_id}_battery_charging",
        "default_entity_id": "binary_sensor.bms_battery_charging",
        "device_class": "battery_charging",
        "payload_on": "ON",
        "payload_off": "OFF",
        "expire_after": int(expire),
        "value_template": "{% if value_json.charge_discharge | float(0) > 0 %}ON{% else %}OFF{% endif %}",
    }

    return {
        "dev": {
            "ids": [device_id],
            "name": os.environ.get("HA_DEVICE_NAME", "Seplos BMS"),
            "mf": "Seplos",
            "mdl": "BMS",
        },
        "o": {
            "name": "SEPLOS MQTT",
            "sw": "1.0",
        },
        "cmps": components,
        "state_topic": f"{device_id}/state",
        "qos": 0,
    }


def main(argv):
    if len(argv) != 2 or argv[1] not in ("state", "discovery"):
        print("usage: ha_payload.py state|discovery", file=sys.stderr)
        return 2
    try:
        if argv[1] == "state":
            payload = reading_from_env()
        else:
            payload = discovery_payload(os.environ["HA_DEVICE_ID"])
    except Exception as exc:
        print(f"payload build failed: {exc}", file=sys.stderr)
        return 1
    json.dump(payload, sys.stdout, separators=(",", ":"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
