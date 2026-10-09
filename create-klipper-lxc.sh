#!/usr/bin/env bash
# Run on the Proxmox HOST as root. Creates a NEW container only.
# Optional overrides:
# CTID=105 IP=192.168.1.244/24 GW=192.168.1.1 bash create-klipper-lxc.sh
# PRINTER_CFG=/root/printer.cfg bash create-klipper-lxc.sh
# Defaults: next free CTID; local storage; vmbr0; 192.168.1.246/24; 2 cores/2 GiB/12 GiB.
# Sources: proxmox/pve-docs; Klipper3d/klipper; Arksine/moonraker;
# mainsail-crew/mainsail and mainsail-crew/mainsail-config (official repositories).
set -Eeuo pipefail
trap 'printf "\nFailed at line %s. Any created container is retained; no automatic deletion.\n" "$LINENO" >&2' ERR
[[ ${EUID} -eq 0 ]] || { echo 'Run as root on the Proxmox host.' >&2; exit 1; }
for cmd in pct pveam pvesm pvesh python3; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd; run on Proxmox VE." >&2; exit 1; }
done
[[ $(dpkg --print-architecture) == amd64 ]] || { echo 'This script targets an amd64 Proxmox host.' >&2; exit 1; }
CTID=${CTID:-$(pvesh get /cluster/nextid)}
STORAGE=local
TEMPLATE_STORAGE=local
BRIDGE=${BRIDGE:-vmbr0}
IP=${IP:-192.168.1.246/24}
GW=${GW:-$(ip -4 route show default dev "$BRIDGE" | awk '/via/ {print $3; exit}')}
CORES=${CORES:-2}
RAM=${RAM:-2048}
DISK_GB=${DISK_GB:-12}
PRINTER_CFG=${PRINTER_CFG:-}
[[ "$CTID" =~ ^[1-9][0-9]{2,8}$ ]] || { echo 'Invalid CTID.' >&2; exit 1; }
[[ -e /etc/pve/lxc/$CTID.conf || -e /etc/pve/qemu-server/$CTID.conf ]] && { echo "ID $CTID is already used; refusing to overwrite it." >&2; exit 1; }
[[ -d /sys/class/net/$BRIDGE/bridge ]] || { echo "Bridge $BRIDGE does not exist." >&2; exit 1; }
for value in "$CORES" "$RAM" "$DISK_GB"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo 'Resources must be positive integers.' >&2; exit 1; }
done
[[ -z "$PRINTER_CFG" || -f "$PRINTER_CFG" ]] || { echo "Printer config not found: $PRINTER_CFG" >&2; exit 1; }
if [[ "$IP" != dhcp ]]; then
  [[ -n "$GW" ]] || { echo 'No default gateway found on vmbr0. Run with GW=your-router-IP.' >&2; exit 1; }
  python3 - "$IP" "$GW" <<'PY'
import ipaddress,sys
addr=ipaddress.ip_interface(sys.argv[1]);gw=ipaddress.ip_address(sys.argv[2])
assert addr.version==gw.version==4 and '/' in sys.argv[1], 'Use IPv4/CIDR and IPv4 gateway'
assert gw in addr.network, 'Gateway is outside the subnet'
PY
fi
for content in rootdir vztmpl; do
  if ! pvesm status --content "$content" | awk '$1=="local" && $3=="active" {found=1} END {exit !found}'; then
    echo "local storage needs content type $content enabled. Show /etc/pve/storage.cfg." >&2
    exit 1
  fi
done
echo 'Updating Debian template catalogue...'
pveam update
catalog=$(pveam available --section system)
TEMPLATE=$(printf '%s\n' "$catalog" | awk '$2 ~ /^debian-13-standard_.*_amd64.tar/ {print $2}' | sort -V | tail -n 1)
if [[ -z "$TEMPLATE" ]]; then
  TEMPLATE=$(printf '%s\n' "$catalog" | awk '$2 ~ /^debian-12-standard_.*_amd64.tar/ {print $2}' | sort -V | tail -n 1)
fi
[[ -n "$TEMPLATE" ]] || { echo 'No Debian 12/13 amd64 template in the catalogue.' >&2; exit 1; }
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
net="name=eth0,bridge=$BRIDGE,ip=$IP,type=veth"
[[ "$IP" == dhcp ]] || net+=",gw=$GW"
printf 'Creating CT %s: %s, storage %s, network %s\n' "$CTID" "$TEMPLATE" "$STORAGE" "$IP"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname hypercube-klipper --ostype debian --unprivileged 1 \
  --features nesting=1 --cores "$CORES" --memory "$RAM" --swap 512 \
  --rootfs "$STORAGE:$DISK_GB" --net0 "$net" --onboot 1 \
  --description 'HyperCube: Klipper / Moonraker / Mainsail. USB passthrough is separate.'
pct start "$CTID"
work=$(mktemp -d /tmp/klipper-lxc.XXXXXXXX)
trap 'rm -rf "$work"' EXIT
cat > "$work/setup-klipper.sh" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /root/klipper-install.log) 2>&1
trap 'echo "Guest setup failed at line $LINENO. Log: /root/klipper-install.log" >&2; rm -f /etc/sudoers.d/klipper-bootstrap' ERR
export DEBIAN_FRONTEND=noninteractive
for attempt in {1..30}; do
  if getent hosts deb.debian.org >/dev/null; then break; fi
  if ((attempt == 30)); then echo 'DNS/network not ready. Check LXC networking.' >&2; exit 1; fi
  sleep 2
done
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git unzip nginx sudo python3 python3-venv python3-dev \
  build-essential libffi-dev libncurses-dev pkg-config libusb-1.0-0-dev \
  gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi \
  dbus polkitd pkexec iproute2
if ! id klipper >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash klipper
fi
usermod -aG dialout,tty klipper
systemctl enable --now dbus
# Installers require sudo. Remove the temporary broad grant immediately after use.
printf 'klipper ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/klipper-bootstrap
chmod 440 /etc/sudoers.d/klipper-bootstrap
visudo -cf /etc/sudoers.d/klipper-bootstrap
install -d -o klipper -g klipper /home/klipper/printer_data/{config,logs,gcodes,comms,systemd,database}
runuser -u klipper -- bash <<'USER'
set -Eeuo pipefail
cd /home/klipper
if [[ ! -d klipper/.git ]]; then git clone https://github.com/Klipper3d/klipper.git; fi
if [[ ! -d moonraker/.git ]]; then git clone https://github.com/Arksine/moonraker.git; fi
if [[ ! -d mainsail-config/.git ]]; then git clone https://github.com/mainsail-crew/mainsail-config.git; fi
python3 -m venv klippy-env
klippy-env/bin/pip install --upgrade pip
klippy-env/bin/pip install -r klipper/scripts/klippy-requirements.txt
# mainsail.cfg in the upstream repo is a symlink to client.cfg.
# Link the target directly so the config remains valid and upgradeable.
ln -sfn /home/klipper/mainsail-config/client.cfg printer_data/config/mainsail.cfg
USER
# Preserve printer.cfg when a failed guest install is resumed.
if [[ ! -e /home/klipper/printer_data/config/printer.cfg ]]; then
  if [[ -f /root/import-printer.cfg ]]; then
    install -o klipper -g klipper -m 644 /root/import-printer.cfg /home/klipper/printer_data/config/printer.cfg
  else
    cat > /home/klipper/printer_data/config/printer.cfg <<'CFG'
# Host setup only. Replace with your verified HyperCube printer.cfg.
# No motors or heaters are defined; this is NOT a printable configuration.
[include mainsail.cfg]
[mcu]
serial: /dev/serial/by-id/REPLACE_WITH_BOARD_ID
[printer]
kinematics: none
max_velocity: 100
max_accel: 1000
CFG
    chown klipper:klipper /home/klipper/printer_data/config/printer.cfg
  fi
fi
# Ensure imported configs can use Mainsail without manually adding includes.
if ! grep -Eq '^\[include[[:space:]]+mainsail\.cfg\]' /home/klipper/printer_data/config/printer.cfg; then
  sed -i '1i[include mainsail.cfg]' /home/klipper/printer_data/config/printer.cfg
fi
if [[ -f /root/hypercube300.base.cfg ]]; then
  install -o klipper -g klipper -m 644 /root/hypercube300.base.cfg /home/klipper/printer_data/config/hypercube300.base.cfg
fi
cat > /home/klipper/printer_data/systemd/klipper.env <<'ENV'
KLIPPER_ARGS="/home/klipper/klipper/klippy/klippy.py /home/klipper/printer_data/config/printer.cfg -l /home/klipper/printer_data/logs/klippy.log -a /home/klipper/printer_data/comms/klippy.sock"
ENV
chown klipper:klipper /home/klipper/printer_data/systemd/klipper.env
cat > /etc/systemd/system/klipper.service <<'UNIT'
[Unit]
Description=Klipper printer host
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=klipper
Group=klipper
EnvironmentFile=/home/klipper/printer_data/systemd/klipper.env
ExecStart=/home/klipper/klippy-env/bin/python $KLIPPER_ARGS
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
# Trust only the local guest subnet. Reverse proxy retains real client IP.
lan=$(ip -4 -o address show dev eth0 scope global | python3 -c 'import ipaddress,sys; s=sys.stdin.read().split(); print(ipaddress.ip_interface(s[3]).network if len(s)>3 else "")')
[[ -n "$lan" ]] || { echo 'Container has no IPv4 address.' >&2; exit 1; }
if [[ ! -e /home/klipper/printer_data/config/moonraker.conf ]]; then
cat > /home/klipper/printer_data/config/moonraker.conf <<MOON
[server]
host: 127.0.0.1
port: 7125
klippy_uds_address: /home/klipper/printer_data/comms/klippy.sock
max_upload_size: 1024

[authorization]
trusted_clients:
    127.0.0.1
    ::1
    $lan
cors_domains:
    *://my.mainsail.xyz

[file_manager]
enable_object_processing: True

[machine]
provider: systemd_dbus

[history]

[octoprint_compat]

[update_manager]
refresh_interval: 168
channel: stable

[update_manager mainsail]
type: web
channel: stable
repo: mainsail-crew/mainsail
path: /var/www/mainsail

[update_manager mainsail-config]
type: git_repo
primary_branch: master
path: /home/klipper/mainsail-config
origin: https://github.com/mainsail-crew/mainsail-config.git
managed_services: klipper
MOON
chown klipper:klipper /home/klipper/printer_data/config/moonraker.conf
fi
# Use Moonraker's current official installer for venv, service and polkit.
runuser -u klipper -- bash -c 'cd /home/klipper/moonraker && bash scripts/install-moonraker.sh -f -d /home/klipper/printer_data'
rm -f /etc/sudoers.d/klipper-bootstrap
# Download the current official Mainsail release, never a third-party image.
mkdir -p /var/www/mainsail
curl --fail --location --retry 3 https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip -o /root/mainsail.zip
unzip -tq /root/mainsail.zip
unzip -oq /root/mainsail.zip -d /var/www/mainsail
chown -R klipper:klipper /var/www/mainsail
[[ -s /var/www/mainsail/index.html ]]
cat > /var/www/mainsail/config.json <<'MAINS_CONFIG'
{"hostname":null,"port":null,"path":null,"instancesDB":"moonraker","instances":[]}
MAINS_CONFIG
chown klipper:klipper /var/www/mainsail/config.json
cat > /etc/nginx/sites-available/mainsail <<'NGINX'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/mainsail;
    index index.html;
    client_max_body_size 1024m;
    location / { try_files $uri $uri/ /index.html; }
    location ~ ^/(websocket|printer|api|access|machine|server)(/|$) {
        proxy_pass http://127.0.0.1:7125;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_request_buffering off;
    }
}
NGINX
rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/mainsail /etc/nginx/sites-enabled/mainsail
nginx -t
systemctl daemon-reload
systemctl enable --now klipper moonraker nginx
systemctl restart klipper moonraker nginx
# Verify host software, not physical printer readiness.
for attempt in {1..30}; do
  if curl -fsS http://127.0.0.1/server/info -o /root/moonraker-health.json; then break; fi
  if ((attempt == 30)); then journalctl -u moonraker -n 60 --no-pager; exit 1; fi
  sleep 2
done
python3 - <<'PY'
import json
j=json.load(open('/root/moonraker-health.json'))['result']
failed=j.get('failed_components',[])
assert not failed, f'Moonraker failed components: {failed}'
print('Moonraker API verified; expected pre-USB printer state:',j.get('klippy_state'))
for warning in j.get('warnings',[]): print('Moonraker warning:',warning)
PY
curl -fsS http://127.0.0.1/ -o /dev/null
systemctl is-active --quiet klipper moonraker nginx
{
  echo "Installed: $(date -Is)"
  for repo in klipper moonraker mainsail-config; do
    printf '%s: ' "$repo"
    runuser -u klipper -- git -C "/home/klipper/$repo" rev-parse HEAD
  done
} > /root/klipper-installed-versions.txt
touch /root/klipper-host-ready
GUEST
# Embed the companion base at packaging time below; never auto-activate it.
cat > "$work/hypercube300.base.cfg" <<'HYPERCUBE_BASE'
# HyperCube 300 V2 / BIGTREETECH SKR MINI E3 V3.0 / Klipper + Mainsail
# BASE TEMPLATE -- not a calibrated, ready-to-print configuration.
# Pin mapping: https://github.com/Klipper3d/klipper/blob/master/config/generic-bigtreetech-skr-mini-e3-v3.0.cfg
# Reference: https://www.klipper3d.org/Config_Reference.html
# Created 2026-10-09.
#
# REQUIRED: replace every REPLACE_ value before Klipper can start.
# Assumptions to check: 300x300x300 usable travel; 1.8-degree motors;
# GT2 belts and 20-tooth XY motor pulleys; X/Y/Z minimum mechanical switches;
# 0.4 mm nozzle; 1.75 mm filament; both Z motors on ZAM/ZBM (ONE driver).
# Motor directions below come from the official board example, not your
# CoreXY wiring. Validate directions and endstops before ANY homing.
#
# FIRMWARE BUILD (exact V3.0, not a different board revision):
# STM32G0B1, 8 KiB bootloader, USB communication.
# Copy out/klipper.bin to microSD as firmware.bin; power-cycle board.
# USB passthrough must expose the board to the Debian VM/LXC.
# Find its path INSIDE the guest: ls /dev/serial/by-id/
#
# INSTALL: rename this file printer.cfg in ~/printer_data/config/.
# KIAUH's Mainsail setup must supply mainsail.cfg in the same directory.
# That file supplies virtual_sdcard, pause_resume, display_status and
# PAUSE/RESUME/CANCEL_PRINT macros. Do not duplicate those sections here.

[include mainsail.cfg]

[mcu]
serial: /dev/serial/by-id/REPLACE_WITH_YOUR_BOARD_ID

[printer]
kinematics: corexy
max_velocity: 100
max_accel: 1000
max_z_velocity: 3
max_z_accel: 50

# XM and YM connect to the two CoreXY belt motors (A and B).
# They do not move independent physical X/Y axes like Cartesian motors.
[stepper_x]
step_pin: PB13
dir_pin: !PB12
enable_pin: !PB14
microsteps: 16
full_steps_per_rotation: 200
rotation_distance: 40
endstop_pin: ^PC0
position_endstop: 0
position_min: 0
position_max: 300
homing_positive_dir: false
homing_speed: 20
second_homing_speed: 5
homing_retract_dist: 5

[tmc2209 stepper_x]
uart_pin: PC11
tx_pin: PC10
uart_address: 0
# Provisional RMS amps, not a recommendation for every NEMA17.
run_current: 0.60
interpolate: false
stealthchop_threshold: 0

[stepper_y]
step_pin: PB10
dir_pin: !PB2
enable_pin: !PB11
microsteps: 16
full_steps_per_rotation: 200
rotation_distance: 40
endstop_pin: ^PC1
position_endstop: 0
position_min: 0
position_max: 300
homing_positive_dir: false
homing_speed: 20
second_homing_speed: 5
homing_retract_dist: 5

[tmc2209 stepper_y]
uart_pin: PC11
tx_pin: PC10
uart_address: 2
run_current: 0.60
interpolate: false
stealthchop_threshold: 0

# ZAM + ZBM share one driver. Both motors must lift/lower the bed together.
# No [stepper_z1] and no Z_TILT_ADJUST: these require independent drivers.
# rotation_distance = axial travel per full screw revolution (lead).
# 2 mm thread pitch does NOT necessarily mean 2 mm lead:
# 1 start -> 2 mm; 2 starts -> 4 mm; 4 starts -> 8 mm.
# Measure travel for one revolution; do not guess from "pitch 2".
[stepper_z]
step_pin: PB0
dir_pin: PC5
enable_pin: !PB1
microsteps: 16
full_steps_per_rotation: 200
rotation_distance: REPLACE_WITH_MEASURED_Z_LEAD_MM
# Mechanical Z-min baseline. If your switch is at Z-max, this homing
# direction and position_endstop MUST change to match the actual switch.
endstop_pin: ^PC2
position_endstop: 0
position_min: 0
position_max: 300
homing_positive_dir: false
homing_speed: 2
second_homing_speed: 1
homing_retract_dist: 3

[tmc2209 stepper_z]
uart_pin: PC11
tx_pin: PC10
uart_address: 1
# 0.80 A is provisional TOTAL driver RMS current, split between two
# parallel-connected matching Z motors; it is NOT 0.80 A per motor.
# Set from motor ratings, driver cooling and lift tests. Do not blindly
# double a single-motor current; manually level both screws initially.
run_current: 0.80
interpolate: false
stealthchop_threshold: 0

[extruder]
step_pin: PB3
dir_pin: !PB4
enable_pin: !PD1
microsteps: 16
full_steps_per_rotation: 200
# If no gear_ratio is used, this is filament mm per MOTOR revolution.
# Copy/convert a verified previous setting or calibrate your actual unit.
# With verified old steps/mm at 16 microsteps, 1.8-degree motor:
# rotation_distance = 3200 / old_steps_per_mm (when gear_ratio omitted).
rotation_distance: REPLACE_WITH_EXTRUDER_ROTATION_DISTANCE
nozzle_diameter: 0.400
filament_diameter: 1.750
heater_pin: PC8
# Select the ACTUAL hotend thermistor. "100K" alone isn't a curve.
# Common names include Generic 3950 and EPCOS 100K B57560G104F.
sensor_type: REPLACE_WITH_HOTEND_THERMISTOR_TYPE
sensor_pin: PA0
# Startup baseline only; PID_CALIBRATE then SAVE_CONFIG replaces this.
control: watermark
max_power: 0.70
min_temp: 0
max_temp: 250
min_extrude_temp: 170
max_extrude_only_distance: 100
pressure_advance: 0

[tmc2209 extruder]
uart_pin: PC11
tx_pin: PC10
uart_address: 3
run_current: 0.60
interpolate: false
stealthchop_threshold: 0

[heater_bed]
heater_pin: PC9
sensor_type: REPLACE_WITH_BED_THERMISTOR_TYPE
sensor_pin: PC4
control: watermark
max_power: 1.0
min_temp: 0
max_temp: 110
# Verify bed current fits the board's rated output/wiring. An external
# suitably rated MOSFET may be required for a high-power 300 mm bed.

# FAN0: part cooling (slicer's M106/M107).
[fan]
pin: PC6
kick_start_time: 0.5

# FAN1: hotend heatsink fan, automatic above 50 C and while heater active.
[heater_fan hotend_fan]
pin: PC7
heater: extruder
heater_temp: 50.0
fan_speed: 1.0
kick_start_time: 0.5

# FAN2: electronics 4010 fan; automatic with any motor or bed heater.
# The fan output voltage follows supply voltage: use a 24 V fan on 24 V.
[controller_fan board_fan]
pin: PB15
heater: heater_bed
stepper: stepper_x, stepper_y, stepper_z, extruder
fan_speed: 1.0
idle_timeout: 60
kick_start_time: 0.5

[idle_timeout]
timeout: 1800

[exclude_object]

# No input-shaper frequencies or pressure-advance value guessed here.
# Bowden retraction belongs in slicer initially; calibrate rather than
# copying a universal value for a 50 cm tube.

# OPTIONAL INDUCTIVE PROBE -- disabled until electrical interface verified.
# Never feed 12/24 V into a board signal pin. A powered NPN probe needs
# a verified compatible open-collector/interface circuit and correct
# grounding/pin identification. Signal conditioning may be necessary.
# Probe may also be used for bed mesh while retaining mechanical Z home.
#
# To home Z using the probe:
# 1. Enable the [probe] block with real offsets and verified signal logic.
# 2. In [stepper_z], replace endstop_pin with probe:z_virtual_endstop,
#    REMOVE position_endstop, and set position_min: -2 for calibration.
# 3. Enable [safe_z_home] below. Choose nozzle XY coordinates that place
#    the PROBE over bed centre, using 150-x_offset and 150-y_offset.
# 4. QUERY_PROBE must report open/triggered correctly before homing.
# 5. PROBE_CALIBRATE then SAVE_CONFIG; measure/restrict reachable mesh.
#
# Example pin ONLY for a verified interface connected to Z-STOP (PC2).
# If on the dedicated PROBE connector instead, verify the board pinout
# and change pin accordingly. Do not configure two inputs on one pin.
#
# [probe]
# pin: ^PC2
# x_offset: REPLACE_WITH_PROBE_X_OFFSET
# y_offset: REPLACE_WITH_PROBE_Y_OFFSET
# z_offset: 0
# speed: 2
# samples: 3
# sample_retract_dist: 3
# samples_result: median
# samples_tolerance: 0.05
# samples_tolerance_retries: 3
#
# [safe_z_home]
# home_xy_position: REPLACE_WITH_NOZZLE_X, REPLACE_WITH_NOZZLE_Y
# speed: 40
# z_hop: 10
# z_hop_speed: 3
#
# [bed_mesh]
# speed: 60
# horizontal_move_z: 5
# mesh_min: REPLACE_WITH_REACHABLE_PROBE_MIN_X, REPLACE_WITH_REACHABLE_PROBE_MIN_Y
# mesh_max: REPLACE_WITH_REACHABLE_PROBE_MAX_X, REPLACE_WITH_REACHABLE_PROBE_MAX_Y
# probe_count: 5, 5
# algorithm: bicubic

# FIRST CHECKS (after replacing placeholders):
# 1. Confirm temperature readings are credible at room temperature.
# 2. QUERY_ENDSTOPS; press switches by hand and verify status changes.
#    Invert using ! if required; check wiring rather than guessing.
# 3. STEPPER_BUZZ STEPPER=stepper_x, then y, then z; bed clear of nozzle.
#    Check CoreXY motor roles/directions; toggle dir_pin ! as needed.
# 4. Carefully home X, then Y, then Z with physical stop access.
# 5. Test heaters individually at low targets; confirm correct sensor
#    rises and cooling works. Never suppress verify_heater safeguards.
# 6. PID_CALIBRATE HEATER=extruder TARGET=210
#    PID_CALIBRATE HEATER=heater_bed TARGET=60
#    SAVE_CONFIG
# 7. Calibrate extruder rotation distance and first-layer Z; then probe
#    offsets/mesh (if used), pressure advance, and input shaping.
# This file has NOT been tested on your printer hardware.

HYPERCUBE_BASE
pct push "$CTID" "$work/setup-klipper.sh" /root/setup-klipper.sh --perms 0700
pct push "$CTID" "$work/hypercube300.base.cfg" /root/hypercube300.base.cfg --perms 0644
if [[ -n "$PRINTER_CFG" ]]; then
  pct push "$CTID" "$PRINTER_CFG" /root/import-printer.cfg --perms 0644
fi
if ! pct exec "$CTID" -- bash /root/setup-klipper.sh; then
  printf '\nGuest install incomplete. Fix the reported issue, then resume with:\npct exec %s -- bash /root/setup-klipper.sh\n' "$CTID" >&2
  exit 1
fi
ADDR=$(pct exec "$CTID" -- ip -4 -o addr show eth0 scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')
printf '\nHost software ready. CTID: %s\nMainsail: http://%s/\n' "$CTID" "$ADDR"
printf 'Printer config: /home/klipper/printer_data/config/printer.cfg\nInstall log: /root/klipper-install.log inside CT\n'
if [[ -n "$PRINTER_CFG" ]]; then
  echo 'Imported your config. Confirm its board serial path after USB passthrough.'
else
  echo 'No printer config imported. Replace the staging printer.cfg with your verified config in Mainsail.'
  echo 'hypercube300.base.cfg is a reference template with unresolved hardware values, not an active include.'
fi
echo 'Next: flash the board if needed, pass its USB serial device through, set [mcu] serial, and restart Klipper.'
printf 'Proxmox root-shell entry: pct enter %s\n' "$CTID"
