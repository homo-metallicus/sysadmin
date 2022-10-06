#!/bin/bash
#
# remoteExec.sh (C) 2022 @homo-metallicus (Romain DECLE)
# https://github.com/homo-metallicus/sysadmin
#
# This Program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3, or (at your option)
# any later version.
#
# This Program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.
#

test $EUID -ne 0 && exit 1

clear
DATE=$(date +%Y%m%d_%Hh%M)
LOG="/var/log/${0##*/}.log"
ROOT_PASSWD=""
TMP_DIR="/tmp"
CLIENT_TMP_DIR="/tmp/"
SSH_OPTS=" -o LogLevel=quiet -o ConnectTimeout=10 -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
APT_LOCK="apt.lock"
NMAP_LOCK="${TMP_DIR}/nmap.lock"
APT_SCRIPT="apt.sh"
AT_SCRIPT="at.sh"
LAUNCH_SCRIPT="launcher.sh"
SCREEN_SCRIPT="screen.sh"
SCRIPTS="${APT_SCRIPT} ${AT_SCRIPT} ${LAUNCH_SCRIPT} ${SCREEN_SCRIPT}"
CHECK_LOG=${1}

function Log() {
	if [ ! -e "${LOG}" ]; then
		echo "Script : \"${0##*/}\"" > "${LOG}"
		echo >> "${LOG}"
	fi
	echo -n "[ ${DATE} ] " >> "${LOG}"
	case $1 in
		-s)
			shift $OPTIND
			echo "${@}" >> "${LOG}"
		;;
		-v)
			shift $OPTIND
			echo "${@}" | tee -a "${LOG}"
		;;
		*)
			echo "${@}" >> "${LOG}"
		;;
	esac
}

function execScript() {
	SCRIPT=$1
	HOST=$2
	expect -c "log_user 0
	spawn -noecho ssh ${SSH_OPTS} root@${HOST} ${SCRIPT}
	expect {
		\"^*assword:\"
	}
	send \"${ROOT_PASSWD}\\r\"
	expect eof"
	BADPASS=$?
}

function secureCopy() {
	HOST=$1
	LOCALPATH=$2
	CLIENTPATH=$3
	expect -c "log_user 0
	spawn -noecho scp ${SSH_OPTS} $LOCALPATH root@${HOST}:$CLIENTPATH
	expect { 
		\"^*assword: \"
	}
	send \"${ROOT_PASSWD}\\r\"
	expect {
		eof { exit 0 } ;
		\"*again.\" { exit 1 }
		\"*rectory\" { exit 2 }
	}
	expect eof"
	BADPASS=$?
}

function testPasswd() {
	BADPASS=$1
	if [ "${BADPASS}" == "1" ] ; then
		Log -v "Incorrect password"
		echo
		exit 1
	elif [ "${BADPASS}" == "2" ] ; then
		Log -v "Incorrect path"
		echo
		exit 1
	else
		Log -v "OK"
		echo
	fi
}

function testLog() {
	HOST=$1
	#LOG_FILE="/var/log/${SCRIPT_NAME}.log"
	LOG_FILE="/var/log/${LAUNCH_SCRIPT}.log"
	if [ "${CHECK_LOG}" == "-d" ]; then
		Log -s "Log verification disabled"
	elif [ "${CHECK_LOG}" == '' ]; then
		testRemoteFile "${HOST}" "${LOG_FILE}"
		TEST_LOG=$?
		if [ ${TEST_LOG} -eq 1 ]; then
			Log -v "Script has already been executed on this client"
			echo
			exit 1
		fi
	else
		Log -v "Usage: ${0##*/} [-d|]"
		echo
		exit 1
	fi
}

function testConn() {
	local HOST="${1}"
	local b=0
	while [ $b -le 3 ]; do
		if [ $b -eq 3 ]; then
			local CONNECTION=1
			break
		fi
		nmap -p22 "${HOST}" | grep "22/tcp" | tr -d " " | grep -qw "22/tcpopenssh"
		TEST_CONN=$?
		if [ "${TEST_CONN}" -ne 0 ]; then
			#echo "Essai n°$((b+1))"
			sleep 0.2
			let b++
		else
			local CONNECTION=0
			break
		fi
	done
	SUCCESS="${CONNECTION}"
}

function deployScripts() {
	TARGET=$1
	Log -v "Copying script on client \"${TARGET}\""
	testLog "${TARGET}"
	secureCopy "${TARGET}" "${SCRIPT_PATH}" "${CLIENT_PATH}"
	BADPASS=$?
	testPasswd "${BADPASS}"
	if [ "${BADPASS}" -eq 0 ]; then
		for SCRIPT in ${SCRIPTS}; do secureCopy "${TARGET}" "${TMP_DIR}/${SCRIPT}" "${CLIENT_TMP_DIR}" ; sleep 1; done
		execScript "${CLIENT_TMP_DIR}${AT_SCRIPT}" "${TARGET}"
		testLock "${TARGET}" "${CLIENT_TMP_DIR}${APT_LOCK}"
		sleep 1
		Log -v "Launching script on client \"${TARGET}\""
		execScript "${CLIENT_TMP_DIR}${SCREEN_SCRIPT}" "${TARGET}"
		BADPASS=$?
		testPasswd "${BADPASS}"
	fi
}	

function makeScripts() {
	echo "#!${SHELL}
	export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt:/tmp
	export DEBIAN_FRONTEND=noninteractive
	dpkg-query -s screen > /dev/null 2>&1 && {
		rm -f ${CLIENT_TMP_DIR}${APT_LOCK} 
	} || {
		apt update -q=2 ; apt install -q=2 --assume-yes screen > /tmp/apt.log 2>&1 && rm -f ${CLIENT_TMP_DIR}${APT_LOCK}
	}
	sleep 1
	exit 0" > "${TMP_DIR}/${APT_SCRIPT}"

	echo "#!${SHELL}
	(
	touch ${CLIENT_TMP_DIR}${APT_LOCK}
	(${CLIENT_TMP_DIR}${APT_SCRIPT}) &
	) 2>&1 >> /tmp/at.log
	exit 0" > "${TMP_DIR}/${AT_SCRIPT}"

	echo "#!${SHELL}
	export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt:/tmp
	export DEBIAN_FRONTEND=noninteractive
	${CLIENT_PATH}${SCRIPT_PATH##*/} \"${ARGS}\"
	exit 0" > "${TMP_DIR}/${LAUNCH_SCRIPT}"

	echo "#!${SHELL}
	export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt:/tmp
	LOG='/var/log/\${0##*/}.log'
	(
	#screen -dmS ${SCREEN_NAME} ${CLIENT_PATH}${SCRIPT_NAME}
	screen -dmS ${SCREEN_NAME} ${CLIENT_TMP_DIR}${LAUNCH_SCRIPT}
	) 2>&1 | tee \$LOG
	exit 0" > "${TMP_DIR}/${SCREEN_SCRIPT}"

	for SCRIPT in ${SCRIPTS}; do chmod +x "${TMP_DIR}/${SCRIPT}"; done
}

function testLock() {
	HOST=$1
	LOCK_FILE=$2
	testRemoteFile "${HOST}" "${LOCK_FILE}"
	TEST_LOCK=$?
	while [ $TEST_LOCK -eq 1 ];do
		sleep 1
		testRemoteFile "${HOST}" "${LOCK_FILE}"
		TEST_LOCK=$?
	done
}

function testRemoteFile() {
	HOST=$1
	LOCK_FILE=$2
	expect -c "log_user 0
	spawn -noecho ssh ${SSH_OPTS} root@${HOST} \"ls\ ${LOCK_FILE}\"
	expect \"^*assword:\"
	send \"${ROOT_PASSWD}\\r\"
	expect {
		\"${LOCK_FILE}\\r\" { exit 1 } ;
		\"ls:*\" { exit 0 } ;
	}
	exit 0
	expect eof"
}

function sendHosts() {
	HOSTS=${1}
	_NETWORK=$(echo "${HOSTS}" | awk -F"." '{ print $1"."$2"."$3 }')
	if echo "${HOSTS}" | grep -q "-"; then
		local j=0
		local k=0
		declare -a ARRAY_IP
		_FIRST_IP=$(echo "${HOSTS}" | awk -F"." '{ print $1"."$2"."$3"."$4 }' | awk -F"-" '{ print $1 }')
		_LAST_IP=${_NETWORK}"."$(echo "${HOSTS}" | awk -F"-" '{ print $2 }')
		FIRST_IP=$(echo "${_FIRST_IP}" | awk -F"." '{ print $4 }')
		LAST_IP=$(echo "${_LAST_IP}" | awk -F"." '{ print $4 }')
		NB_IP=$(((LAST_IP - FIRST_IP) + 1))
		if [ "${NB_IP}" -gt 2 ];then
			ARRAY_IP=( $(while [ $j -lt "${NB_IP}" ]; do echo "${_NETWORK}.${FIRST_IP}";let j++;let FIRST_IP++;done) )
			j=0
		else
			ARRAY_IP=( "${_NETWORK}.${FIRST_IP}" "${_NETWORK}.${LAST_IP}" )
		fi
		#printf '%s\n' "${ARRAY_IP[@]}"	
		declare -a IP_ARRAY
		local l=0
		echo
		touch "${NMAP_LOCK}"
		echo -n "Looking for clients online "
		DOTS=0
		LOOPS=0
		while [ $j -lt ${#ARRAY_IP[*]} ]; do
			if [ -e /tmp/nmap.lock ]; then
				echo -n "."
				DOTS=$((DOTS + 1))
				if [ ${LOOPS} -lt 1 ]; then
					if [ ${DOTS} -eq 8 ]; then
						echo										
						DOTS=0
						LOOPS=$((LOOPS +1))
					fi
				else
					if [ ${DOTS} -eq 40 ]; then
						echo										
						DOTS=0
					fi
				fi
			fi
			testConn "${ARRAY_IP[$j]}"
			if [ "${SUCCESS}" -eq 0 ]; then
				IP_ARRAY[$l]=${ARRAY_IP[$j]}
				l=$((l+1))
				sleep 0.2
			else
				j=$((j+1))
				continue
			fi
			j=$((j+1))
		done
		unset ARRAY_IP
		echo " ${#IP_ARRAY[*]} online"
		rm -f "${NMAP_LOCK}"
		if [ ${#IP_ARRAY[*]} -eq 0 ]; then
			echo
			Log -v "No client online"
			exit 1
		fi
		if [ ${#IP_ARRAY[*]} -gt 0 ]; then
			while [ $k -lt ${#IP_ARRAY[*]} ];do
					if [ $k -eq 0 ]; then echo; fi
					deployScripts "${IP_ARRAY[$k]}"
					k=$((k+1))
			done	
			unset IP_ARRAY
		fi
	else
		testConn "${HOSTS}"
		if [ "${SUCCESS}" -eq 1 ]; then
			echo
			Log -v "Client \"${HOSTS}\" offline, quitting"
			echo
			exit 1
		fi
		echo
		deployScripts "${HOSTS}"
	fi
}

echo "#######################################"
echo "###     Remote execution script     ###"
echo "###       for Debian client(s)      ###"
echo "#######################################"

sleep 1

Log -s "Starting script"

echo
echo "Script path: "
echo "============"
read -r SCRIPT_PATH
test -f "${SCRIPT_PATH}" && chmod +x "${SCRIPT_PATH}" || exit 1

Log -s "Script : ${SCRIPT_PATH}"

echo
echo "Script Argument(s): "
echo "==================="
OLD_IFS=${IFS}
IFS=
read -r ARGS
IFS=${OLD_IFS}

Log -s "Argument(s) : ${ARGS}"

echo
echo "Screen session name: "
echo "===================="
read -r SCREEN_NAME

Log -s "Screen session name: ${SCREEN_NAME}"

echo
echo "Client destination directory: "
echo "============================="
read -r CLIENT_PATH
STRLN=${#CLIENT_PATH}
LAST=${CLIENT_PATH:${STRLN}-1:1}
[[ "${LAST}" != "/" ]] && { 
	CLIENT_PATH="${CLIENT_PATH}/"
}

Log -s "Script destination directory: ${CLIENT_PATH}"

echo
echo "IP addres or range: "
echo "==================="
read -r HOSTS

Log -s "Client(s): ${HOSTS}"

[ -n "${ROOT_PASSWD:+x}" ] || {
	echo
	stty -echo
	echo -n "\"root\" password on client(s): "
	read -r _ROOT_PASSWD
	echo
	echo -n "Confirm password: "
	read -r __ROOT_PASSWD
	echo
	stty echo
	if [ "${_ROOT_PASSWD}" != "${__ROOT_PASSWD}" ]; then
		Log -v "Passwords don't match"
		exit 1
	elif [ -z "${_ROOT_PASSWD}" ]; then
		Log -v "Password can't be empty"
		exit 1
	else 
		ROOT_PASSWD="${_ROOT_PASSWD}"
	fi
}

makeScripts

sendHosts "${HOSTS}"

for SCRIPT in ${SCRIPTS}; do rm -f "${TMP_DIR}/${SCRIPT}"; done

Log -v "End"
echo
exit 0
