#!/bin/bash
BOND_IF="bond0"
TAP0="tap0"
TAP1="tap1"

VPN00="VPN00"
VPN01="VPN01"

LOG_tap0="/etc/bridgeman/logs/openvpn/aws1_zs1_vpn01.log"
LOG_tap1="/etc/bridgeman/logs/openvpn/aws1_zs1_vpn02.log"

CONFIG1="/etc/openvpn/aws1_zs1_vpn01.conf"
CONFIG2="/etc/openvpn/aws1_zs1_vpn02.conf"

TIME_SLEEP=5 #Sec
debug=true
#########################################################
#####DO NOT EDIT BELOW THIS LINE#########################
#########################################################
tap0_bonded="0"
tap1_bonded="0"
tap0_set_down="0"
tap1_set_down="0"
VPN00_STATUS=""
VPN01_STATUS=""

writeLog(){
  #If pass the second arg then write to log anyway -> for important message like failover
  if [ $debug = true ] || [ $2 != ""]; then
    DATE=`date +%Y-%m-%d_%H:%M:%S`
    echo "$DATE - $1"
  fi
}

checkprocess(){
  PROC="$1"
  PROCESS_NUM=$(ps -ef | grep openvpn | grep $PROC | awk '{print $2}')

  if [ "$PROCESS_NUM" != "0" ] && [ "$PROCESS_NUM" != "" ]; then
    writeLog "Process found $PROCESS_NUM"
    PID=$PROCESS_NUM
    PROC_STATUS="RUNNING" #OK
  else
    writeLog "Process NOT found"
    PID=0
    PROC_STATUS="STOP" #Proc non running
  fi
}

start(){
  VPN="$1"
  CONFIG=""

  if [ "$VPN" = $VPN00 ]; then
    CONFIG=$CONFIG1

  elif [ "$VPN" = $VPN01 ]; then
    CONFIG=$CONFIG2
  fi

  #Start VPN
  /usr/sbin/openvpn --config $CONFIG --daemon $VPN
  writeLog "$VPN Started" 1
}

stop(){
  VPN="$1"
  checkprocess $VPN
  if [ "$PID" != "" ] && [ "$PID" != "0" ]; then
    kill $PID
  fi
}

restartvpn(){
  stop $1
  start $1
}

addIfToBond(){
  VPN="$1"
  VPN_STATUS=""

  if [ "$VPN" = $VPN00 ]; then
    TAP_DEV=$TAP0
    VPN_STATUS=$VPN00_STATUS
    tap0_set_down="0"

  elif [ "$VPN" = $VPN01 ]; then
    TAP_DEV=$TAP1
    VPN_STATUS=$VPN01_STATUS   
    tap1_set_down="0"
  fi

  
  ip_link_check=$(ip link show | grep $TAP_DEV | awk '{print $9}')
  if [ "$VPN_STATUS" = "CONNECTED" ] && [ "$ip_link_check" = "DOWN" ]; then
    writeLog "Adding $TAP_DEV to $BOND_IF for $VPN" 1
    /sbin/ifenslave $BOND_IF $TAP_DEV
  fi  
}

removeIfFromBond(){
  TAP_DEV=""
  tap_set_down=""

  if [ "$VPN" = $VPN00 ]; then
    TAP_DEV=$TAP0
    tap_set_down=$tap0_set_down

  elif [ "$VPN" = $VPN01 ]; then
    TAP_DEV=$TAP1
    tap_set_down=$tap1_set_down
  fi

  #Do not set DOWN again If was already set
  if [ "$tap_set_down" = "0" ]; then
    writeLog "Turn $TAP_DEV DOWN" 1
    /sbin/ifconfig $TAP_DEV down
  fi

  if [ "$VPN" = $VPN00 ]; then
    tap0_set_down="1"

  elif [ "$VPN" = $VPN01 ]; then
    tap1_set_down="1"
  fi   
}

checkvpn(){
  TAP_DEV=""
  VPN="$1"

  #Assign temp variables
  if [ "$VPN" = $VPN00 ]; then
    TAP_DEV=$TAP0
    LOG=$LOG_tap0

  elif [ "$VPN" = $VPN01 ]; then
    TAP_DEV=$TAP1
    LOG=$LOG_tap1
  fi

  #Check VPN log status
  lastline=$(tail -1 $LOG)
  if echo $lastline | grep -qF -e "Exiting due to fatal error"; then
    #The process is terminated due to an error, kill and restart
    writeLog "The OPENVPN process $PID is terminated due to an error, kill and restart - $VPN" 1
    kill -9 $PID
    PID=""
    exit 1
  fi


  if echo $lastline | grep -qF -e "Initialization Sequence Completed"; then
    VPN_STATUS="CONNECTED"
  else
    VPN_STATUS="DISCONNECTED"
  fi
  writeLog "VPN $VPN status $VPN_STATUS"

  if [ "$VPN" = $VPN00 ]; then
    VPN00_STATUS=$VPN_STATUS
  elif [ "$VPN" = $VPN01 ]; then
    VPN01_STATUS=$VPN_STATUS
  fi  
}

execmain() {
  VPNIF="$1"

  #reset variables
  PID=0
  VPN_STATUS=""
  PROC_STATUS=""  
  PROCESS_NUM="0"

  writeLog "Starting checking for VPN $VPNIF"

  checkprocess $VPNIF

  if [ "$PID" = "0" ]; then
    #restart process VPNIF
    restartvpn $VPNIF
    sleep 10
  else
    #Process exists, going to check if is connected
    checkvpn $VPNIF

    if [ "$VPN" = $VPN00 ]; then
      VPN_STATUS=$VPN00_STATUS
    elif [ "$VPN" = $VPN01 ]; then
      VPN_STATUS=$VPN01_STATUS
    fi  

    if [ "$VPN_STATUS" != "CONNECTED" ]; then
      #Problems with VPN, failover 
      removeIfFromBond $VPNIF
    else
      addIfToBond $VPNIF
    fi
    
  fi
}

#Infinite loop with sleep interval
while true
do
  #Main
  execmain $VPN00

  execmain $VPN01

  sleep $TIME_SLEEP
done
