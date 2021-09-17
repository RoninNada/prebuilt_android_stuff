#!/system/bin/sh
DEBUG="0"
VERBOSE="0"
ELITE="0"
USERID=""
IFACE=""
checkvm_status=""
MAC80211=0
IW_SOURCE="https://www.kernel.org/pub/software/network/iw/iw-4.3.tar.gz"
IW_ERROR=""
if [ ! -d /sys/ ]; then
	printf "CONFIG_SYSFS is disabled in your kernel, this program will almost certainly not work.\n"
fi

if [ "${1}" = "--elite" ]; then
	shift
	ELITE="1"
fi

if [ "${1}" = "--verbose" ]; then
	shift
	VERBOSE="1"
fi

if [ "${1}" = "--debug" ]; then
	shift
	DEBUG="1"
	VERBOSE="1"
fi

#yes, I know this is in here twice
if [ "${1}" = "--elite" ]; then
	shift
	ELITE="1"
fi


if [ -n "${3}" ];then
	if [ "${3}" -gt 0 ] > /dev/null 2>&1; then
		CH="${3}"
	else
		printf "\nYou have entered an invalid channel \"${3}\" which will be ignored\n"
		CH=3
	fi
else
	CH=10
fi

#TODO LIST

#cleanup getDriver()
#fix to not assume wifi drivers are modules
#rewrite to not have two devices at any one time

if [ -n "$(command -v id 2> /dev/null)" ]; then
	USERID="$(id -u 2> /dev/null)"
fi

if [ -z "${USERID}" ] && [ -n "$(id -ru)" ]; then
	USERID="$(id -ru)"
fi

if [ -n "${USERID}" ] && [ "${USERID}" != "0" ]; then
	printf "Run it as root\n" ; exit 1;
elif [ -z "${USERID}" ]; then
	printf "Unable to determine user id, permission errors may occur.\n"
fi

#check for all needed binaries
if [ ! -x "$(command -v uname 2>&1)" ]; then
	printf "How in the world do you not have uname installed?\n"
	printf "Please select a linux distro which has at least basic functionality (or install uname).\n"
	exit 1
else
        OS=$(uname -s)
	#Recognized values are Linux and Darwin
fi

if [ ! -x "$(command -v ip 2>&1)" ] && [ ! -x "$(command -v ifconfig 2>&1)" ]; then
	printf "You have neither ip (iproute2) nor ifconfig installed.\n"
	printf "Please install one of them from your distro's package manager.\n"
	exit 1
fi

if [ ! -x "$(command -v iw 2>&1)" ]; then
	printf "You don't have iw installed, please install it from your distro's package manager.\n"
	printf "If your distro doesn't have a recent version you can download it from this link:\n"
	printf "${IW_SOURCE}\n"
	exit 1
fi

if [ ! -x "$(command -v ethtool 2>&1)" ]; then
	printf "Please install the ethtool package for your distro.\n"
	exit 1
fi

if [ -d /sys/bus/usb ]; then
	if [ ! -x "$(command -v lsusb 2>&1)" ]; then
		printf "Please install lsusb from your distro's package manager.\n"
		exit 1
	else
		LSUSB=1
	fi
else
	LSUSB=0
fi

if [ -d /sys/bus/pci ] || [ -d /sys/bus/pci_express ] || [ -d /proc/bus/pci ]; then
	if [ ! -x "$(command -v lspci 2>&1)" ]; then
		printf "Please install lspci from your distro's package manager.\n"
		exit 1
	else
		LSPCI=1
	fi
else
	LSPCI=0
fi

if [ -f /proc/modules ] || [ -d /sys/module ]; then
	if [ ! -x "$(command -v modprobe 2>&1)" ]; then
		printf "Your kernel has module support but you don't have modprobe installed.\n"
		printf "It is highly recommended to install modprobe (typically from kmod).\n"
		MODPROBE=0
	else
		MODPROBE=1
	fi
	if [ ! -x "$(command -v modinfo 2>&1)" ]; then
		printf "Your kernel has module support but you don't have modinfo installed.\n"
		printf "It is highly recommended to install modinfo (typically from kmod).\n"
		printf "Warning: driver detection without modinfo may yield inaccurate results.\n"
		MODINFO=0
	else
		MODINFO=1
	fi
else
	MODINFO=0
fi

if [ -c /dev/rfkill ]; then
	if [ ! -x "$(command -v rfkill 2>&1)" ];then
		printf "Your kernel supports rfkill but you don't have rfkill installed.\n"
		printf "To ensure devices are unblocked you must install rfkill.\n"
		RFKILL=0
	else
		RFKILL=1
	fi
else
	RFKILL=0
fi

if [ ! -x "$(command -v awk 2>&1)" ]; then
	printf "How in the world do you not have awk installed?\n"
	printf "Please select a linux distro which has at least basic functionality (or install awk).\n"
	exit 1
fi

if [ ! -x "$(command -v grep 2>&1)" ]; then
	printf "How in the world do you not have grep installed?\n"
	printf "Please select a linux distro which has at least basic functionality (or install grep).\n"
	exit 1
fi
#done checking for binaries

usage() {
	printf "usage: $(basename $0) <start|stop|check> <interface> [channel or frequency]\n\n"
	exit 0
}

handleLostPhys() {
	MISSING_INTERFACE=""
	for i in $(ls /sys/class/ieee80211/); do
		if [ ! -d /sys/class/ieee80211/${i}/device/net ]; then
			MISSING_INTERFACE="${i}"
			printf "\nFound ${MISSING_INTERFACE} with no interfaces assigned, would you like to assign one to it? [y/n] "
			yesorno
			retcode=$?
               		if [ "${retcode}" = "1" ]; then
				printf "PHY ${MISSING_INTERFACE} will remain lost.\n"
			elif [ "${retcode}" = "0" ]; then
				PHYDEV=${MISSING_INTERFACE}
				findFreeInterface monitor
               		fi
		fi
	done
				#add some spacing so this doesn't make the display hard to read
				printf "\n"
}

findFreeInterface() {
	if [ -z "${1}" ]; then
		printf "findFreeInterface needs a target mode.\n"
		exit 1
	fi
	if [ "${1}" != "monitor" ] && [ "${1}" != "station" ]; then
		printf "findFreeInterface only supports monitor and station for target mode.\n"
		exit 1
	fi
	target_mode="${1}"
	if [ "$target_mode" = "monitor" ]; then
		target_suffix="mon"
		target_type="803"
	else
		target_suffix=""
		target_type="1"
	fi
	for i in $(seq 0 100); do
		if [ "$i" = "100" ]; then
			printf "\n\tUnable to find a free name between wlan0 and wlan99, you are on your own from here.\n"
			return 1
		fi
		if [ "$DEBUG" = "1" ]; then
			printf "\nChecking candidate wlan${i}\n"
		fi
		if [ ! -e /sys/class/net/wlan${i} ]; then
			if [ "$DEBUG" = "1" ]; then
				printf "\nCandidate wlan${i} is not in use\n"
			fi
			if [ ! -e /sys/class/net/wlan${i}mon ]; then
				if [ "$DEBUG" = "1" ]; then
					printf "\nCandidate wlan${i} and wlan${i}mon are both clear, creating wlan${i}${target_suffix}\n"
				fi
				IW_ERROR="$(iw phy ${PHYDEV} interface add wlan${i}${target_suffix} type ${target_mode} 2>&1)"
				if [ -z "${IW_ERROR}" ]; then
					if [ -d /sys/class/ieee80211/${PHYDEV}/device/net ]; then
						for j in $(ls /sys/class/ieee80211/${PHYDEV}/device/net/); do
							if [ "$(cat /sys/class/ieee80211/${PHYDEV}/device/net/${j}/type)" = "${target_type}" ]; then
								#here is where we catch udev renaming our interface
								k=${j#wlan}
								i=${k%mon}
							fi
						done
					else
						printf "Unable to create wlan${i}${target_suffix} and no error recieved.\n"
						return 1
					fi
					printf "\n\t\t(mac80211 ${target_mode} mode vif enabled on [${PHYDEV}]wlan${i}${target_suffix}\n"
					unset IW_ERROR
					break
				else
					printf "\n\n ERROR adding ${target_mode} mode interface: ${IW_ERROR}\n"
					break
				fi
			else
				if [ "$DEBUG" = "1" ]; then
					printf "\nCandidate wlan${i} does not exist, but wlan${i}mon does, skipping...\n"
				fi
			fi
		else
			if [ "$DEBUG" = "1" ]; then
				printf "\nCandidate wlan${i} is in use already.\n"
			fi
		fi
	done
}

rfkill_check() {
	#take phy and check blocks
	if [ "${RFKILL}" = 0 ]; then
		#immediatly return if rfkill isn't supported
		return 0
	fi
	if [ -z "${1}" ]; then
		printf "Fatal, rfkill_check requires a phy to be passed in\n"
		exit 1
	fi
	#first we have to find the rfkill index
	#this is available as /sys/class/net/wlan0/phy80211/rfkill## but that's a bit difficult to parse
	index="$(rfkill list | grep ${1} | awk -F: '{print $1}')"
	if [ -z "$index" ]; then
		return 187
	fi
	rfkill_status="$(rfkill list ${index} 2>&1)"
	if [ $? != 0 ]; then
		printf "rfkill error: ${rfkill_status}\n"
		return 187
	elif [ -z "${rfkill_status}" ]; then
		printf "rfkill had no output, something went wrong.\n"
		exit 1
	else
		soft=$(printf "${rfkill_status}" | grep -i soft | awk '{print $3}')
		hard=$(printf "${rfkill_status}" | grep -i hard | awk '{print $3}')
		if [ "${soft}" = "yes" ] && [ "${hard}" = "no" ]; then
			return 1
		elif [ "${soft}" = "no" ] && [ "${hard}" = "yes" ]; then
			return 2
		elif [ "${soft}" = "yes" ] && [ "${hard}" = "yes" ]; then
			return 3
		fi
	fi
	return 0
}

rfkill_unblock() {
	#attempt unblock and CHECK SUCCESS
	if [ "${RFKILL}" = 0 ]; then
		#immediatly return if rfkill isn't supported
		return 0
	fi
	rfkill_status="$(rfkill unblock ${1#phy} 2>&1)"
	if [ $? != 0 ]; then
		printf "rfkill error: ${rfkill_status}\n"
		printf "Unable to unblock.\n"
		return 1
	else
		sleep 1
		return 0
	fi
}

setLink() {
	if [ -x "$(command -v ip 2>&1)" ]; then
		ip link set dev ${1} ${2} > /dev/null 2>&1 || printf "\nFailed to set ${1} ${2} using ip\n"
	elif [ -x "$(command -v ifconfig 2>&1)" ]; then
		ifconfig ${1} ${2} > /dev/null 2>&1 || printf "\nFailed to set ${1} ${2} using ifconfig\n"
	fi
	return
}

ifaceIsUp() {
	if [ -x "$(command -v ip 2>&1)" ]; then
		ifaceIsUpCmd="ip link show dev"
	elif [ -x "$(command -v ifconfig 2>&1)" ]; then
		ifaceIsUpCmd="ifconfig"
	fi
	if ${ifaceIsUpCmd} ${1} 2>&1 | grep -q UP
	then
		return
	else
		return 1
	fi
}

#listIfaceUnspec() {
#	if [ -x "$(command -v ip 2>&1)" ]; then
#		ip link 2>/dev/null | awk -F"[: ]+" '/UNSPEC/ {print $2}'
#	elif [ -x "$(command -v ifconfig 2>&1)" ]; then
#		ifconfig -a 2>/dev/null | awk -F"[: ]+" '/UNSPEC/ {print $1}'
#	fi
#}

#startDeprecatedIface() {
#	iwconfig ${1} mode monitor > /dev/null 2>&1
#	if [ -n "${2}" ]; then
#		if [ ${2} -lt 1000 ]; then
#			iwconfig ${1} channel ${2} > /dev/null 2>&1
#		else
#			iwconfig ${1} freq ${2}000000 > /dev/null 2>&1
#		fi
#	else
#		iwconfig ${1} channel ${CH} > /dev/null 2>&1
#	fi
#	iwconfig ${1} key off > /dev/null 2>&1
#	setLink ${1} up
#	printf " (monitor mode enabled)"
#}

yesorno() {
	read input
	case $input in
		y) return 0 ;;
		yes) return 0 ;;
		n) return 1 ;;
		no) return 1 ;;
		*) printf "\nInvalid input. Yes, or no? [y/n] "
		   yesorno;;
	esac
}

startMac80211Iface() {
	#check if rfkill is set and cry if it is
	rfkill_check ${PHYDEV}
	rfkill_retcode="$?"
	case ${rfkill_retcode} in
		1) printf "\t${1} is soft blocked, please run \"rfkill unblock ${1#phy}\" to use this interface.\n" ;;
		2) printf "\t${1} is hard blocked, please flip the hardware wifi switch to on.\n"
		   printf "\tIt may also be possible to unblock with \"rfkill unblock ${1#phy}\"\n"
		   if [ "${checkvm_status}" != "run" ]; then
		   	checkvm
		   fi
		   if [ -n "${vm}" ]; then
		   	printf "Detected VM using ${vm_from}\n"
		   	printf "This appears to be a ${vm} Virtual Machine\n"
		   	printf "Some distributions have bugs causing rfkill hard block to be forced on in a VM.\n"
		   	printf "If toggling the rfkill hardware switch and \"rfkill unblock ${1#phy}\" both fail\n"
		   	printf "to fix this, please try not running in a VM.\n"
		   fi
		   ;;
		3) printf "\t${1} is hard and soft blocked, please flip the hardware wifi switch to on.\n"
		   printf "\tIt may also be needed to unblock with \"rfkill unblock ${1#phy}\"\n" ;;
	esac
	if [ "${rfkill_retcode}" != 0 ]; then
		printf "rfkill error, unable to start ${1}\n\n"
		printf "Would you like to try and automatically resolve this? [y/n] "
		yesorno
		retcode="$?"
		if [ "${retcode}" = "1" ]; then
			return 1
		elif [ "${retcode}" = "0" ]; then
			rfkill_unblock ${PHYDEV}
		fi
	fi
	#check if $1 already has a mon interface on the same phy and bail if it does
	if [ -d /sys/class/ieee80211/${PHYDEV}/device/net ]; then
		for i in $(ls /sys/class/ieee80211/${PHYDEV}/device/net/); do
			if [ "$(cat /sys/class/ieee80211/${PHYDEV}/device/net/${i}/type)" = "803" ]; then
				setChannelMac80211 ${i}
				printf "\n\t\t(mac80211 monitor mode already enabled for [${PHYDEV}]${1} on [${PHYDEV}]${i})\n"
				exit
			fi
		done
	fi
	#we didn't bail means we need a monitor interface
        if [ ${#1} -gt 12 ]; then
		printf "Interface ${#1}mon is too long for linux so it will be renamed to the old style (wlan#) name.\n"
		findFreeInterface monitor
	else
		if [ -e /sys/class/net/${1}mon ]; then
			printf "\nYou already have a ${1}mon device but it is NOT in monitor mode."
			printf "\nWhatever you did, don't do it again."
			printf "\nPlease run \"iw ${1}mon del\" before attempting to continue\n"
			exit 1
		fi
		#we didn't bail means our target interface is available
		setLink ${1} down
		IW_ERROR="$(iw phy ${PHYDEV} interface add ${1}mon type monitor 2>&1)"
		if [ -z "${IW_ERROR}" ]; then
			sleep 1
			if [ "$(cat /sys/class/ieee80211/${PHYDEV}/device/net/${1}mon/type)" = "803" ]; then
				setChannelMac80211 ${1}mon
			else
				printf "\nNewly created monitor mode interface ${1}mon is *NOT* in monitor mode.\n"
				printf "Removing non-monitor ${1}mon interface...\n"
				stopMac80211Iface ${1}mon abort
				exit 1
			fi
			printf "\n\t\t(mac80211 monitor mode vif enabled for [${PHYDEV}]${1} on [${PHYDEV}]${1}mon)\n"
		else
			printf "\n\nERROR adding monitor mode interface: ${IW_ERROR}\n"
			exit 1
		fi
	fi
	if [ "${ELITE}" = "1" ]; then
		#check if $1 is still down, warn if not
		if ifaceIsUp ${1}
		then
			printf "\nInterface ${1} is up, but it should be down. Something is interferring."
			printf "\nPlease run \"airmon-ng check kill\" and/or kill your network manager."
		fi
	else
		iw ${1} del
		printf "\t\t(mac80211 station mode vif disabled for [${PHYDEV}]${1})\n"
	fi
}

startwlIface() {
	if [ -f "/proc/brcm_monitor0" ]; then
		if [ -r "/proc/brcm_monitor0" ]; then
			local brcm_monitor="$(cat /proc/brcm_monitor0)"
			if [ "$brcm_monitor" = "1" ]; then
				printf "\n\t\t(experimental wl monitor mode vif already enabled for [${PHYDEV}]${1} on [${PHYDEV}]prism0)\n"
				return 0
			fi
		fi
		if [ -w "/proc/brcm_monitor0" ]; then
			printf "1" > /proc/brcm_monitor0
			if [ "$?" = "0" ]; then
				printf "\n\t\t(experimental wl monitor mode vif enabled for [${PHYDEV}]${1} on [${PHYDEV}]prism0)\n"
			else
				printf "\n\t\t(failed to enable experimental wl monitor mode for [${PHYDEV}${1})\n"
			fi
		else
			printf "\n\tUnable to write to /proc/brcm_monitor0, cannot enable monitor mode.\n"
		fi
	else
		printf "\n\tThis version of wl does not appear to suport monitor mode.\n"
	fi
}

#startDarwinIface() {
#	if [ -x /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport ]; then
#		if [ -n "${CH}" ] && [ ${CH} -lt 220 ]; then
#			/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport $1 sniff ${CH}
#		else
#			printf "Channel is set to none channel value of ${CH}
#		fi
#	fi
#}

setChannelMac80211() {
	setLink ${1} up
	if [ -n "${CH}" ]; then
		if [ ${CH} -lt 1000 ]; then
			#mac80211 specific check to see if hardware supports the channel number being assigned (requires grep with pcre)
			if [ -r "/sys/class/net/$1/phy80211/name" ]; then
		                channel_list="$(iw phy $(cat /sys/class/net/$1/phy80211/name) info 2>&1 | grep -oP '\[\K[^\]]+')"
				local hardware_valid_channel=1
	        	        for i in $channel_list; do
	                	        if [ "${CH}" = "${i}" ]; then
	                        	        hardware_valid_channel=0
		                                break
		                        fi
		                done
				if [ "${hardware_valid_channel}" = "1" ]; then
	        	                printf "Channel ${CH} does not appear to be supported by ${1} hardware, defaulting to channel 3.\n\n"
					CH=3
				fi
			fi
			IW_ERROR="$(iw dev ${1} set channel ${CH} 2>&1)"
		else
			#mac80211 specific check to see if hardware supports the frequency number being assigned (requires grep with pcre)
			if [ -r "/sys/class/net/$1/phy80211/name" ]; then
				frequency_list="$(iw phy $(cat /sys/class/net/$1/phy80211/name) info 2>&1 | grep -oP '\*\ \K[\d]+\ ')"
				local hardware_valid_freq=1
				for i in $frequency_list; do
					if [ "${CH}" = "${i}" ]; then
						hardware_valid_freq=0
						break
					fi
					print
				done
				if [ "${hardware_valid_freq}" = "1" ]; then
					printf "Frequency ${CH} does not appear to be supported by ${1} hardware, defaulting to 2422 Mhz.\n\n"
					CH="2422"
				fi
			fi
			IW_ERROR="$(iw dev ${1} set freq "${CH}" 2>&1)"
		fi
	else
		printf "CH is unset, this should not be possible.\n"
		exit 1
	fi
	if [ -n "${IW_ERROR}" ]; then
		printf "\nError setting channel: ${IW_ERROR}\n"
		if printf "${IW_ERROR}" | grep -q "(-16)"; then
			printf "Error -16 likely means your card was set back to station mode by something.\n"
			printf "Removing non-monitor ${1} interface...\n"
			stopMac80211Iface "${1}" abort
			exit 1
		fi
		if printf "${IW_ERROR}" | grep -q "(-22)"; then
			printf "Unable to set channel/frequency ${CH}, most likely it is outside of regulatory domain\n\n"
		fi
	fi
}

#stopDeprecatedIface() {
#	setLink $1 down
#	iwconfig $1 mode Managed > /dev/null 2>&1
#	setLink $1 up
#	printf " (monitor mode disabled)"
#}

stopMac80211Iface() {
	if [ -f /sys/class/net/${1}/type ]; then
		if [ "${2}" != "abort" ] && [ "$(cat /sys/class/net/${1}/type)" != "803" ]; then
			printf "\n\nYou are trying to stop a device that isn't in monitor mode.\n"
			printf "Doing so is a terrible idea, if you really want to do it then you\n"
			printf "need to type 'iw ${1} del' yourself since it is a terrible idea.\n"
			printf "Most likely you want to remove an interface called wlan[0-9]mon\n"
			printf "If you feel you have reached this warning in error,\n"
			printf "please report it.\n"
			exit 1
		else
			if [ "${ELITE}" = "0" ]; then
				local need_sta=1
				if [ -d /sys/class/ieee80211/${PHYDEV}/device/net ]; then
					for i in $(ls /sys/class/ieee80211/${PHYDEV}/device/net/); do
						if [ "$(cat /sys/class/ieee80211/${PHYDEV}/device/net/${i}/type)" = "1" ]; then
							[ "${2}" != "abort" ] && printf "\n\t\t(mac80211 station mode vif already available for [${PHYDEV}]${1} on [${PHYDEV}]${i})\n"
							need_sta=0
						fi
					done
				fi
				if [ "${need_sta}" = "1" ] && [ -e /sys/class/net/${1%mon}/phy80211/name ]; then
					if [ "$(cat /sys/class/net/${1%mon}/phy80211/name)" = "${PHYDEV}" ]; then
						printf "\nYou already have a ${1%mon} device but it is NOT in station mode."
						printf "\nWhatever you did, don't do it again."
						printf "\nPlease run \"iw ${1%mon} del\" before attempting to continue\n"
						exit 1
					else
						printf "\nYou already have a ${1%mon} device, but is is not on the same phy as ${1}.\n"
						printf "\nAttemping to pick a new name...\n"
						findFreeInterface station
					fi
				fi
				if [ "${need_sta}" = "1" ]; then
					IW_ERROR="$(iw phy ${PHYDEV} interface add ${1%mon} type station 2>&1)"
					if [ -z "${IW_ERROR}" ]; then
						interface="${1%mon}"
						if [ -d /sys/class/ieee80211/${PHYDEV}/device/net ]; then
							for i in $(ls /sys/class/ieee80211/${PHYDEV}/device/net/); do
								if [ "$(cat /sys/class/ieee80211/${PHYDEV}/device/net/${i}/type)" = "1" ]; then
									#here is where we catch udev renaming our interface
									interface="${i}"
								fi
							done
						fi
						printf "\n\t\t(mac80211 station mode vif enabled on [${PHYDEV}]${interface})\n"
					else
						printf "\n\n ERROR adding station mode interface: ${IW_ERROR}\n"
					fi
				fi
			fi
			setLink ${1} down
			IW_ERROR="$(iw dev "${1}" del 2>&1 | grep "nl80211 not found")"
			if [ -z "$IW_ERROR" ]; then
				if [ "${2}" != "abort" ]; then
					printf "\n\t\t(mac80211 monitor mode vif disabled for [${PHYDEV}]${1})\n"
				elif [ "${2}" = "abort" ]; then
					printf "\nWARNING: unable to start monitor mode, please run \"airmon-ng check kill\"\n"
				fi
			else
				if [ -f /sys/class/ieee80211/${PHYDEV}/remove_iface ]; then
					printf "${1}" > /sys/class/ieee80211/${PHYDEV}/remove_iface
					printf "\n\t\t(mac80211 monitor mode vif disabled for [${PHYDEV}]${1})\n"
				else
					printf "\n\nERROR: Neither the sysfs interface links nor the iw command is available.\nPlease download and install iw from\n$IW_SOURCE\n"
				fi
			fi
		fi
	fi
}

stopwlIface() {
	if [ -f "/proc/brcm_monitor0" ]; then
		if [ -r "/proc/brcm_monitor0" ]; then
			local brcm_monitor="$(cat /proc/brcm_monitor0)"
			if [ "$brcm_monitor" = "0" ]; then
				printf "\n\t\t(experimental wl monitor mode vif already disabled for [${PHYDEV}]${1})\n"
				return 0
			fi
		fi
		if [ -w "/proc/brcm_monitor0" ]; then
			printf "0" > /proc/brcm_monitor0
			if [ "$?" = "0" ]; then
				printf "\n\t\t(experimental wl monitor mode vif disabled for [${PHYDEV}]${1})\n"
			else
				printf "\n\t\t(failed to disable experimental wl monitor mode for [${PHYDEV}${1})\n"
			fi
		else
			printf "\n\tUnable to write to /proc/brcm_monitor0, cannot disable monitor mode.\n"
		fi
	else
		printf "\n\tThis version of wl does not appear to suport monitor mode.\n"
	fi
}

getDriver() {
	#standard detection path, this is all that is needed for proper drivers
	#DRIVER=$(printf "$ethtool_output" | awk '/driver/ {print $2}')

	#if $(modinfo -n ${DRIVER} > /dev/null 2>&1)
	#then
	#	true
	#else
	#	unset DRIVER
	#fi

	#if [ "$DRIVER" = "" ]
	#then
		if [ -f /sys/class/net/$1/device/uevent ]; then
			DRIVER="$(awk -F'=' '$1 == "DRIVER" {print $2}' /sys/class/net/$1/device/uevent)"
		else
			#DRIVER we put SOMETHING in DRIVER here if we are unable to find anything real
			DRIVER="??????"
		fi
	#fi

	#here we test for driver usb, ath9k_htc,rt2870, possibly others show this
	if [ "$DRIVER" = "usb" ]; then
		printf "Warn ON: USB\n"
		BUSADDR="$(printf "$ethtool_output" | awk '/bus-info/ {print $2}'):1.0"

		if [ "$DEBUG" = "1" ]; 	then
			printf "${BUSADDR}\n"
		fi

		if [ -n "$BUSADDR" ]; then
			if [ -f /sys/class/net/$1/device/"$BUSADDR"/uevent ]; then
				DRIVER="$(awk -F'=' '$1 == "DRIVER" {print $2}' /sys/class/net/$1/device/$BUSADDR/uevent)"
			fi
		fi

		#here we can normalize driver names we don't like
		if [ "$DRIVER" = "rt2870" ]; then
			DRIVER="rt2870sta"
		fi
		if [ -f /sys/class/net/$1/device/idProduct ]; then
			if [ "$(cat /sys/class/net/$1/device/idProduct)" = "3070" ]; then
				DRIVER="rt3070sta"
			fi
		fi
	fi
	if [ "$DRIVER" = "rtl8187L" ]; then
		DRIVER="r8187l"
	fi
	if [ "$DRIVER" = "rtl8187" ] && [ "$STACK" = "ieee80211" ]; then
		DRIVER="r8187"
	fi

	#Here we will catch the broken lying drivers not caught above
	#currently this only functions for pci devices and not usb since lsusb has no -k option
	if [ "${MODINFO}" = "1" ]; then
		if $(modinfo -n $DRIVER  > /dev/null 2>&1)
		then
			true
		else
			if [ -n "${DEVICEID}" ] && [ "$BUS" = "pci" ]; then
				DRIVER="$(lspci -d $DEVICEID -k | awk '/modules/ {print $3}')"
			fi
			if [ -n "$DRIVER" ]; then
				DRIVER="??????"
			fi
		fi
	fi
	if [ "$DEBUG" = "1" ]; then
		printf "getdriver() $DRIVER\n"
	fi
}

getFrom() {
	#from detection
	FROM="K"
	if [ "${MODINFO}" = "1" ] && [ -f /proc/modules ]; then
		if modinfo -n $DRIVER 2>&1 | grep -q 'kernel/drivers'
		then
			FROM="K"
			#we add special handling here because we hate the vendor drivers AND they install in the wrong place
			if [ "$DRIVER" = "r8187" ]; then
				FROM="V"
			elif [ "$DRIVER" = "r8187l" ]; then
				FROM="V"
			elif [ "$DRIVER" = "rt5390sta" ]; then
				FROM="V"
			fi
		elif modinfo -n $DRIVER 2>&1 | grep -q 'updates/drivers'
		then
			FROM="C"
		elif modinfo -n $DRIVER 2>&1 | grep -q misc
		then
			FROM="V"
		elif modinfo -n $DRIVER 2>&1 | grep -q staging
		then
			FROM="S"
		else
			FROM="?"
		fi
	else
		FROM="K"
	fi
	if [ "$DEBUG" = "1" ]; then
		printf "getFrom() $FROM\n"
	fi
}

getFirmware() {
	FIRMWARE="$(printf "$ethtool_output" | awk '/firmware-version/ {print $2}')"
	#ath9k_htc firmware is a shorter version number than most so trap and make it pretty
	if [ "$DRIVER" = "ath9k_htc" ]; then
		FIRMWARE="$FIRMWARE\t"
	fi

	if [ "$FIRMWARE" = "N/A" ]; then
		FIRMWARE="$FIRMWARE\t"
	elif [ -z "$FIRMWARE" ]; then
		FIRMWARE="unavailable"
	fi

	if [ "$DEBUG" = "1" ]; then
		printf "getFirmware $FIRMWARE\n"
	fi
}

getChipset() {
	#this needs cleanup, we shouldn't have multiple lines assigning chipset per bus
	#fix this to be one line per bus
	if [ -f /sys/class/net/$1/device/modalias ]; then
		BUS="$(cut -d ":" -f 1 /sys/class/net/$1/device/modalias)"
		if [ "$BUS" = "usb" ]; then
			if [ "${LSUSB}" = "1" ]; then
				BUSINFO="$(cut -d ":" -f 2 /sys/class/net/$1/device/modalias | cut -b 1-10 | sed 's/^.//;s/p/:/')"
				CHIPSET="$(lsusb -d "$BUSINFO" | head -n1 - | cut -f3- -d ":" | sed 's/^....//;s/ Network Connection//g;s/ Wireless Adapter//g;s/^ //')"
			elif [ "${LSUSB}" = "0" ]; then
				printf "Your system doesn't seem to support usb but we found usb hardware, please report this.\n"
				exit 1
			fi
		#yes the below line looks insane, but broadcom appears to define all the internal buses so we have to detect them here
		elif [ "${BUS}" = "pci" -o "${BUS}" = "pcmcia" ] && [ "${LSPCI}" = "1" ]; then
			if [ -f /sys/class/net/$1/device/vendor ] && [ -f /sys/class/net/$1/device/device ]; then
				DEVICEID="$(cat /sys/class/net/$1/device/vendor):$(cat /sys/class/net/$1/device/device)"
				CHIPSET="$(lspci -d $DEVICEID | cut -f3- -d ":" | sed 's/Wireless LAN Controller //g;s/ Network Connection//g;s/ Wireless Adapter//;s/^ //')"
			else
				BUSINFO="$(printf "$ethtool_output" | grep bus-info | cut -d ":" -f "3-" | sed 's/^ //')"
				CHIPSET="$(lspci | grep "$BUSINFO" | head -n1 - | cut -f3- -d ":" | sed 's/Wireless LAN Controller //g;s/ Network Connection//g;s/ Wireless Adapter//;s/^ //')"
				DEVICEID="$(lspci -nn | grep "$BUSINFO" | grep '[[0-9][0-9][0-9][0-9]:[0-9][0-9][0-9][0-9]' -o)"
			fi
		elif [ "${BUS}" = "sdio" ]; then
			if [ -f /sys/class/net/$1/device/vendor ] && [ -f /sys/class/net/$1/device/device ]; then
				DEVICEID="$(cat /sys/class/net/$1/device/vendor):$(cat /sys/class/net/$1/device/device)"
			fi
			if [ "${DEVICEID}" = '0x02d0:0x4330' ]; then
				CHIPSET='Broadcom 4330'
			elif [ "${DEVICEID}" = '0x02d0:0x4329' ]; then
				CHIPSET='Broadcom 4329'
			elif [ "${DEVICEID}" = '0x02d0:0x4334' ]; then
				CHIPSET='Broadcom 4334'
			elif [ "${DEVICEID}" = '0x02d0:0xa94c' ]; then
				CHIPSET='Broadcom 43340'
			elif [ "${DEVICEID}" = '0x02d0:0xa94d' ]; then
				CHIPSET='Broadcom 43341'
			elif [ "${DEVICEID}" = '0x02d0:0x4324' ]; then
				CHIPSET='Broadcom 43241'
			elif [ "${DEVICEID}" = '0x02d0:0x4335' ]; then
				CHIPSET='Broadcom 4335/4339'
			elif [ "${DEVICEID}" = '0x02d0:0xa962' ]; then
				CHIPSET='Broadcom 43362'
			elif [ "${DEVICEID}" = '0x02d0:0xa9a6' ]; then
				CHIPSET='Broadcom 43430'
			elif [ "${DEVICEID}" = '0x02d0:0x4345' ]; then
				CHIPSET='Broadcom 43455'
			elif [ "${DEVICEID}" = '0x02d0:0x4354' ]; then
				CHIPSET='Broadcom 4354'
			elif [ "${DEVICEID}" = '0x02d0:0xa887' ]; then
				CHIPSET='Broadcom 43143'
			else
				CHIPSET="unable to detect for sdio $DEVICEID"
			fi
		else
			CHIPSET="Not pci, usb, or sdio"
		fi
	#we don't do a check for usb here but it is obviously only going to work for usb
	elif [ -f /sys/class/net/$1/device/idVendor ] && [ -f /sys/class/net/$1/device/idProduct ]; then
		DEVICEID="$(cat /sys/class/net/$1/device/idVendor):$(cat /sys/class/net/$1/device/idProduct)"
		if [ "${LSUSB}" = "1" ]; then
			CHIPSET="$(lsusb | grep -i "$DEVICEID" | head -n1 - | cut -f3- -d ":" | sed 's/^....//;s/ Network Connection//g;s/ Wireless Adapter//g;s/^ //')"
		elif [ "${LSUSB}" = "0" ]; then
			CHIPSET="idVendor and idProduct found on non-usb device, please report this."
		fi
	elif [ "${DRIVER}" = "mac80211_hwsim" ]; then
		CHIPSET="Software simulator of 802.11 radio(s) for mac80211"
	elif $(printf "$ethtool_output" | awk '/bus-info/ {print $2}' | grep -q bcma)
	then
		BUS="bcma"

		if [ "${DRIVER}" = "brcmsmac" ] || [ "${DRIVER}" = "brcmfmac" ] || [ "${DRIVER}" = "b43" ]; then
			CHIPSET="Broadcom on bcma bus, information limited"
		else
			CHIPSET="Unrecognized driver \"${DRIVER}\" on bcma bus"
		fi
	else
		CHIPSET="non-mac80211 device? (report this!)"
	fi

	if [ "$DEBUG" = "1" ]; then
		printf "getchipset() $CHIPSET\n"
		printf "BUS = $BUS\n"
		printf "BUSINFO = $BUSINFO\n"
		printf "DEVICEID = $DEVICEID\n"
	fi
}

getStack() {
	if [ -z "$1" ]; then
		return
	fi

	if [ -d /sys/class/net/$1/phy80211/ ]; then
		MAC80211="1"
		STACK="mac80211"
	else
		MAC80211="0"
		STACK="ieee80211"
	fi

	if [ -e /proc/sys/dev/$1/fftxqmin ]; then
		MAC80211="0"
		STACK="net80211"
	fi

	if [ "$DEBUG" = "1" ]; then
		printf "getStack $STACK\n"
	fi
}

getExtendedInfo() {
	#stuff rfkill info into extended if nothing else is there
	rfkill_check ${PHYDEV}
	rfkill_retcode="$?"
	if [ "${rfkill_retcode}" = "1" ]; then
		EXTENDED="rfkill soft blocked"
	elif [ "${rfkill_retcode}" = "2" ]; then
		EXTENDED="rfkill hard blocked"
	elif [ "${rfkill_redcode}" = "3" ]; then
		EXTENDED="rfkill hard and soft blocked"
	fi

	if [ "$DRIVER" = "??????" ]; then
		EXTENDED="\t Failure detecting driver properly please report"
	fi

	#first we set all the real (useful) info we can find
	if [ -f /sys/class/net/$1/device/product ]; then
		EXTENDED="\t$(cat /sys/class/net/$1/device/product)"
	fi

	#then we sweep for known broken drivers with no available better drivers
	if [ "$DRIVER" = "wl" ]; then
		if [ -f "/proc/brcm_monitor0" ]; then
			EXTENDED="Experimental monitor mode support"
		else
			EXTENDED="No known monitor support, try a newer version or b43"
		fi
	fi
	if [ "$DRIVER" = "brcmsmac" ]; then
		EXTENDED="Driver commonly referred to as brcm80211 (no injection yet)"
	fi
	if [ "$DRIVER" = "r8712u" ]; then
		EXTENDED="\t\t\t\tNo monitor or injection support"
	fi

	#lastly we detect all the broken drivers which have working alternatives
	KV="$(uname -r | awk -F'-' '{print $1}')"
	KVMAJOR="$(printf ${KV} | awk -F'.' '{print $1$2}')"
	KVMINOR="$(printf ${KV} | awk -F'.' '{print $3}')"

	if [ $KVMAJOR -lt 26 ]; then
		printf "You are running a kernel older than 2.6, I'm surprised it didn't error before now."
	        if [ "$DEBUG" = "1" ]; then
			printf "${KVMAJOR} ${KVMINOR}\n"
		fi
		exit 1
	fi

	if [ "$DRIVER" = "rt2870sta" ];	then
		if [ "$KVMAJOR" = "26" ] && [ "$KVMINOR" -ge "35" ]; then
			EXTENDED="\tBlacklist rt2870sta and use rt2800usb"
		else
			EXTENDED="\tUpgrade to kernel 2.6.35 or install compat-wireless stable"
		fi
		#add in a flag for "did you tell use to do X" and emit instructions
	elif [ "$DRIVER" = "rt3070sta" ]; then
		if [ "$KVMAJOR" = "26" ] && [ "$KVMINOR" -ge "35" ]; then
			EXTENDED="\tBlacklist rt3070sta and use rt2800usb"
		else
			EXTENDED="\tUpgrade to kernel 2.6.35 or install compat-wireless stable"
		fi
	elif [ "$DRIVER" = "rt5390sta" ]; then
		if [ "$KVMAJOR" = "26" ] && [ "$KVMINOR" -ge "39" ]; then
			EXTENDED="\tBlacklist rt5390sta and use rt2800usb"
		else
			EXTENDED="\tUpgrade to kernel 2.6.39 or install compat-wireless stable"
		fi
	elif [ "$DRIVER" = "ar9170usb" ]; then
		if [ "$KVMAJOR" = "26" ] && [ "$KVMINOR" -ge "37" ]; then
			EXTENDED="\tBlacklist ar9170usb and use carl9170"
		else
			EXTENDED="\tUpgrade to kernel 2.6.37 or install compat-wireless stable"
		fi
	elif [ "$DRIVER" = "arusb_lnx" ]; then
		if [ "$KVMAJOR" = "26" ] && [ "$KVMINOR" -ge "37" ]; then
			EXTENDED="\tBlacklist arusb_lnx and use carl9170"
		else
			EXTENDED="\tUpgrade to kernel 2.6.37 or install compat-wireless stable"
		fi
	elif [ "$DRIVER" = "r8187" ]; then
		if [ "$KVMAJOR" = "26" ] && [ "$KVMINOR" -ge "29" ]; then
			EXTENDED="\t\tBlacklist r8187 and use rtl8187 from the kernel"
		else
			EXTENDED="\t\tUpgrade to kernel 2.6.29 or install compat-wireless stable"
		fi
	elif [ "$DRIVER" = "r8187l" ]; then
		if [ "$KVMAJOR" = "26" ] && [ "$KVMINOR" -ge "29" ]; then
			EXTENDED="\t\tBlacklist r8187l and use rtl8187 from the kernel"
		else
			EXTENDED="\t\tUpgrade to kernel 2.6.29 or install compat-wireless stable"
		fi
	fi
}

scanProcesses() {
	#this test means it errored and said it was busybox since busybox doesn't print without error
	if (ps -A 2>&1 | grep -q BusyBox)
	then
		#busybox in openwrt cannot handle -A but its output by default is -A
		psopts=""
	else
		psopts="-A"
	fi
	if ( ps -o comm= 2>&1 | grep -q BusyBox )
	then
		#busybox in openwrt cannot handle -o
		pso="0"
	else
		pso="1"
	fi

	PROCESSES="wpa_action\|wpa_supplicant\|wpa_cli\|dhclient\|ifplugd\|dhcdbd\|dhcpcd\|udhcpc\|NetworkManager\|knetworkmanager\|avahi-autoipd\|avahi-daemon\|wlassistant\|wifibox"
	#PS_ERROR="invalid\|illegal"

	if [ -x "$(command -v service 2>&1)" ] && [ "$1" = "kill" ]; then
		service network-manager stop 2> /dev/null > /dev/null
		service NetworkManager stop 2> /dev/null > /dev/null
		service avahi-daemon stop 2> /dev/null > /dev/null
	fi

	unset match
	if [ "${pso}" = 1 ]; then
		match="$(ps ${psopts} -o comm= | grep -c ${PROCESSES})"
	elif [ "${pso}" = 0 ]; then
		#openwrt busybox grep hits on itself so we -v it out
		match="$(ps ${psopts} | grep -c ${PROCESSES} | grep -v grep)"
	fi
	if [ ${match} -gt 0 ] && [ "${1}" != "kill" ]; then
		printf "Found $match processes that could cause trouble.\n"
		printf "If airodump-ng, aireplay-ng or airtun-ng stops working after\n"
		printf "a short period of time, you may want to run 'airmon-ng check kill'\n\n"
	else
		if [ "${1}" != "kill" ] && [ -n "${1}" ]; then
			printf "No interfering processes found\n"
			return
		fi
	fi

	if [ ${match} -gt 0 ]; then
		if [ "${1}" = "kill" ]; then
			printf "Killing these processes:\n\n"
		fi
		if [ "${pso}" = "1" ]; then
			ps ${psopts} -o pid=PID -o comm=Name | grep "${PROCESSES}\|PID"
		else
			#openwrt busybox grep hits on itself so we -v it out
			ps ${psopts} | grep "${PROCESSES}\|PID | grep -v grep"
		fi
		if [ "${1}" = "kill" ]; then
			#we have to use signal 9 because things like nm actually respawn wpa_supplicant too quickly
			if [ "${pso}" = "1" ]; then
				for pid in $(ps ${psopts} -o pid= -o comm= | grep ${PROCESSES} | awk '{print $1}'); do
					kill -9 ${pid}
				done
			else
				#openwrt busybox grep hits on itself so we -v it out
				for pid in $(ps ${psopts} | grep ${PROCESSES} | grep -v grep | awk '{print $1}'); do
					kill -9 ${pid}
				done
			fi
		fi
	fi

	#i=1
	#while [ $i -le $match ]
	#do
	#	pid=$(ps ${psopts} -o pid= -o comm= | grep $PROCESSES | head -n $i | tail -n 1 | awk '{print $1}')
	#	pname=$(ps ${psopts} -o pid= -o comm= | grep $PROCESSES | head -n $i | tail -n 1 | awk '{print $2}')
	#	if [ x"$1" != "xkill" ]
	#	then
	#		printf "${pid}\t${pname}\n"
	#	else
	#		kill ${pid}
	#	fi
	#	i=$(($i+1))
	#done

	printf "\n"

	#this stub is for checking against the interface name, but since it almost never hits why bother?
	#if [ x"${1}" != "x" -a x"${1}" != "xkill" ]
	#then
	#	#the next line doesn't work on busybox ps because -p is unimplimented
	#	match2=$(ps -o comm= -p 1 2>&1 | grep $PS_ERROR -c)
	#	if [ ${match2} -gt 0 ]
	#	then
	#		return
	#	fi
	#
	#	for i in $(ps auxw | grep ${1} | grep -v "grep" | grep -v "airmon-ng" | awk '{print $2}')
	#	do
	#		pname=$(ps -o comm= -p ${i})
	#		printf "Process with PID ${i} ($pname) is running on interface ${1}\n"
	#	done
	#fi
}

listInterfaces() {
	unset iface_list
	for iface in $(ls -1 /sys/class/net)
	do
		if [ -f /sys/class/net/${iface}/uevent ]; then
			if $(grep -q DEVTYPE=wlan /sys/class/net/${iface}/uevent)
			then
				iface_list="${iface_list}\n ${iface}"
			fi
		fi
	done
	if [ -x "$(command -v iwconfig 2>&1)" ] && [ -x "$(command -v sort 2>&1)" ]; then
		for iface in $(iwconfig 2> /dev/null | sed 's/^\([a-zA-Z0-9_.]*\) .*/\1/'); do
			iface_list="${iface_list}\n ${iface}"
		done
		iface_list="$(printf "${iface_list}" | sort -bu)"
	fi
}

getPhy() {
	if [ -z "$1" ];	then
		return
	fi

	if [ $MAC80211 = "0" ]; then
		PHYDEV="null"
		return
	fi

	if [ -r /sys/class/net/$1/phy80211/name ]; then
		PHYDEV="$(cat /sys/class/net/$1/phy80211/name)"
	fi
	if [ -d /sys/class/net/$1/phy80211/ ] && [ -z "${PHYDEV}" ]; then

		PHYDEV="$(ls -l "/sys/class/net/$1/phy80211" | sed 's/^.*\/\([a-zA-Z0-9_-]*\)$/\1/')"
	fi
}

checkvm() {
	#this entire section of code is completely stolen from Carlos Perez's work in checkvm.rb for metasploit and rewritten (poorly) in sh
	#Check dmi info
	if [ -x "$(command -v dmidecode 2>&1)" ]; then
		dmi_info=$(dmidecode 2>&1)
		if [ -n "${dmi_info}" ]; then
			printf "${dmi_info}" | grep -iq "microsoft corporation" 2> /dev/null && vm="MS Hyper-V"
			printf "${dmi_info}" | grep -iq "vmware" 2> /dev/null && vm="VMware"
			printf "${dmi_info}" | grep -iq "virtualbox" 2> /dev/null && vm="VirtualBox"
			printf "${dmi_info}" | grep -iq "qemu" 2> /dev/null && vm="Qemu/KVM"
			printf "${dmi_info}" | grep -iq "domu" 2> /dev/null && vm="Xen"
			[ -n "${vm}" ] && vm_from="dmi_info"
		fi
	fi

	#check loaded modules
	if [ -z "${vm_from}" ]; then
		if [ -x "$(command -v lsmod 2>&1)" ]; then
			lsmod_data="$(lsmod 2>&1)"
			if [ -n "${lsmod}" ]; then
				printf "${lsmod_data}" | grep -iqE "vboxsf|vboxguest" 2> /dev/null && vm="VirtualBox"
				printf "${lsmod_data}" | grep -iqE "vmw_ballon|vmxnet|vmw" 2> /dev/null && vm="VMware"
				printf "${lsmod_data}" | grep -iqE "xen-vbd|xen-vnif" 2> /dev/null && vm="Xen"
				printf "${lsmod_data}" | grep -iqE "virtio_pci|virtio_net" 2> /dev/null && vm="Qemu/KVM"
				printf "${lsmod_data}" | grep -iqE "hv_vmbus|hv_blkvsc|hv_netvsc|hv_utils|hv_storvsc" && vm="MS Hyper-V"
				[ -n "${vm}" ] && vm_from="lsmod"
			fi
		fi
	fi

	#check scsi driver
	if [ -z "${vm_from}" ]; then
		if [ -r /proc/scsi/scsi ]; then
			grep -iq "vmware" /proc/scsi/scsi 2> /dev/null && vm="VMware"
			grep -iq "vbox" /proc/scsi/scsi 2> /dev/null && vm="VirtualBox"
			[ -n "${vm}" ] && vm_from="/pro/scsi/scsi"
		fi
	fi

	# Check IDE Devices
	if [ -z "${vm_from}" ];	then
		if [ -d /proc/ide ]; then
			ide_model="$(cat /proc/ide/hd*/model)"
			printf "${ide_model}" | grep -iq "vbox" 2> /dev/null && vm="VirtualBox"
			printf "${ide_model}" | grep -iq "vmware" 2> /dev/null && vm="VMware"
			printf "${ide_model}" | grep -iq "qemu" 2> /dev/null && vm="Qemu/KVM"
			printf "${ide_model}" | grep -iqE "virtual (hd|cd)" 2> /dev/null && vm="Hyper-V/Virtual PC"
			[ -n "${vm}" ] && vm_from="ide_model"
		fi
	fi

	# Check using lspci
	if [ -z "${vm_from}" ] && [ "${LSPCI}" = "1" ]; then
			lspci_data="$(lspci 2>&1)"
			printf "${lspci_data}" | grep -iq "vmware" 2> /dev/null && vm="VMware"
			printf "${lspci_data}" | grep -iq "virtualbox" 2> /dev/null && vm="VirtualBox"
			[ -n "${vm}" ] && vm_from="lspci"
	fi

	# Xen bus check
	## XXX: Removing unsafe check
	# this check triggers if CONFIG_XEN_PRIVILEGED_GUEST=y et al are set in kconfig (debian default) even in not actually a guest
	#if [ -z ${vm} ]
	#then
	#	ls -1 /sys/bus | grep -iq "xen" 2> /dev/null && vm="Xen"
	#	vm_from="/sys/bus/xen"
	#fi

	# Check using lscpu
	if [ -z "${vm_from}" ]; then
		if [ -x "$(command -v lscpu 2>&1)" ]; then
                        lscpu_data="$(lscpu 2>&1)"
			printf "${lscpu_data}" | grep -iq "Xen" 2> /dev/null && vm="Xen"
			printf "${lscpu_data}" | grep -iq "KVM" 2> /dev/null && vm="KVM"
			printf "${lscpu_data}" | grep -iq "Microsoft" 2> /dev/null && vm="MS Hyper-V"
			[ -n "${vm}" ] && vm_from="lscpu"
		fi
	fi

	#Check vmnet
	if [ -z "${vm_from}" ]; then
		if [ -e /dev/vmnet ]; then
			vm="VMware"
			vm_from="/dev/vmnet"
		fi
	fi

	# Check dmesg Output
	if [ -z "${vm_from}" ]; then
		if [ -x "$(command -v dmesg 2>&1)" ]; then
			dmesg | grep -iqE "vboxbios|vboxcput|vboxfacp|vboxxsdt|(vbox cd-rom)|(vbox harddisk)" && vm="VirtualBox"
			dmesg | grep -iqE "(vmware virtual ide)|(vmware pvscsi)|(vmware virtual platform)" && vm="VMware"
			dmesg | grep -iqE "(xen_mem)|(xen-vbd)" && vm="Xen"
			dmesg | grep -iqE "(qemu virtual cpu version)" && vm="Qemu/KVM"
			[ -n "${vm}" ] && vm_from="dmesg"
		fi
	fi
	checkvm_status="run"
}

#end function definitions
#begin execution

#here we check for any phys that have no interfaces to pick up The Lost Phys
handleLostPhys

listInterfaces

if [ "${1}" = "check" ] || [ "${1}" = "start" ]; then
	if [ "${2}" = "kill" ]; then
		#if we are killing, tell scanProcesses that
		scanProcesses "${2}"
		exit
	elif [ "${1}" = "start" ]; then
		#this stub can send scanProcesses the interface name
		#but this seems entirely unreliable so just run generic
		#scanProcesses "${2}"
		scanProcesses
	else
		scanProcesses
		exit
	fi
fi

if [ "$#" != "0" ]; then
	if [ "$1" != "start" ] && [ "$1" != "stop" ]; then
		usage
	fi

	if [ -z "$2" ]; then
		usage
	fi
fi

#startup checks complete, headers then main

if [ "$DEBUG" = "1" ]; then
	if [ -x "$(command -v readlink 2>&1)" ]; then
		printf "/bin/sh -> $(readlink -f /bin/sh)\n"
		if $(readlink -f /bin/sh) --version > /dev/null 2>&1
		then
			printf "$($(readlink -f /bin/sh) --version)\n"
		fi
	else
		ls -l /bin/sh
		if /bin/sh --version > /dev/null 2>&1
		then
			/bin/sh --version
		fi
	fi
	if [ -n "$SHELL" ]; then
		if $SHELL --version > /dev/null 2>&1
		then
			printf "\nSHELL is $($SHELL --version)\n\n"
		else
			printf "\nSHELL is $SHELL\n\n"
		fi
	fi
fi
if [ "$VERBOSE" = "1" ]; then
	lsb_release -a
	printf "\n"
	uname -a

	checkvm
	if [ -n "${vm}" ]; then
		printf "Detected VM using ${vm_from}\n"
		printf "This appears to be a ${vm} Virtual Machine\n"
		printf "If your system supports VT-d, it may be possible to use PCI devices\n"
		printf "If your system does not support VT-d, you can only use USB wifi cards\n"
	fi

	printf "\nK indicates driver is from $(uname -r)\n"
	if [ "${MODPROBE}" = "1" ]; then
		modprobe compat > /dev/null 2>&1

		if [ -r /sys/module/compat/parameters/compat_version ]; then
			printf "C indicates driver is from $(cat /sys/module/compat/parameters/compat_version)\n"
		fi
	fi
	printf "V indicates driver comes directly from the vendor, almost certainly a bad thing\n"
	printf "S indicates driver comes from the staging tree, these drivers are meant for reference not actual use, BEWARE\n"
	printf "? indicates we do not know where the driver comes from... report this\n\n"
fi

if [ "${VERBOSE}" = "1" ]; then
	printf "\nX[PHY]Interface\t\tDriver[Stack]-FirmwareRev\t\tChipset\t\t\t\t\t\t\t\t\t\tExtended Info\n\n"
else
	printf "PHY\tInterface\tDriver\t\tChipset\n\n"
fi

#this whole block of code shouldn't be here, it makes no sense
#per shellcheck, this block is broken as it runs the loops once with iface=listIfaceUnspec instead of the output of listIFaceUnspec
#for iface in listIfaceUnspec; do
#
#	if [ -e "/proc/sys/dev/$iface/fftxqmin" ]
#	then
#		setLink ${iface} up
#		printf "$iface\t\tAtheros\t\tmadwifi-ng"
#		if [ x$1 = "xstart" ] && [ x$2 = x$iface ]
#		then
#			IFACE=$(wlanconfig ath create wlandev $iface wlanmode monitor -bssid | grep ath)
#			setLink ${iface} up
#			if [ $CH -lt 1000 ]
#			then
#				iwconfig $IFACE channel $CH 2> /dev/null > /dev/null
#			else
#				iwconfig $IFACE freq "$CH"000000 2> /dev/null > /dev/null
#			fi
#		setLink ${IFACE} up
#		UDEV_ISSUE=$?
#		fi
#
#		if [ x$1 = "xstop" ] && [ x$2 = x$iface ]
#		then
#			printf "$iface does not support 'stop', do it on ath interface\n"
#		fi
#
#		#why, dear god why is there a random newline here?
#		printf "\n"
#		sleep 1
#		continue
#	fi
#done
#end random block of code that needs to die

for iface in $(printf "${iface_list}"); do
	unset ethtool_output DRIVER FROM FIRMWARE STACK MADWIFI MAC80211 BUS BUSADDR BUSINFO DEVICEID CHIPSET EXTENDED PHYDEV ifacet DRIVERt FIELD1 FIELD1t FIELD2 FIELD2t CHIPSETt
	#add a RUNNING check here and up the device if it isn't already
	ethtool_output="$(ethtool -i $iface 2>&1)"
	if [ "$ethtool_output" != "Cannot get driver information: Operation not supported" ]; then
		getStack  ${iface}
		getPhy     ${iface}
		getDriver   ${iface}
		getChipset ${iface}
		if [ "${VERBOSE}" = "1" ]; then
			getFrom ${iface}
			getFirmware ${iface}
			getExtendedInfo ${iface}
		fi
	else
 		printf "\nethtool failed...\n"
		printf "Only mac80211 devices on kernel 2.6.33 or higher are officially supported by airmon-ng.\n"
		exit 1
	fi

	#yes this really is the main output loop
	if [ "${VERBOSE}" = "1" ]; then
		#beautify output spacing (within reason)
		FIELD1="${FROM}[${PHYDEV}]${iface}"
		if [ ${#FIELD1} -gt 15 ]; then
			FIELD1t="\t"
		else
			FIELD1t="\t\t"
		fi
		FIELD2="${DRIVER}[${STACK}]-${FIRMWARE}"
		if [ ${#FIELD2} -gt 28 ]; then
			FIELD2t="\t"
		else
			FIELD2t="\t\t"
		fi
		if [ -n "${EXTENDED}" ]; then
			CHIPSETt="\t\t\t\t\t\t\t\t\t\t"
			if [ ${#CHIPSET} -gt 70 ]; then
				CHIPSETt="\t"
			elif [ ${#CHIPSET} -gt 63 ]; then
				CHIPSETt="\t\t"
			elif [ ${#CHIPSET} -gt 56 ]; then
				CHIPSETt="\t\t\t"
			elif [ ${#CHIPSET} -gt 49 ]; then
				CHIPSETt="\t\t\t\t"
			elif [ ${#CHIPSET} -gt 39 ]; then
				CHIPSETt="\t\t\t\t\t"
			elif [ ${#CHIPSET} -gt 35 ]; then
				CHIPSETt="\t\t\t\t\t\t"
			elif [ ${#CHIPSET} -gt 28 ]; then
				CHIPSETt="\t\t\t\t\t\t\t"
			elif [ ${#CHIPSET} -gt 21 ]; then
				CHIPSETt="\t\t\t\t\t\t\t\t"
			elif [ ${#CHIPSET} -gt 14 ]; then
				CHIPSETt="\t\t\t\t\t\t\t\t\t"
			fi
		fi
		printf "${FROM}[${PHYDEV}]${iface}${FIELD1t}${DRIVER}[${STACK}]-${FIRMWARE}${FIELD2t}${CHIPSET}${CHIPSETt}${EXTENDED}\n"
	else
		#beautify output spacing (within reason, interface/driver max length is 15 and phy max length is 7))
		if [ ${#DRIVER} -gt 7 ]; then
			DRIVERt="\t"
		else
			DRIVERt="\t\t"
		fi
		if [ ${#iface} -gt 7 ]; then
			ifacet="\t"
		else
			ifacet="\t\t"
		fi
		printf "${PHYDEV}\t${iface}${ifacet}${DRIVER}${DRIVERt}${CHIPSET}\n"
	fi

	if [ "$DRIVER" = "wl" ]; then
		if [ "$1" = "start" ] && [ "$2" = "$iface" ]; then
			startwlIface $iface
		fi
		if [ "$1" = "stop" ] && [ "$2" = "$iface" ]; then
			stopwlIface $iface
		fi
	elif [ "$MAC80211" = "1" ]; then
		if [ "$1" = "start" ] && [ "$2" = "$iface" ]; then
			startMac80211Iface $iface
		fi

		if [ "$1" = "stop" ] && [ "$2" = "$iface" ]; then
			stopMac80211Iface $iface
		fi
	fi
done

#end with some space
printf "\n"
