#!/bin/bash
#
# lvBackup.sh (C) 2022 @homo-metallicus (Romain DECLE)
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

DEFAULT_CONFIG_FILE="/etc/default/lvBackup"
CONFIG_FILE="/etc/lvBackup.conf"
OK=0
DATE=$(date +"%Y%m%d")
USAGE="Usage: $0 [-a|-m|-r]"
HERE=$(pwd)
. $DEFAULT_CONFIG_FILE || {
	REPORT=0
	Log -v "default config file not found, backup report can't be sent"
}
. $CONFIG_FILE || {
	[ -n "${REPORT:+x}" ] && {
		echo "couldn't find config file" | mail -s "Backup report" $MAIL_ADMIN 
	} ||
	{
		Log -i "couldn't find config file"
		sleep 1
		exit 1
	}
}
function createVar() {
	_TMP_VAR=$(echo \$${TRANSFER_METHOD})${1}
	eval "echo ${_TMP_VAR}"
}
[ "${TRANSFER_METHOD}" != "LOCAL" ] && BACKUP_HOST=$(createVar _BACKUP_HOST) || BACKUP_HOST="localhost"
function testConn() {
	TRY=${1:-0}
	[ $TRY -eq 2 ] && {
		TRY=0
		Log -v "function "${FUNCNAME}": host \""${BACKUP_HOST}"\" seems to be down"
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
		NFS)
			SERVICE_PORT="2049"
			SERVICE_NAME="nfs"
		;;
		*)
			Log -v "function "${FUNCNAME}": missing transfer method setting, check config file"
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
		Log -v "function "${FUNCNAME}": couldn't connect to \"${SERVICE_NAME}\" service on port \"${SERVICE_PORT}\" (try ${TRY})"
		sleep 1
		testConn ${TRY}
	}

}
function Log() {
	[ ! -e $LOG ] && {
		echo "Date: "$(date +%d/%m/%Y) > $LOG
		echo "Compression type: \""${COMPRESSION_TYPE}"\"" >> $LOG
		echo "Transfer method: \""${TRANSFER_METHOD}"\"" >> $LOG
		echo "Backup host: \""${BACKUP_HOST}"\"" >> $LOG
		echo >> $LOG
	}
	if [ "${1}" != "-n" ]; then
		echo -n "[ "$(date +%Hh%M)" ] " >> $LOG
	fi
	case ${1} in
		-i)
			[ -e $LOG ] && {
				cp $LOG $LOG"_"$(date +%Y%m%d_%Hh%M) && rm -f $LOG
			}
			Log -s "${2}"
		;;
		-e)
			echo ${2}
		;;
		-n)
			echo | tee -a $LOG
		;;
		-s)
			echo ${2} >> $LOG
		;;
		-v)
			echo ${2} | tee -a $LOG
		;;
		*)
			:
		;;
	esac
}
BACKUP_PATH=$(createVar _BACKUP_PATH)
BACKUP_DIR=$(createVar _BACKUP_DIR)
if [ "${TRANSFER_METHOD}" != "LOCAL" ]; then
	REMOTE_BACKUP_PATH=$(createVar _REMOTE_BACKUP_PATH)
	OPTS=$(createVar _OPTS)
	if [ "${TRANSFER_METHOD}" != "NFS" ]; then
		BACKUP_USER=$(createVar _BACKUP_USER)
		BACKUP_PASSWD=$(createVar _BACKUP_PASSWD)
	fi
	testConn
fi
function checkEUID() {
	test $EUID != 0 && {
		Log -e "function "${FUNCNAME}": only root can execute this script"
		exit 1
	}
}
function sendReport() {
	echo
	echo -n "sending backup report to \"${MAIL_ADMIN}\"..."
	[ -e $LOG ] && {
		cat "${LOG}" | mail -s "Backup report" ${MAIL_ADMIN} && echo "done" || echo "error"
	} ||
	{
		echo "couldn't find log file \"${LOG}\"" | mail -s "Backup report" ${MAIL_ADMIN} && echo "done" || echo "error"
	}
	echo
}
function getMaxSnapshotSize() {
	#getMaxSnapshotSize ${VG}
	_FREE_VG_SPACE=$(vgdisplay ${1} | grep 'Free' | awk '{print $(NF-1)}')
	
	if [ "${_FREE_VG_SPACE}" == "/" ]; then
		MAX_SNAPSHOT_SIZE=0
	else
		MAX_SNAPSHOT_SIZE=$(vgdisplay ${1} | grep 'Free' | awk '{print $(NF-3)}')
	fi
	echo ${MAX_SNAPSHOT_SIZE}
}
function checkLeftVgSpace() {
	#checkLeftVgSpace ${VG} ${LV} ${MAX_SNAP_SIZE}
	if [ "${3}" == "0" ]; then
		Log -s "function "${FUNCNAME}": no space left for a snapshot on \"${1}\""
		exit 1
	fi
	if [ ! -z ${LOCAL_VGS} ]; then
		for LOCAL_VG in ${LOCAL_VGS}; do
			if [ "${1}" != "${LOCAL_VG}" ]; then
				mount -o ro /dev/${1}/${2} ${TMP_PATH}
				MIN_SNAP_SIZE=$(df -h ${TMP_PATH} | tail -n 1 | awk '{print $2}')
				umount ${TMP_PATH} || umount -l ${TMP_PATH}
			else
				#MIN_SNAP_SIZE=$(df -h | grep -A 1 ${1} | tail -n 1 | awk '{print $2}')
				#MIN_SNAP_SIZE=$(df -h | grep -w ${2} | tail -n 1 | awk '{print $2}')
				MIN_SNAP_SIZE=$(df -h | grep -w ${2} | awk '{print $2}')
				#echo "Minimum snapshot size for ${2}: ${MIN_SNAP_SIZE}"
			fi
		done
	fi
	SNAP_SIZE_UNIT=$(echo ${MIN_SNAP_SIZE:(-1)})
	DEC_SNAP_SIZE=$(echo ${MIN_SNAP_SIZE%$SNAP_SIZE_UNIT})
	ABS_SNAP_SIZE=$(echo ${DEC_SNAP_SIZE} | cut -d "," -f1)
	if [ "${SNAP_SIZE_UNIT}" == "M" ]; then
		MIN_SNAP_SIZE=`expr ${ABS_SNAP_SIZE} + 100`
	fi
	if [ "${SNAP_SIZE_UNIT}" == "G" ]; then
		MIN_SNAP_SIZE=`expr ${ABS_SNAP_SIZE} + 1`
	fi
 	__VG_FREESPACE_UNIT=$(vgdisplay ${1} | grep "Free" | awk -F "/" '{print $3}' | tr -d " ") #returns 30,00GiB
 	_VG_FREESPACE_UNIT=$(echo ${__VG_FREESPACE_UNIT%iB}) #returns 30,00G
	VG_FREESPACE_UNIT=$(echo ${_VG_FREESPACE_UNIT:(-1)}) #returns G
	VG_FREESPACE=$(echo ${_VG_FREESPACE_UNIT} | awk -F "," '{print $1}')
	if [ "${SNAP_SIZE_UNIT}" == "${VG_FREESPACE_UNIT}" ]; then
		test $(expr ${VG_FREESPACE} - ${MIN_SNAP_SIZE} ) -ge 0 && {
			LEFT_SPACE=1
		} ||
		{
			LEFT_SPACE=0
		}
	else
		if [ "${SNAP_SIZE_UNIT}" == "G" ]; then
			LEFT_SPACE=0
		else
			LEFT_SPACE=1
		fi
	fi
	echo ${LEFT_SPACE}
}
function createBackupdir() {
	#createBackupdir ${VG}
	case ${TRANSFER_METHOD} in
		SSH)
			mount | grep -qw ^"${BACKUP_USER}@${BACKUP_HOST}:${REMOTE_BACKUP_PATH}" || mountRemoteFs
		;;
		CIFS)
			mount | grep -Fqw "//${BACKUP_HOST}${REMOTE_BACKUP_PATH}" || mountRemoteFs
		;;
		NFS)
			mount | grep -w ^"${BACKUP_HOST}:/${REMOTE_BACKUP_PATH}" | grep -wq nfs4 || mountRemoteFs
		;;
		LOCAL)
			LOCAL_err=0
			[ -n "${LOCAL_check:+x}" ] || {
				LOCAL_check=0
				[ ${LOCAL_check} -eq 0 ] && {
					mount | grep -qw "${BACKUP_PATH}" || LOCAL_err=$((${LOCAL_err} + 1))
					[ ! -z ${BACKUP_DIR} ] && mkdir -p ${BACKUP_PATH}"/"${BACKUP_DIR}
				}
				LOCAL_check=$((${LOCAL_check} + 1))
			}
			if [ ${LOCAL_err} -gt 0 ]; then
				Log -v ${BACKUP_PATH}" is not mounted, exiting"
				exit 1
			fi
		;;
	esac
	sleep 2
	if [ ! -d ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE} ]; then
		mkdir -p ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE} || {
			Log -v "function "${FUNCNAME}": couldn't create backup directory \""${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"\", exiting"
			sleep 1
			exit 1
		}
	fi
}
function doSnapshot() {
	#doSnapshot ${VG} ${LV} ${MAX_SNAP_SIZE}
	lvcreate -l${3} -s -n ${2}"_tmp" "/dev/"${1}"/"${2} > /dev/null 2>&1 || {
		Log -v "function "${FUNCNAME}": couldn't create snapshot \""${2}"_tmp\""
		sleep 1
		exit 1
	}
}
function createMountpoint() {
	#createMountpoint ${VG} ${LV}
	if [ ! -d ${TMP_PATH}"/"${1}"/"${2}"_tmp" ]; then
		mkdir -p ${TMP_PATH}"/"${1}"/"${2}"_tmp" || { 
			Log -v "function "${FUNCNAME}": couldn't create mount point"
			sleep 1
			removeSnapshot ${1} ${2}
			exit 1
		}
	fi
}
function mountSnapshot() {
	#mountSnapshot ${VG} ${LV}
	mount "/dev/"${1}"/"${2}"_tmp" ${TMP_PATH}"/"${1}"/"${2}"_tmp" || {
		Log -v "function "${FUNCNAME}": couldn't mount \"/dev/"${1}"/"${2}"_tmp\" on \""${TMP_PATH}"/"${1}"/"${2}"_tmp\", exiting"
		sleep 1
		removeSnapshot ${1} ${2}
		exit 1
	}
}
function backupSnapshot() {
	#backupSnapshot ${VG} ${LV}
	num=1
	PROC_NUM=$(cat /proc/cpuinfo | grep -w processor  | wc -l)
	case ${COMPRESSION_TYPE} in
		gz)
			COMPRESSION_COMMAND="gzip -${COMPRESSION_LEVEL}"
			COMPRESSION_EXTENSION="gz"
		;;
		pgz)
			COMPRESSION_COMMAND="pigz -${COMPRESSION_LEVEL} -p ${PROC_NUM}"
			COMPRESSION_EXTENSION="gz"
		;;
		bz2)
			COMPRESSION_COMMAND="bzip2 -${COMPRESSION_LEVEL}"
			COMPRESSION_EXTENSION="bz2"
		;;
		pbz2)
			COMPRESSION_COMMAND="pbzip2 -${COMPRESSION_LEVEL} -p${PROC_NUM}"
			COMPRESSION_EXTENSION="bz2"
		;;
		xz)
			COMPRESSION_COMMAND="xz -${COMPRESSION_LEVEL}"
			COMPRESSION_EXTENSION="xz"
		;;
	esac
	cd  ${TMP_PATH}"/"${1}"/"${2}"_tmp"
	#while [ -e ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"/"${DATE}-${2}-${num}.tar.${COMPRESSION_EXTENSION} ]; do
	while [ -e ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"/"${DATE}-${2}-${num}.tar.${COMPRESSION_EXTENSION}${ARCHIVE_SUFFIX}00 -o -e ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"/"${DATE}-${2}-${num}.tar.${COMPRESSION_EXTENSION} ]; do
		num=$((${num} + 1))
	done
	archive="${DATE}-${2}-${num}.tar.${COMPRESSION_EXTENSION}"
	
	SPLIT_CMD="| split -d -b ${PART_SIZE} - ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"/"${archive}${ARCHIVE_SUFFIX}"
	echo "Saving LV \"${2}\" ("$(df -h | grep -w ${2} | awk '{print $3}')"): "
	#TAR_CMD=$(eval "tar --one-file-system --sparse -pcf - * | pv -i 1 -w 50 -berps `du -bs  ${TMP_PATH}'/'${1}'/'${2}'_tmp' | awk '{print $1}'` | ${COMPRESSION_COMMAND} > ${BACKUP_PATH}'/'${BACKUP_DIR}'/'${1}'/'${DATE}'/'${archive}")
	TAR_CMD=$(eval "tar --one-file-system --sparse -pcf - * | pv -i 1 -w 50 -berps `du -bs  ${TMP_PATH}'/'${1}'/'${2}'_tmp' | awk '{print $1}'` | ${COMPRESSION_COMMAND} ${SPLIT_CMD}")
	$TAR_CMD > /dev/null 2>&1 && {
		Log -v "LV \"${2}\" saved to \""${archive}"\""
	} ||
	{
		umountRemoteFs
		Log -v "function "${FUNCNAME}": couldn't create archive \""${archive}"\""
		echo
		sleep 1
		exit 1
	}
	ARCHIVE_NUM=`ls ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"/"${archive}${ARCHIVE_SUFFIX}* | wc -l`
	test ${ARCHIVE_NUM} -le 1 && {
		mv ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"/"${archive}${ARCHIVE_SUFFIX}00 ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"/"${archive}
	}
	#SIZE_LENGTH=${#PART_SIZE}
	#_SIZE_INDEX=${PART_SIZE:0:-2}
	#__SIZE_UNIT=`echo "${SIZE_LENGTH} - 2" | bc`
	#_SIZE_UNIT=${PART_SIZE:${__SIZE_UNIT}}
	#case ${_SIZE_UNIT} in
	#MB)
	#	POWER="6"
	#;;
	#GB)
	#	POWER="9"
	#;;
	#*)
	#	echo "chunk size unit should be one of \"MB\" or \"GB\""
	#;;
	#esac
	#MULTIPLICATOR=`echo "10^${POWER}" | bc`
	#CHUNK_SIZE=`echo "${_SIZE_INDEX}*${MULTIPLICATOR}" | bc`
	#ARCHIVE_SIZE=`du -bs ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"/"${archive}${ARCHIVE_SUFFIX}00 | awk '{print $1}'`
	#test ${ARCHIVE_SIZE} -lt ${CHUNK_SIZE} && {
	#	mv ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"/"${archive}${ARCHIVE_SUFFIX}00 ${BACKUP_PATH}"/"${BACKUP_DIR}"/"${1}"/"${DATE}"/"${archive}
	#}
	cd ${HERE}
}
function umountSnapshot() {
	#umountSnapshot ${VG} ${LV}
	umount  ${TMP_PATH}"/"${1}"/"${2}"_tmp" || {
		Log -v "function "${FUNCNAME}": couldn't unmount \"" ${TMP_PATH}"/"${1}"/"${2}"_tmp\""
		sleep 1
		exit 1
	}
}
function removeSnapshot() {
	#removeSnapshot ${VG} ${LV}
	lvremove -f "/dev/"${1}/${2}"_tmp" > /dev/null 2>&1 || {
		Log -v "function "${FUNCNAME}": couldn't remove snapshot \"/dev/"${1}/${2}"_tmp\", exiting"
		sleep 1
		exit 1
	}
}
function removeMountpoint() {
	#removeMountpoint ${VG}
	rm -rf ${TMP_PATH}"/"${1} || {
		Log -v "function "${FUNCNAME}": couldn't remove mountpoint \""${TMP_PATH}"/"${1}"\", exiting"
		sleep 1
		exit 1
	}
}
function mountRemoteFs() {
	err=0
	mount | grep -qw ^"${BACKUP_PATH}" || {
		mkdir -p "${BACKUP_PATH}" > /dev/null 2>&1 || {
			if  [ -d "${BACKUP_PATH}" ]; then
				Log -v "function "${FUNCNAME}": mountpoint \""${BACKUP_PATH}"\" already exists"
			else
				Log -v "function "${FUNCNAME}": couldn't create mountpoint \""${BACKUP_PATH}"\""
			fi
			sleep 1
		}
		case ${TRANSFER_METHOD} in
			SSH)
				test $VERBOSE -eq 1 && eval "echo '${BACKUP_PASSWD}' | sshfs ${BACKUP_USER}@${BACKUP_HOST}:${REMOTE_BACKUP_PATH} ${BACKUP_PATH} ${OPTS}"
				echo "${BACKUP_PASSWD}" | sshfs ${BACKUP_USER}@${BACKUP_HOST}:${REMOTE_BACKUP_PATH} ${BACKUP_PATH} ${OPTS} > /dev/null 2>&1 || err=$((${err} + 1))
			;;
			CIFS)
				test $VERBOSE -eq 1 && eval "echo /bin/mount -t cifs ${OPTS} //${BACKUP_HOST}${REMOTE_BACKUP_PATH} ${BACKUP_PATH}"
				/bin/mount -t cifs ${OPTS} //${BACKUP_HOST}${REMOTE_BACKUP_PATH} ${BACKUP_PATH} > /dev/null 2>&1 || err=$((${err} + 1))		
			;;
			NFS)
				test $VERBOSE -eq 1 && eval "echo /bin/mount -t nfs4 ${OPTS} ${BACKUP_HOST}:${REMOTE_BACKUP_PATH} ${BACKUP_PATH}"
				/bin/mount -t nfs4 ${OPTS} ${BACKUP_HOST}:${REMOTE_BACKUP_PATH} ${BACKUP_PATH} > /dev/null 2>&1 || err=$((${err} + 1))
			;;
		esac
		test ${err} -eq 0 || {
			Log -v "function "${FUNCNAME}": client \""${BACKUP_HOST}"\" already mounted or invalid password"
			sleep 1
			exit 1
		}
	}
}
function umountRemoteFs() {
	if [ "${TRANSFER_METHOD}" != "LOCAL" ]; then
		mount | grep -qw ${BACKUP_PATH} && {
			err=0
			if [ "${TRANSFER_METHOD}" == "SSH" ]; then
				fusermount -u ${BACKUP_PATH} || {
					fusermount -u -z ${BACKUP_PATH} && err=$((${err} + 1))
					sleep 1
				}
			else
				umount ${BACKUP_PATH} || {
					umount -l ${BACKUP_PATH} && err=$((${err} + 1))
					sleep 1
				}
			fi
			test ${err} -eq 0 || {
				Log -v "function "${FUNCNAME}": forced unmount \""${BACKUP_PATH}"\" ("${TRANSFER_METHOD}" method) "
				sleep 1
			}
		}
	fi
}
function execBackup() {
	#execBackup ${VG} ${LV} ${MAX_SNAP_SIZE}
	doSnapshot ${1} ${2} ${3}
	sleep 2
	createMountpoint ${1} ${2}
	sleep 2
	mountSnapshot ${1} ${2}
	sleep 2
	backupSnapshot ${1} ${2}
	sleep 2
	umountSnapshot ${1} ${2}
	sleep 2
	removeSnapshot ${1} ${2}
	sleep 2
}
function endBackup() {
	#endBackup ${VG}
	cleanOldBackups ${1}
	sleep 2
	umountRemoteFs
	sleep 2
	removeMountpoint ${1}
	sleep 2
}
function lvBackup() {
	case ${1} in
		m)	
			if [ -z ${2} ];then
				echo
				declare -a VG_array
				[ -n "${LOCAL_VGS:+x}" ] || {
					echo -n "Physical server's VG name (none if empty): "
					read LOCAL_VGS
					if [ -z ${LOCAL_VGS} ];then
            LOCAL_VGS=""
					else
            vgscan | grep -q ${LOCAL_VGS} || {
              echo "couldn't find VG \""${LOCAL_VGS}"\""
              exit 1
            }
					fi
					echo
				}
				VG_array=( `vgdisplay | grep "VG Name" | cut -d " " -f19 | while read VOL; do echo "${VOL}"; done;` )
				VG_count=${#VG_array[*]}
				echo -n "Available VGs: "
				echo
				v=0
				while [ $v -lt ${VG_count} ]; do echo "$(($v + 1)). ${VG_array[$v]}"; v=$(($v + 1)); done; v=0; echo;
				echo -n "Choose a VG from the list above: "
				read _choice
				_choice=$((${_choice} - 1))
				VG=${VG_array[${_choice}]}
				unset VG_array
				if [ ! -d /dev/${VG} ]; then
					echo -n "invalid VG name..."
					sleep 1
					echo "exiting"
					exit 1
				fi
				declare -a LV_array
				LV_array=( `ls /dev/${VG} | eval $(echo "${out}") | while read LV; do echo "${LV}"; done;` )
				LV_count=${#LV_array[*]}
				echo
				echo -n "LVs in VG \"`echo "/dev/"${VG} | cut -d / -f3`\": "
				echo
				j=0
				while [ $j -lt ${LV_count} ]; do echo "$(($j + 1)). ${LV_array[$j]}"; j=$(($j + 1)); done; j=0; echo;
				echo -n "Choose a LV from the list above or type \"A\" for all: "
				read choice
				echo
				Log -v "VG \""${VG}"\""
			else
				choice=${2}
				VG=${3}
			fi
			case ${choice} in 
				[1-${LV_count}])
					choice=$((${choice} - 1))
					createBackupdir ${VG}
					MAX_SNAP_SIZE=$(getMaxSnapshotSize ${VG})
					LEFT_SPACE=$(checkLeftVgSpace ${VG} ${LV_array[${choice}]} ${MAX_SNAP_SIZE})
					if [ "${LEFT_SPACE}" == "1" ]; then
						execBackup ${VG} ${LV_array[${choice}]} ${MAX_SNAP_SIZE}
					else
						Log -v "no space left for a snapshot of \""${LV_array[${choice}]}"\" on \""${VG}"\""
						sleep 1
					fi
					unset LV_count
					unset LV_array
				;;
				A|a)
					ls "/dev/"${VG} | eval $(echo "${out}") | while read LV; do
						createBackupdir ${VG}
						MAX_SNAP_SIZE=$(getMaxSnapshotSize ${VG})
						LEFT_SPACE=$(checkLeftVgSpace ${VG} ${LV} ${MAX_SNAP_SIZE})
						#echo -n "Minimum snapshot size for \"${LV}\": "
						#df -h | grep -w ${LV} | awk '{print $2}'
						if [ "${LEFT_SPACE}" == "1" ]; then
							execBackup ${VG} ${LV} ${MAX_SNAP_SIZE}
						else
							Log -v "no space left for a snapshot of \""${LV}"\" on \""${VG}"\""
							sleep 1
						fi
					done
				;;
				*)
					echo "invalid choice...exiting"
					exit 1
				;;
			esac
			endBackup ${VG}
		;;
		a)
			lvBackup "m" "a" ${2}
		;;
	esac
}
function lvRestore() {
	echo "use your usual GNU/Linux rescue CD for this purpose"
}
function cleanOldBackups() {
	#cleanOldBackups ${VG}
	echo
	touch /tmp/${0##*/}.lock
	HERE=`pwd`
	i=0
	cd "${BACKUP_PATH}/${BACKUP_DIR}/${1}"
	ls -Ad `date +%Y`*/ >/dev/null 2>&1 && {
		BACKUP_SUBDIRS_number=$(ls -Ad `date +%Y`*/ | wc -l)
		if [ ${BACKUP_SUBDIRS_number} -gt ${KEEP_COUNT} ]; then
			declare -a BACKUP_SUBDIRS_array
			BACKUP_SUBDIRS_array=( $(ls -Ar `date +%Y`* | egrep '([[:digit:]]{8}:)' | awk -F':' '{print $1;}' | while read BACKUP_SUBDIR; do test -d "${BACKUP_SUBDIR}" && echo "${BACKUP_SUBDIR}"; done;) )
			BACKUP_SUBDIRS_count=${#BACKUP_SUBDIRS_array[*]}
			if [ ${BACKUP_SUBDIRS_number} -eq ${BACKUP_SUBDIRS_count} ]; then
				until [ ${BACKUP_SUBDIRS_count} -eq ${KEEP_COUNT} ]; do
					BACKUP_SUBDIRS_count=$((${BACKUP_SUBDIRS_count} - 1))
					echo -n "deleting backup dir \""${BACKUP_SUBDIRS_array[${BACKUP_SUBDIRS_count}]}"\""
					while [ ${i} -le 2 ]; do sleep 1;echo -n ".";i=$((${i} + 1)); done
					rm -Rf ${BACKUP_SUBDIRS_array[${BACKUP_SUBDIRS_count}]} && {
						echo "OK"
						Log -s "backup dir \""${BACKUP_SUBDIRS_array[${BACKUP_SUBDIRS_count}]}"\" successfully deleted"
					} || 
					{
						echo "error"
						Log -s "function "${FUNCNAME}": couldn't delete backup dir \""${BACKUP_SUBDIRS_array[${BACKUP_SUBDIRS_count}]}"\""
					}
					i=0
					sleep 1
				done
				unset BACKUP_SUBDIRS_array
				echo
			else
				Log -v "function "${FUNCNAME}": backup directories count does not match"
			fi
		fi
	}
	cd ${HERE}
	sleep 2
	[ -e /tmp/${0##*/}.lock ] && rm -f /tmp/${0##*/}.lock
}
checkEUID
Log -i "Script is starting"
if [ $# -eq 1 ]; then
	[ -n "${BACKUP_PATH:+x}" ] || {
		echo
		echo -n "Backup path (set to \"/mnt/BACKUP\" if empty): "
		read BACKUP_PATH
		if [ -z ${BACKUP_PATH} ]; then
			BACKUP_PATH="/mnt/BACKUP"
		fi
	}
	[ ! -d ${BACKUP_PATH} ] && mkdir -p ${BACKUP_PATH}
	[ -n "${TMP_PATH:+x}" ] || {
		echo -n "Temporary path (set to \"/mnt/tmp\" if empty): "
		read TMP_PATH
		if [ -z ${TMP_PATH} ]; then
			TMP_PATH="/mnt/tmp"
		fi
	}
	[ ! -d ${TMP_PATH} ] && mkdir -p ${TMP_PATH}
	while getopts "amr" option; do
		declare -a LVOUT
		LVOUT_count=${#LVOUT[*]}
		if [ ${LVOUT_count} -ne 0 ]; then
			a=0
			while [ $a -lt ${LVOUT_count} ]; do
				out+="grep -v ${LVOUT[$a]}"
				if [ $a -lt $((${LVOUT_count}-1)) ];then
					out+="| "
				fi
				a=$(($a + 1))
			done
		else
			out="grep -v /"
			echo
		fi
		unset LVOUT
		case ${option} in	
			a)
				declare -a VG
				VG_count=${#VG[*]}
				b=0
				echo
				while [ $b -lt ${VG_count} ]; do
					Log -v "VG \""${VG[$b]}"\""
					lvBackup ${option} ${VG[$b]}
				b=$(($b + 1))
				done
				unset VG
				[ -n "${REPORT:+x}" ] || sendReport
			;;
			m)
				lvBackup ${option}
				[ -n "${REPORT:+x}" ] || sendReport
			;;
			r)
				lvRestore
			;;
			*)
				echo ${USAGE}
				exit 1
			;;
		esac
	done
	shift $((${OPTIND} - 1))
else
	echo ${USAGE}
	exit 1
fi
