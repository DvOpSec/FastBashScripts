wget -qO - https://rpms.litespeedtech.com/debian/lst_repo.gpg | sudo apt-key add -
sudo add-apt-repository 'deb http://rpms.litespeedtech.com/debian/ bionic main'
sudo apt install openlitespeed -y
sudo /usr/local/lsws/admin/misc/admpass.sh
