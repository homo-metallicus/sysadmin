#!/bin/bash
#
# rsyncBackup.sh (C) 2022 @homo-metallicus (Romain DECLE)
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

SCRIPT=$(basename ${0})
DEFAULT_CONFIG_FILE="/usr/local/etc/default/${SCRIPT%%.sh}"
CONFIG_FILE="/usr/local/etc/${SCRIPT%%.sh}.conf"
TODAY=$(date +"%Y-%m-%d")
YESTERDAY=$(date +"%Y-%m-%d" --date '1 day ago')
USAGE="Usage: $0 [-c|-i]"
LOG="/var/log/"${SCRIPT%%.sh}".log"

. $DEFAULT_CONFIG_FILE || {
	REPORT=0
	echo "default config file not found, backup report can't be sent" | tee -a $LOG
}

. $CONFIG_FILE || {
	[ -n "${REPORT:+x}" ] && {
		echo "couldn't find config file" | mail -s "Backup report" $MAIL_ADMIN 
	} ||
	{
		echo "couldn't find config file" | tee -a $LOG
		sleep 1
		exit 1
	}
}

function createVar() {
	_TMP_VAR=$(echo \$${1})${2}
	eval "echo ${_TMP_VAR}"
}

function testConn() {
	TRY=${1:-0}
	[ $TRY -eq 2 ] && {
		TRY=0
		echo "function "${FUNCNAME}": host \""${BACKUP_HOST}"\" seems to be down" | tee -a $LOG
		[ ${TRY} -eq 1 ] && continue || exit 1
	}
	case ${TRANSFER_METHOD} in
		SSH)
			SERVICE_PORT="22"
			SERVICE_NAME="ssh"
		;;
		CIFS)
			SERVICE_PORT="445"
			SERVICE_NAME="microsoft-ds"
		;;
		*)
			echo "function "${FUNCNAME}": missing transfer method, check config file" | tee -a $LOG
			exit 1
		;;
	esac
	nmap -p"${SERVICE_PORT}" "${BACKUP_HOST}" | grep "${SERVICE_PORT}/tcp" | tr -d " " | grep -qw "${SERVICE_PORT}/tcpopen${SERVICE_NAME}" && {
		if [ ${TRY} -ne 0 ]; then
			TRY=0
		fi
	} ||
	{
		TRY=$((${TRY} + 1))
		echo "function "${FUNCNAME}": couldn't connect to \"${SERVICE_NAME}\" service on port \"${SERVICE_PORT}\" (try ${TRY})" | tee -a $LOG
		sleep 1
		testConn ${TRY}
	}

}

function checkEUID() {
	test $EUID != 0 && {
		echo "function "${FUNCNAME}": only root can execute this script" | tee -a $LOG
		exit 1
	}
}

function sendReport() {
	echo -n "sending backup report to \"${MAIL_ADMIN}\"..."
	[ -e $LOG ] && {
		cat "${LOG}" | mail -s "Backup report" ${MAIL_ADMIN} && echo "done" || echo "error"
	} ||
	{
		echo "couldn't find log file \"${LOG}\"" | mail -s "Backup report" ${MAIL_ADMIN} && echo "done" || echo "error"
	}
	echo
}

function remoteFs() {
	OPTS=$(createVar ${TRANSFER_METHOD} _OPTS)
	BACKUP_USER=$(createVar ${TRANSFER_METHOD} _BACKUP_USER)
	BACKUP_PASSWD=$(createVar ${TRANSFER_METHOD} _BACKUP_PASSWD)
	err=0
	if [ ${1} == "-m" ]; then
		mount | grep -qw ^"${BACKUP_PATH}" || {
			mkdir -p "${BACKUP_PATH}" > /dev/null 2>&1 || {
				if  [ -d "${BACKUP_PATH}" ]; then
					echo "function "${FUNCNAME}": mountpoint \""${BACKUP_PATH}"\" already exists" | tee -a $LOG
				else
					echo "function "${FUNCNAME}": couldn't create mountpoint \""${BACKUP_PATH}"\"" | tee -a $LOG
				fi
				sleep 1
			}
			test $VERBOSE -eq 1 && echo
			case ${TRANSFER_METHOD} in
				SSH)
					echo "${BACKUP_PASSWD}" | sshfs ${BACKUP_USER}@${BACKUP_HOST}: ${BACKUP_PATH} ${OPTS} > /dev/null 2>&1 || err=$((${err} + 1))
				;;
				CIFS)
					/bin/mount -t cifs ${OPTS} //${BACKUP_HOST}${CIFS_BACKUP_PATH} ${BACKUP_PATH} > /dev/null 2>&1 || err=$((${err} + 1))
				;;
			esac
			test ${err} -eq 0 || {
				echo "function "${FUNCNAME}": client \""${BACKUP_HOST}"\" already mounted or invalid password" | tee -a $LOG
				sleep 1
				exit 1
			}
		}
	fi
	if [ ${1} == "-u" ]; then
		mount | grep -qw ${BACKUP_PATH} && {
			err=0
			case ${TRANSFER_METHOD} in
				SSH)
					fusermount -u ${BACKUP_PATH} || {
						fusermount -u -z ${BACKUP_PATH} && err=$((${err} + 1))
						sleep 1
					}
				;;
				CIFS)
					umount ${BACKUP_PATH} || {
						umount -l ${BACKUP_PATH} && err=$((${err} + 1))
						sleep 1
					}
				;;
			esac
			test ${err} -eq 0 || {
				echo "function "${FUNCNAME}": forced unmount \""${BACKUP_PATH}"\" ("${TRANSFER_METHOD}" method) " | tee -a $LOG
				sleep 1
			}
		}
	fi
}

function cleanOldBackups() {
	LS=$(ls -d ${1}/* | sort | head --lines=-${2} | xargs rm -Rf)
	if [ ${?} -ne 0 ]; then
		echo "An error occured during deletion"
		exit 1
	fi
}

function createDir() {
	if [ ! -d "${1}" ]; then
		mkdir -p "${1}"
	fi
}

if [ $# -eq 1 ]; then
	checkEUID
	testConn
	if [ -e $LOG ]; then
		cp $LOG $LOG"_"$(date +%Y%m%d_%Hh%M) && rm -f $LOG
	fi
	createDir "${BACKUP_PATH}"
	remoteFs -m
	sleep 2
	v=0
	> .exclude
	while [ $v -lt ${#EXCLUSIONS[*]} ]; do echo "${EXCLUSIONS[$v]}" >> .exclude; let v++; done; v=0
	echo
	echo "Date: "$(date +%d/%m/%Y) | tee -a $LOG
	echo "Source host: "$(hostname) | tee -a $LOG
	echo "Target host: "${BACKUP_HOST} | tee -a $LOG
	echo "Backup method: "${TRANSFER_METHOD,,} | tee -a $LOG
	if [ "${1}" == "-c" ]; then
		echo "Backup type: complete" | tee -a $LOG
	fi
	if [ "${1}" == "-i" ]; then
		echo "Backup type: incremental" | tee -a $LOG
	fi
	echo | tee -a $LOG
	echo "[ "$(date +%Hh%M)" ] Script is starting" >> $LOG
	BACKUP_DIR=$(createVar ${TRANSFER_METHOD} _BACKUP_DIR)
	while [ $v -lt ${#DIRS_TO_BACKUP[*]} ]; do
		if [ "${DIRS_TO_BACKUP[$v]}" != "/" ]; then
			_BACKUP_TARGET="${BACKUP_DIR}/$(basename ${DIRS_TO_BACKUP[$v]})"
		else
			_BACKUP_TARGET="${BACKUP_DIR}"
		fi
		BACKUP_TARGET="${BACKUP_PATH}${_BACKUP_TARGET}"
		createDir "${BACKUP_TARGET}"
		NOW_BACKUP_TARGET="${BACKUP_TARGET}/${TODAY}"
		createDir "${NOW_BACKUP_TARGET}"
		if [ ${?} -ne 0 ]; then
			echo "Could not create backup target" | tee -a $LOG
			exit 1
		fi
		TMP="/mnt/tmp"
		createDir "${TMP}"
		echo >> $LOG
		echo "[ ${DIRS_TO_BACKUP[$v]}* => ${_BACKUP_TARGET}/${TODAY}/ ]" | tee -a $LOG
		if [ "${1}" == "-c" ]; then
			OPT=""
		fi
		if [ "${1}" == "-i" ]; then
			OPT=--link-dest="${BACKUP_TARGET}/${YESTERDAY}"
		fi
		rsync -a --delete --stats --no-o --no-g --safe-links --exclude-from=.exclude "${OPT}" "${DIRS_TO_BACKUP[$v]}" "${NOW_BACKUP_TARGET}/" 2>/dev/null >> $LOG
		cleanOldBackups "${BACKUP_TARGET}" ${KEEPERS}
		if [ $v -ne $((${#DIRS_TO_BACKUP[*]}-1)) ]; then
			echo
		fi
		let v++
	done
	sleep 2
	echo | tee -a $LOG
	echo "[ "$(date +%Hh%M)" ] Script is ending" >> $LOG
	sleep 2
	sendReport
	sleep 2
	remoteFs -u
else
	echo ${USAGE}
	exit 1
fi

exit 0
