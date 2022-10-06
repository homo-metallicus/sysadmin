#!/bin/bash
#
# genAutoInstallPkg.sh (C) 2022 @homo-metallicus (Romain DECLE)
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

[[ ${EUID} -ne 0 ]] && exit 1

USAGE="Usage: ${0##*/} [-b|-u] DEBIAN_PACKAGE"

if [ $# -lt 2 ]; then
	echo "${USAGE}"
	exit 1
fi

if [ "${1}" != "-b" ] && [ "${1}" != "-u" ]; then
	echo "${USAGE}"
	exit 1
else
	if [ "${1}" == "-u" ]; then
		ENCODE="| uuencode -"
		dpkg-query -s sharutils > /dev/null 2>&1 || {
			apt update -q=2 ; apt install -q=2 --assume-yes sharutils
		}
	else
		ENCODE=""
	fi
fi

if [ "${2:${#2}-4:4}" != ".deb" ]; then
	echo "\"${2}\" is not a \".deb\" file"
	exit 1
else
	FILETYPE=$(file "${2}" | cut -d ':' -f2 | awk -F " " '{print $1" "$2" "$3;}')
	if [ "${FILETYPE}" != "Debian binary package" ]; then
		echo "\"${2}\" is not a valid Debian binary package"
		exit 1
	fi
fi

[ ! -d ~/tmp ] && mkdir ~/tmp

EXEC_PATH=$(echo "$(basename "${2}")")

OUTPUT_SCRIPT=~/tmp/"${EXEC_PATH%.deb}.sh"

DPKG="dpkg -i ./${EXEC_PATH}"

echo "#!${SHELL}" > "${OUTPUT_SCRIPT}"

if [ "${1}" == "-u" ]; then
	echo -e "dpkg-query -s sharutils > /dev/null 2>&1 || {
\texport PATH=${PATH}
\texport DEBIAN_FRONTEND=noninteractive
\tapt update -q=2 ; apt install -q=2 --assume-yes sharutils
}" >> "${OUTPUT_SCRIPT}"
fi

echo -n "MATCH=\$(grep -an '^PAYLOAD:\$' \${0} | cut -d ':' -f1)
START=\$((\${MATCH} + 1))
tail -n +\${START} \${0}" >> "${OUTPUT_SCRIPT}"

[[ "${1}" == "-u" ]] && echo -n " | uudecode" >> "${OUTPUT_SCRIPT}"
echo " > ./${EXEC_PATH}
${DPKG}" >> "${OUTPUT_SCRIPT}"

echo "apt -fy install" >> "${OUTPUT_SCRIPT}"
echo "exit 0
PAYLOAD:" >> "${OUTPUT_SCRIPT}"

eval "cat ${2} ${ENCODE}" >> "${OUTPUT_SCRIPT}" && echo "Install script \"${OUTPUT_SCRIPT}\" moved to ~/tmp" || exit 1

chmod +x "${OUTPUT_SCRIPT}"

exit 0
