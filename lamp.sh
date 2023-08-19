#!/bin/bash
#
# metadata_begin
# recipe: LAMP
# tags: centos7,centos8,centos9,alma,rocky,oracle,fedora,debian10,debian11,debian12,ubuntu1804,ubuntu2004,ubuntu2204,centos_arm,alma_arm,rocky_arm,oracle_arm,ubuntu_arm,debian_arm
# revision: 0
# description_ru: Linux + Apache2 + MySQL + PHP + Nginx
# description_en: Linux + Apache2 + MySQL + PHP + Nginx
# metadata_end
#

RNAME="LAMP"

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
echo "== Recipe ${RNAME} started at $(date) =="
echo

# Пароль
#mypwddb=""
mypwddb=($MY_SQL_PASS)
[ -z "${mypwddb}" -o "${mypwddb}" = "()" ] && mypwddb=$(echo $RANDOM|md5sum|head -c 20)
[ -z "${mypwddb}" -o "${mypwddb}" = "()" ] && echo "Bad passwd. Fail with ${mypwddb}" > /root/${RNAME}-script-final.txt && exit 1

# Определение IP-адресов и сетевой карты
#ipv4Addr=$(ip a | grep 'inet ' | grep global | awk '{print $2}' | sed -r 's/\/.+//')
#ipv6Addr=$(ip a | grep 'inet6' | grep global | awk '{print $2}' | sed -r 's/\/.+//')
ipv4Addr=$(ip route get 1 | grep -Po '(?<=src )[^ ]+')
#ipv6Addr=$(ip -6 route get 1 | grep -Po '(?<=src )[^ ]+')
ifName=$(ip route get 1 | grep -Po '(?<=dev )[^ ]+')

# Информация об ОС
. /etc/os-release
osLike="${ID_LIKE}"
[ "${ID}" = "debian" ] && osLike="debian"
echo ${ID_LIKE} | grep -q "rhel\|fedora" && osLike="rhel"
[ "${ID}" = "fedora" ] && osLike="rhel"
unaID=$(echo ${VERSION_ID} | sed -r 's/\..+//')

# Определение имени демона и конфирационного каталога Apache2
[ "${osLike}" = "debian" ] && webServer="apache2" && webServerSiteDir="/etc/apache2/sites-available/"
[ "${osLike}" = "rhel" ] && webServer="httpd" && webServerSiteDir="/etc/httpd/conf.d/"
[ -z ${webServer} ] && exit 1
[ -z ${webServerSiteDir} ] && exit 1

# Определение имени пользователя Apache2
[ "${osLike}" = "debian" ] && webUser="www-data"
[ "${osLike}" = "rhel" ] && webUser="apache"
[ -z ${webUser} ] && exit 1

# Определение переменных PhpMyAdmin
[ "${osLike}" = "debian" ] && PhpMyAdm_dir="/var/www/phpmyadmin"
[ "${osLike}" = "rhel" ] && PhpMyAdm_dir="/usr/share/phpmyadmin"
[ -z ${PhpMyAdm_dir} ] && exit 1

# Определение SELinux
[ "${osLike}" = "rhel" ] && [ $(sestatus | grep 'SELinux status' | grep -q 'enabled') ] && selinux_enabled=yes

# Определение пакетного менеджера
DNF="/usr/bin/yum"
[ -f /usr/bin/dnf ] && DNF="/usr/bin/dnf"
[ -f /usr/bin/apt ] && DNF="/usr/bin/apt -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -q -y --allow-downgrades --allow-remove-essential --allow-change-held-packages "
[ -n "${DNF}" ] || exit 1

# Настройка /root/.my.cnf
RootMyCnf() {
touch /root/.my.cnf
chmod 600 /root/.my.cnf
echo "[client]" > /root/.my.cnf
echo "password=${1}" >> /root/.my.cnf
}

# Финальный текст
final_text() {
cat > /root/${RNAME}-script-final.txt <<- EOF
Работа скрипта ${RNAME} успешно завершена.
Пароль MariaDB находится в файле /root/.my.cnf.
Журнал выполнения вы можете посмотреть в файле /root/${RNAME}.log
Внимание! В /root/${RNAME}.log может находиться пароль MariaDB в открытом виде, удалите его немедленно.
Панель phpMyAdmin доступна по адресам:
${ipv4Addr}/phpmyadmin

The ${RNAME} script completed successfully.
The MariaDB password is located in the /root/.my.cnf file.
You can see the execution log in /root/${RNAME}.log.
Attention! The /root/${RNAME}.log may contain the MariaDB password in clear text, remove it immediately.
The phpMyAdmin panel is available at:
${ipv4Addr}/phpmyadmin
EOF
}

# Установка основных программ и подготовка базовых репозиториев
install_soft() {
if [ "${osLike}" = "debian" ]; then
	export DEBIAN_FRONTEND=noninteractive
	[ $(systemctl is-active unattended-upgrades.service 2>/dev/null) = "active" ] && systemctl stop unattended-upgrades.service && unattServ="1";
	while ps uxaww | grep  -v grep | grep -Eq 'apt-get|dpkg|unattended' ; do echo "waiting..." ; sleep 5 ; done
	${DNF} update && ${DNF} -y install lsb-release ca-certificates debian-archive-keyring gnupg2
fi
if [ "${osLike}" = "rhel" -a "${ID}" != "ol" -a "${ID}" != "fedora" ]; then
	${DNF} -y install epel-release elrepo-release
fi
if [ "${osLike}" = "rhel" -a "${ID}" = "ol" ]; then
	sed -i 's/oracle.com/hoztnode.net/' /etc/yum/vars/ocidomain
	${DNF} -y install oracle-epel-release-el${unaID}
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
${DNF} -y install bzip2 unzip tar pwgen curl
${DNF} -y install tuned
systemctl enable --now tuned 2>/dev/null
}

# Преднастройка ОС
config_system() {
[ "${osLike}" = "debian" -a "${VERSION_ID}" = "10" ] && \
echo $(hostname -I | cut -d\  -f1) $(hostname) | tee -a /etc/hosts
}

# Настройки SELinux
config_selinux() {
semanage fcontext -a -t httpd_sys_rw_content_t $1
restorecon -R $1
setsebool -P httpd_can_network_connect on
#setsebool httpd_unified on
setsebool -P httpd_unified on
}

# Определение и настройка фаервола
config_firewall() {
if [ -f /usr/sbin/ufw ]; then
	ufw allow http
	ufw allow ssh
fi
if [ -f /usr/sbin/firewalld ]; then
	firewall-cmd --permanent --remove-service=dhcpv6-client
	firewall-cmd --permanent --add-service=http
	firewall-cmd --reload
fi
}

# Установка MySQL
install_mariadb() {
${DNF} -y install mariadb-client 2>/dev/null
${DNF} -y install mariadb-server
systemctl enable --now mariadb.service
}

# Установка Apache2
install_web() {
${DNF} -y install ${webServer}
}

# Установка Nginx
install_nginx() {
if [ "${osLike}" = "rhel" -a "${ID}" != "fedora" ]; then
	cat > /etc/yum.repos.d/nginx.repo <<- 'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/rhel/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/rhel/$releasever/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
fi
if [ "${osLike}" = "debian" ]; then
	curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
	echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${ID}/ ${VERSION_CODENAME} nginx" | tee /etc/apt/sources.list.d/nginx.list
	if [ "${ID}" = "ubuntu" -a "${unaID}" = "18" ]; then
		curl -o- http://nginx.org/keys/nginx_signing.key | apt-key add -
		echo "deb http://nginx.org/packages/${ID}/ ${VERSION_CODENAME} nginx" | tee /etc/apt/sources.list.d/nginx.list
	fi
	apt update
fi
${DNF} -y install nginx
}

# Установка PHP
install_php() {
${DNF} -y install php php-xml php-json php-common php-fpm php-mbstring php-cli php-json php-mbstring php-zip php-gd php-pear
#php-mysqli php-pdo
#${DNF} -y install php-imagick 2>/dev/null
[ "${osLike}" = "debian" ] && ${DNF} -y install php-mysql libapache2-mod-php php-cli
[ "${osLike}" = "rhel" ] && ${DNF} -y install php-mysqlnd php-pecl-zip php-pdo
}

# Установка PhpMyAdmin
install_phpmyadmin() {
if [ "${osLike}" = "rhel" -a "${unaID}" = "7" ]; then
	${DNF} -y install phpmyadmin
else
	mkdir -p ${PhpMyAdm_dir}
	curl -s --connect-timeout 30 --retry 10 --retry-delay 5 -k -L "https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz" | tar xz --strip-components=1 -C ${PhpMyAdm_dir}
	cp ${PhpMyAdm_dir}/config.sample.inc.php ${PhpMyAdm_dir}/config.inc.php
	sed -i "/blowfish_secret/s/''/'$(pwgen -s 32 1)'/" ${PhpMyAdm_dir}/config.inc.php
	chmod 660 ${PhpMyAdm_dir}/config.inc.php
	#mkdir ${PhpMyAdm_dir}/tmp
	#chmod 777 ${PhpMyAdm_dir}/tmp
	chown -R ${webUser}:${webUser} ${PhpMyAdm_dir}
	[ "${selinux_enabled}" = "yes" ] && config_selinux ${PhpMyAdm_dir}
fi
}

# Настройка MariaDB
config_mariadb() {
[ ! -s /root/.my.cnf -a -z $(echo "QUIT" | mysql -u root) ] && case ${osLike} in
"rhel")
	/usr/bin/mysqladmin -u root password "${mypwddb}"
	RootMyCnf "${mypwddb}"
	echo "DELETE FROM user WHERE Password='';" | mysql --defaults-file=/root/.my.cnf -N mysql
	;;
"debian")
	/usr/bin/mysqladmin -u root password "${mypwddb}"
	RootMyCnf "${mypwddb}"
	echo "mariadb-server mariadb-server/root_password password ${mypwddb}" | debconf-set-selections
	echo "mariadb-server mariadb-server/root_password_again password ${mypwddb}" | debconf-set-selections
	systemctl restart mariadb.service
	;;
esac
}

# Настройка Nginx
config_nginx() {
[ -f /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default
[ -f /etc/nginx/conf.d/default.conf ] && rm -f /etc/nginx/conf.d/default.conf
systemctl enable nginx
systemctl restart nginx
}

# Настройка Apache2
config_apache() {
systemctl enable ${webServer}.service
systemctl restart ${webServer}.service
}

# Настройка PhpMyAdmin
config_phpmysqladmin() {
if [ -f ${webServerSiteDir}/phpMyAdmin.conf ]; then
	cat > /tmp/sed.$$ << EOF
/<Directory \/usr\/share\/phpMyAdmin\/>/,/<\/Directory>/ {
    /<RequireAny>/,/<\/RequireAny>/d;
    /<IfModule !mod_authz_core.c>/,/<\/IfModule>/s/Deny from All/Allow from All/g;
    /<IfModule mod_authz_core.c>/a\\\tRequire all granted 
};
/<Directory \/usr\/share\/phpMyAdmin\/setup\/>/,/<\/Directory>/ {
    /<IfModule mod_authz_core.c>/a\\\tRequire all denied
    /<RequireAny>/,/<\/RequireAny>/d;
    /<IfModule !mod_authz_core.c>/,/<\/IfModule>/{ /Allow from/d}
}
EOF
	sed -i -r -f /tmp/sed.$$ /etc/httpd/conf.d/phpMyAdmin.conf
else
	cat << EOF > ${webServerSiteDir}/phpmyadmin.conf
Alias /phpmyadmin ${PhpMyAdm_dir}

<Directory ${PhpMyAdm_dir}/>
   AddDefaultCharset UTF-8

   <IfModule mod_authz_core.c>
     # Apache 2.4
     <RequireAny>
      Require all granted
     </RequireAny>
   </IfModule>
   <IfModule !mod_authz_core.c>
     # Apache 2.2
     Order Deny,Allow
     Deny from All
     Allow from 127.0.0.1
     Allow from ::1
   </IfModule>
</Directory>

<Directory ${PhpMyAdm_dir}/setup/>
   <IfModule mod_authz_core.c>
     # Apache 2.4
     <RequireAny>
       Require all granted
     </RequireAny>
   </IfModule>
   <IfModule !mod_authz_core.c>
     # Apache 2.2
     Order Deny,Allow
     Deny from All
     Allow from 127.0.0.1
     Allow from ::1
   </IfModule>
</Directory>
EOF
fi
[ "${osLike}" = "debian" ] && a2ensite phpmyadmin.conf
}

install_soft
config_system
install_mariadb
install_web
install_nginx
install_php
install_phpmyadmin
config_mariadb
config_phpmysqladmin
config_apache
config_nginx
config_firewall

# Включаем обратно сервис самообновления Ubuntu
[ -n "${unattServ}" ] && systemctl start unattended-upgrades.service

# Проверка
q=0
i=20
while [ $q -le $i ]; do
	curl -v --silent  http://127.0.0.1/phpmyadmin/ 2>&1 | grep -q "phpMyAdmin" && final_text && exit 0
	q=$(($q + 1))
	sleep 1
done

exit 1
