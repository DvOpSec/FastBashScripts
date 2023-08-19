#!/bin/bash
#
# metadata_begin
# recipe: Zabbix Agent2
# tags: centos7,centos8,centos9,alma,rocky,oracle,fedora,debian10,debian11,debian12,ubuntu1804,ubuntu2004,ubuntu2204,ubuntu2004_arm,ubuntu2204_arm
# revision: 0
# description_ru: Zabbix Agent2
# description_en: Zabbix Agent2
# metadata_end
#

RNAME="Zabbix-agent2"

set -x

LOG_PIPE=/tmp/log.pipe.$$
mkfifo ${LOG_PIPE}
LOG_FILE=/root/${RNAME}.log
touch ${LOG_FILE}
chmod 600 ${LOG_FILE}
tee < ${LOG_PIPE} ${LOG_FILE} &
exec > ${LOG_PIPE}
exec 2> ${LOG_PIPE}

killjobs() {
    test -n "$(jobs -p)" && kill $(jobs -p) || :
}
trap killjobs INT TERM EXIT

echo
echo "=== Recipe ${RNAME} started at $(date) ==="
echo

# Переменные
ZABBIX_AGENT2_CONFIG="/etc/zabbix/zabbix_agent2.conf"
[ "($ZABBIX_SERVER)" != "()" ] && ZABBIX_SERVER="($ZABBIX_SERVER)"
ZABBIX_RELEASE_FULL="6.4-1"
ZABBIX_RELEASE="6.4"

# Определение IP-адресов и сетевой карты
#ipv4Addr=$(ip a | grep 'inet ' | grep global | awk '{print $2}' | sed -r 's/\/.+//')
#ipv6Addr=$(ip a | grep 'inet6' | grep global | awk '{print $2}' | sed -r 's/\/.+//')
ipv4Addr=$(ip route get 1 | grep -Po '(?<=src )[^ ]+')
ipv6Addr=$(ip -6 route get 1 | grep -Po '(?<=src )[^ ]+')
ifName=$(ip route get 1 | grep -Po '(?<=dev )[^ ]+')

# Информация об ОС
. /etc/os-release
osLike="${ID_LIKE}"
[ "${ID}" = "debian" ] && osLike="debian"
echo ${ID_LIKE} | grep -q "rhel\|fedora" && osLike="rhel"
[ "${ID}" = "fedora" ] && osLike="rhel"
unaID=$(echo ${VERSION_ID} | sed -r 's/\..+//')

# Определение пакетного менеджера
DNF="/usr/bin/yum"
[ -f /usr/bin/dnf ] && DNF="/usr/bin/dnf"
[ -f /usr/bin/apt ] && DNF="/usr/bin/apt -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -q -y --allow-downgrades --allow-remove-essential --allow-change-held-packages "
[ -n "${DNF}" ] || exit 1

# Финальный текст
final_text() {
cat > /root/${RNAME}-script-final.txt <<- EOF
Работа скрипта ${RNAME} успешно завершена.
Конфигурационные файлы находятся в каталоге /etc/zabbix/

The ${RNAME} script completed successfully.
The configuration files are located in the directory /etc/zabbix/
EOF
}

# Установка основных программ и подготовка базовых репозиториев
install_soft() {
if [ "${osLike}" = "debian" ]; then
	export DEBIAN_FRONTEND=noninteractive
	[ $(systemctl is-active unattended-upgrades.service 2>/dev/null) = "active" ] && systemctl stop unattended-upgrades.service && unattServ="0"
	while ps uxaww | grep  -v grep | grep -Eq 'apt-get|dpkg|unattended' ; do echo "waiting..." ; sleep 5 ; done
	${DNF} update && ${DNF} -y install lsb-release ca-certificates debian-archive-keyring
fi
if [ "${osLike}" = "rhel" -a "${ID}" = "ol" ]; then
	sed -i 's/oracle.com/hoztnode.net/' /etc/yum/vars/ocidomain
fi
[ "${osLike}" = "rhel" ] && \
case ${unaID} in
"7")
	${DNF} -y install policycoreutils-python
	;;
*)
	${DNF} -y install policycoreutils-python-utils 
	${DNF} -y update libmodulemd
esac
${DNF} -y install tuned 2>/dev/null
systemctl enable --now tuned 2>/dev/null
${DNF} -y install curl
}

# Преднастройка ОС
config_system() {
[ "${osLike}" = "debian" -a "${VERSION_ID}" = "10" ] && \
echo $(hostname -I | cut -d\  -f1) $(hostname) | tee -a /etc/hosts
}

# Определение и настройка фаервола
config_firewall() {
local firewalldZone="public"
[ "${osLike}" = "rhel" -a "${ID}" = "fedora" ] && local firewalldZone="FedoraServer"
if [ -f /usr/sbin/firewalld ]; then
	[ ! -f /usr/lib/firewalld/services/zabbix-agent.xml ] && \
	cat << 'EOF' > /etc/firewalld/services/zabbix-agent.xml
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>Zabbix Agent</short>
  <description>Zabbix is a mature and effortless enterprise-class open source monitoring solution for network monitoring and application monitoring of millions of metrics.</description>
  <port protocol="tcp" port="10050"/>
</service>
EOF
	firewall-cmd --reload
	firewall-cmd --permanent --zone=${firewalldZone} --remove-service=dhcpv6-client
#	firewall-cmd --permanent --zone=${firewalldZone} --remove-service=cockpit
	firewall-cmd --permanent --zone=${firewalldZone} --add-service=zabbix-agent
    firewall-cmd --permanent --zone=${firewalldZone} --add-source="${ZABBIX_SERVER}/32" --permanent
    firewall-cmd --reload
fi
}

# Установка Zabbix Agent2
install_zabbix_agent2() {
case ${osLike} in
	"debian")
		local idDebUbn=${ID}
		[ "${ID}" = "ubuntu" -a $(uname -m) = "arm64" ] && local idDebUbn="ubuntu-arm64"
		curl -o /root/zabbix-release.deb https://mirror.hoztnode.net/zabbix/zabbix/${ZABBIX_RELEASE}/${idDebUbn}/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_RELEASE_FULL}+${idDebUbn}${VERSION_ID}_all.deb && \
		dpkg -i /root/zabbix-release.deb && \
		sed -i 's/repo.zabbix.com/mirror.hoztnode.net\/zabbix/' /etc/apt/sources.list.d/zabbix.list
		[ -f /root/zabbix-release.deb ] && rm -rf /root/zabbix-release.deb
		${DNF} update
	;;
	"rhel")
		[ "S{ID}" != "fedora" ] && \
		${DNF} -y install https://mirror.hoztnode.net/zabbix/zabbix/${ZABBIX_RELEASE}/rhel/${unaID}/x86_64/zabbix-release-${ZABBIX_RELEASE_FULL}.el${unaID}.noarch.rpm
	;;
esac
${DNF} -y install zabbix-agent2 || exit 1
systemctl enable zabbix-agent2.service
}

# Настройка сервера Zabbix Agent2
config_zabbix_agent2() {
	sed -i "s/Server=127.0.0.1/Server=127.0.0.1,${ZABBIX_SERVER}/" ${ZABBIX_AGENT2_CONFIG}
	sed -i "s/ServerActive=127.0.0.1/ServerActive=127.0.0.1,${ZABBIX_SERVER}/" ${ZABBIX_AGENT2_CONFIG}
	systemctl restart zabbix-agent2.service
}

install_soft
config_system
install_zabbix_agent2 && final_text || exit 1
# Включаем обратно сервис самообновления Ubuntu
[ -n "$unattServ" ] && systemctl start unattended-upgrades.service
if [ -n "${ZABBIX_SERVER}" ]; then
	config_zabbix_agent2
	config_firewall
fi
