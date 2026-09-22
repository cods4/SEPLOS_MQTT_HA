# Seplos MQTT
Read data From Seplos BMS and send them to the Home Assistant

This is a bash script that reads data from a Seplos BMS over RS485 and publishes it to Home Assistant with MQTT discovery. Home Assistant creates the device and its sensors, binary sensor, and cell statistics from those messages. The topic layout follows the same idea as [batmon-ha](https://github.com/fl4p/batmon-ha): one state topic per metric, plus a retained discovery payload for each entity.

## Hardware requirements:
1. Raspberry (i use an RPI4)
2. USB to RS485 adapter
3. [Seplos BMS](https://www.alibaba.com/product-detail/Seplos-50A-100A-150A-200A-24V_1600246972725.html?spm=a2700.galleryofferlist.normal_offer.d_title.41f63a936kcnil)
4. Home assitant with configured MQTT broker

## Installation and configuration

Prepare Raspberry with Raspberry PI OS
perform the apt-get update and the apt-get upgrade

move to the your user home and use git clone to download this script

```
git clone https://github.com/byte4geek/SEPLOS_MQTT.git

chmod 700 ~/SEPLOS_MQTT/query_seplos_ha.sh ~/SEPLOS_MQTT/run_bms_query.sh
```

edit the script ```~/SEPLOS_MQTT/query_seplos_ha.sh``` and set the COM port that you use (Ex. DEV=/dev/ttyUSB0)

edit the file config.ini ```~/SEPLOS_MQTT/config.ini``` and set the below parameters with your MQTT server information:

```
# insert the mqtt info below
# mqtt host name
MQTTHOST=192.168.1.2
# name inserted into topic
TOPIC=seplos
# mqtt user name
MQTTUSER=mqttuser
# mqtt password
MQTTPASWD=mqttpassword
# time to read and update datas vs mqtt server and Home Assistant, not used for run_bms_query_ha.sh
TELEPERIOD=10
# is a prefix inserted into topic, chage it if you need
id_prefix=364715398511
# Max size of the BMS_error.log and nohup.out
MAXSIZE=2000000
# Minmum voltage in mV permitted for Cell value for correct output
CELL_MIN_VOLT=2500
# Maximum voltage in mV permitted for Cell value for correct output
CELL_MAX_VOLT=3800
# Friendly name of the Home Assistant device created by MQTT discovery
DEVICE_NAME=Seplos BMS
# Discovery prefix configured in the Home Assistant MQTT integration
DISCOVERY_PREFIX=homeassistant
# MQTT broker port
MQTTPORT=1883
# How often to resend retained discovery messages, in seconds
DISCOVERY_INTERVAL=3600
# Nominal pack size in Ah for charge capacity. Usable Ah is this times SOH.
# Leave unset to use the rated capacity reported by the BMS.
#PACK_CAPACITY_AH=570
```

then install the following pkg:

```
sudo apt-get install bc
```

Python 3 builds the discovery payloads and publishes every MQTT message on one broker connection. Raspberry Pi OS already includes it. The machine that runs the script does not need `mosquitto-clients`. Home Assistant still needs its MQTT broker.

edit the crontab to run the script at the boot

```crontab -e``` and add the line below:
```
@reboot /home/pi/SEPLOS_MQTT/run_bms_query.sh
```

## Manual execution
simply run 
```~/SEPLOS_MQTT/run_bms_query.sh```
or
```nohup ~/SEPLOS_MQTT/run_bms_query.sh &```

To test if the communication is working try to run
```~/SEPLOS_MQTT/query_seplos_ha.sh 4201```

you can see the output like this:
```
3334
3334
3334
3335
3334
3335
3334
3335
3335
3336
3335
3335
3335
3335
3335
3334
31.7
32.2
32.0
31.8
36.5
33.7
0
53.35
273.97
280.00
97.8
280.00
12
100.0
54.45
```

`query_seplos_ha.sh 4201 kv` prints the same reading as `KEY=value` lines. The publisher uses that form.

On the first good reading, and again every `DISCOVERY_INTERVAL` seconds, the script publishes one retained MQTT device discovery payload. That payload lists every entity. Each entity has a `value_template`, so Home Assistant builds the sensors from one shared JSON state message. Battery status, power, and charge/discharge capacity are templates in that payload, evaluated by Home Assistant:

```
homeassistant/device/seplos_1/config
seplos_1/state    {"cell01":3431,"charge_discharge":26.01,"total_voltage":54.90,"soc":96.8,...}
```

`id_prefix` is part of the device id and of every `unique_id`. Leave it unchanged after the first start, otherwise Home Assistant creates a second device. `DEVICE_NAME` is the name shown on that device.

## Installation and configuration for Home Assistant only

This section describe the installation and configuration for people that have the rs485 directly connecte to the Home Assistant Raspberry.
Require Home Assistant Operating System

install the docker "SSH & Web Terminal" https://github.com/hassio-addons/addon-ssh and configure it

connect to the HA with ssh port 22

```
cd /share

git clone https://github.com/byte4geek/SEPLOS_MQTT.git

chmod 700 ./SEPLOS_MQTT/query_seplos_ha.sh ./SEPLOS_MQTT/run_bms_query_ha.sh

ssh-copy-id root@<YOUR HA IP>     ---> and choose yes
```

edit the script ```./SEPLOS_MQTT/query_seplos_ha.sh``` and set the COM port that you use (Ex. DEV=/dev/ttyUSB0)

edit the file config.ini ```./SEPLOS_MQTT/config.ini``` and set the below parameters with your MQTT server information:

```
# insert the mqtt info below
# mqtt host name
MQTTHOST=192.168.1.2
# name inserted into topic
TOPIC=seplos
# mqtt user name
MQTTUSER=mqttuser
# mqtt password
MQTTPASWD=mqttpassword
# time to read and update datas vs mqtt server and Home Assistant, not used for run_bms_query_ha.sh
TELEPERIOD=10
# is a prefix inserted into topic, chage it if you need
id_prefix=364715398511
# Max size of the BMS_error.log and nohup.out
MAXSIZE=2000000
# Minmum voltage in mV permitted for Cell value for correct output
CELL_MIN_VOLT=2500
# Maximum voltage in mV permitted for Cell value for correct output
CELL_MAX_VOLT=3800
# Friendly name of the Home Assistant device created by MQTT discovery
DEVICE_NAME=Seplos BMS
# Discovery prefix configured in the Home Assistant MQTT integration
DISCOVERY_PREFIX=homeassistant
# MQTT broker port
MQTTPORT=1883
# How often to resend retained discovery messages, in seconds
DISCOVERY_INTERVAL=3600
# Nominal pack size in Ah for charge capacity. Usable Ah is this times SOH.
# Leave unset to use the rated capacity reported by the BMS.
#PACK_CAPACITY_AH=570
```

create a shell command in HA:
```
seplos_query: ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@<YOUR HA IP> "cd /share/SEPLOS_MQTT;nohup /share/SEPLOS_MQTT/run_bms_query_ha.sh &"
```

then create an automation to run the script every 10 seconds or what you prefer
```
- id: seplos_startup_automation
  alias: Seplos Startup Automation
  trigger:
    platform: time_pattern
    seconds: "/10"
  action:
    - service: shell_command.seplos_query
```

## Configuring Home Assistant

Install and start the Mosquitto broker add-on, then add the MQTT integration. Discovery is enabled on that integration by default. `DISCOVERY_PREFIX` in `config.ini` must match the integration's discovery prefix (`homeassistant`).

Start `run_bms_query.sh`, or the automation that calls `run_bms_query_ha.sh`. After the first good BMS read, the device named in `DEVICE_NAME` appears under Settings → Devices & services → MQTT. It includes pack voltage, current, power, SoC, SoH, capacity, temperatures, per-cell voltages in mV, min/max/delta/average/median, charge and discharge capacity in kWh, a charging binary sensor, and battery status (Charging, Discharge, or Standby).

Set `TOPIC=seplos` and `id_prefix=1` when the existing MQTT sensors use ids such as `seplos_1_cell01`. Discovery then reuses those ids. `PACK_CAPACITY_AH=570` keeps the charge-capacity formula that used a 570 Ah pack.

`lovelace.yaml` is an optional dashboard for those entities (`sensor.bms_soc`, `sensor.bms_cell_01`, `sensor.bms_discharge_capacity`, `sensor.bms_charge_capacity`, `sensor.bms_battery_status`, `binary_sensor.bms_battery_charging`, and the rest of the `bms_*` object ids).

When upgrading, remove the Seplos `mqtt:` sensor list and the template sensors for battery status, discharge capacity, charge capacity, and power. The MQTT sensors keep their history because the `unique_id` matches. The four template sensors are a different integration, so delete those entities after removing them from YAML. Discovery then creates `sensor.bms_battery_status`, `sensor.bms_discharge_capacity`, `sensor.bms_charge_capacity`, and `sensor.bms_power`.

example:
![BMS dashboard](https://github.com/byte4geek/Seplos-BMS-vs-Home-Assistant/raw/main/bms_ha_panel.JPG)

# Donation
Buy me a coffee

[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=VK4CSX9NVQAZU)
