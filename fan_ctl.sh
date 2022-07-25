#!/usr/sbin/env zsh

logging=$1

# set LC_NUMERIC to C because in german decimal places are specified with ,
export LC_NUMERIC="C"

# variable definition
IPMI="/usr/bin/ipmitool"
Kp=0.7
Ki=0.525
Kd=0.525
SP=30.00
last_dT=(0.0 0.0)
pwm_min=20 # 0x14
pwm_max=100 # 0x64
sleep_timer=1
reset_timer=120 # bmc need some time to come up agian
log_timer=30

function log() {
  args=($@)
  format="%10s |%8s |"
  case ${args[1]} in
    "head")
      printf $format "Date" "Time"
      for i in {2..${#args[@]}}; do
        printf "%8s |" ${args[$i]}
      done
      ;;
    *)
      printf $format $(date +%x) $(date +%T)
      for i in ${args[@]}; do
        printf "%8s |" $i
      done
      ;;
  esac
  printf "\n"
}

if [[ $logging ]]; then
  declare -a ids=( \
    0x01 \
    0x02 \
    0x0a \
    0x0b \
    0x0c \
    0xb0 \
    0xb4 \
    0xb8 \
    0xbc \
    0xd0 \
    0xd4 \
    0xd8 \
    0xdc \
  )

  declare -a header=( \
    CPU-1 \
    CPU-2 \
    PCH \
    SYSTEM \
    PER \
    DIMMA1 \
    DIMMB1 \
    DIMMC1 \
    DIMMD1 \
    DIMME1 \
    DIMMF1 \
    DIMMG1 \
    DIMMH1 \
  )

  # only for logging at the moment
  declare -a label=( \
    "NVME-0" \
    "NVME-1" \
    "ST5-0" \
    "ST5-1" \
    "MX3-0" \
    "MX3-1" \
    "DOM" \
  )
fi

# only for logging at the moment
function storTemp() {
  ST5=0
  MX3=0
  DOM=0
  NVME=0

  for f in /sys/class/hwmon/*; do
    drive=$(/usr/bin/grep -q drivetemp $f/name 2>/dev/null && cat $f/device/model)
    nvme=$(/usr/bin/grep -q nvme $f/name 2>/dev/null && cat $f/device/model)
    # check empty
    if [[ ! -z "$drive" ]]; then
      if [[ "$drive" =~ "ST500" ]]; then
        t+=($(printf "%.2f" $(($(cat $f/temp1_input) / 1000))))
        ((ST5++))
      elif [[ "$drive" =~ "CT525MX3" ]]; then
        t+=($(printf "%.2f" $(($(cat $f/temp1_input) / 1000))))
        ((MX3++))
      elif [[ "$drive" =~ "SuperMicro" ]]; then
        t+=($(printf "%.2f" $(($(cat $f/temp1_input) / 1000))))
        ((DOM++))
      fi
    elif [[ ! -z "$nvme" ]]; then
      t+=($(printf "%.2f" $(($(cat $f/temp1_input) / 1000))))
      ((NVME++))
    fi
    continue
  done
}

function update_last_dT() {
  last_dT[2]=${last_dT[1]}
  last_dT[1]=$1
}
# convert to hexadecimal
function toHex() {
  printf "0x%x" "$1"
}
# convert to decimal
function toDec() {
  printf "%d" "0x$1"
}

# raw command is much faster -> sdr query takes at least 1 second
# $($IPMI sdr | grep "CPU1" | grep -Eo '[0-9]{2,}' | xargs echo -n)
function getTemps() {
  temp=$($IPMI raw 0x04 0x2d $1 | awk {'printf $1'} | xargs)
  printf "%.2f" "$(toDec $temp)"
}
function setFanDuty() {
  # raw 0x30 0x70 0x66 0x01 ZONE DUTY
  echo -n $($IPMI raw 0x30 0x70 0x66 0x01 $(toHex $1) $(toHex $2))
}

function getFanDuty() {
  # raw 0x30 0x70 0x66 0x00 ZONE
  duty=$($IPMI raw 0x30 0x70 0x66 0x00 $(toHex $1) | xargs)
  toDec $duty
}

MODE=$($IPMI raw 0x30 0x45 0x00 | xargs)

if [[ $MODE -ne 01 ]]; then
  $IPMI raw 0x30 0x45 0x01 0x01
  # 0 = Standard 1 = Full 2 = Optimal 4 = HeavyIO
  $IPMI mc rest warm # most of the time not necessary

  sleep $reset_timer
fi

start_timer=$(date +%s)

if [[ $logging ]]; then
  log head "DUTY" ${header[@]} ${label[@]}
fi

while true
do
  pid=0

  if [[ $logging ]]; then
    declare -a t

    for i in {1..${#header[@]}};do
          t[$i]=$(getTemps ${ids[$i]})
    done

    Tsum=$(printf "%.2f" $(((${t[1]} + ${t[2]}) / 2)))
  else
    Tsum=$(printf "%.2f" $((($(getTemps 0x01) + $(getTemps 0x02)) / 2)))
  fi

  cZone=$(getFanDuty 0)
  pZone=$(getFanDuty 1)

  if [[ $Tsum -le $SP && $cZone -eq $pwm_min && ! $(( $(date +%s) - $start_timer )) -ge $log_timer ]]; then
    sleep $sleep_timer
    continue
  fi

  dT=$(( Tsum - SP ))
  P=$(( Kp * dT ))
  I=$(( Ki * (dT + last_dT[1] + last_dT[2]) ))
  D=$(( Kd * (last_dT[1] - last_dT[2]) ))
  pid=$(printf "%.0f" $(( P + I + D + pwm_min)))

  if [[ $pid -lt $pwm_min ]]; then pid=$pwm_min; fi
  if [[ $pid -gt $pwm_max ]]; then pid=$pwm_max; fi

  # greater equal because processing ipmi raw cmd took up to 3 sec
  if [[ $(( $(date +%s) - $start_timer )) -ge $log_timer ]]; then
    if [[ $logging ]]; then
      storTemp
      log $pid $t[@]
    fi
    start_timer=$(date +%s)
  fi

  update_last_dT $dT

  setFanDuty 0 $pid
  setFanDuty 1 $pid

  unset t
  sleep $sleep_timer

done

# NOTES:
# -------------------------------
#
# Get Mode: $IPMI raw 0x30 0x45 0x00
# Set Mode: $IPMI raw 0x30 0x45 0x01
#
# ZONE: 0x00 und 0x01
# Get Fan Speed in %: $IPMI raw 0x30 0x70 0x66 0x00 ZONE SPEED
# Set Fan Speed in %: $IPMI raw 0x30 0x70 0x66 0x01 ZONE SPEED
#
# Get temperature with raw command
# (https://www.thomas-krenn.com/de/wiki/IPMI_Analyse_mit_openipmish#mc_sdrs)
#
# $IPMI sdr elist
#
# CPU1 Temp        | 01
# CPU2 Temp        | 02
# PCH Temp         | 0A
# System Temp      | 0B
# Peripheral Temp  | 0C
# Vcpu1VRM Temp    | 10
# Vcpu2VRM Temp    | 11
# VmemABVRM Temp   | 12
# VmemCDVRM Temp   | 13
# VmemEFVRM Temp   | 14
# VmemGHVRM Temp   | 15
# P1-DIMMA1 Temp   | B0
# P1-DIMMA2 Temp   | B1
# P1-DIMMB1 Temp   | B4
# P1-DIMMB2 Temp   | B5
# P1-DIMMC1 Temp   | B8
# P1-DIMMC2 Temp   | B9
# P1-DIMMD1 Temp   | BC
# P1-DIMMD2 Temp   | BD
# P2-DIMME1 Temp   | D0
# P2-DIMME2 Temp   | D1
# P2-DIMMF1 Temp   | D4
# P2-DIMMF2 Temp   | D5
# P2-DIMMG1 Temp   | D8
# P2-DIMMG2 Temp   | D9
# P2-DIMMH1 Temp   | DC
# P2-DIMMH2 Temp   | DD
#
# $IPMI raw 0x04 0x2d <ID>
# e.g.
# $IPMI raw 0x04 0x2d 0x01
# 1e c0 c0 => 0x1e is the cpu temp
#
#
# NVME temp sysfs
# cat  /sys/class/nvme/nvme0/device/nvme/nvme0/hwmon0/temp2_input
# c=$(ls -l /sys/class/nvme/* | grep -c ^l) oder c=$(ls -l /sys/class/nvme/* | rg -c ^l)
# for i in {0..$(($c-1))};do echo $i; done
