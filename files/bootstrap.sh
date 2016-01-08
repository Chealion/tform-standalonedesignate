#! /bin/bash +x

# Install prereqs
export DEBIAN_FRONTEND=noninteractive

#/usr/local/bin/localSUS && /usr/local/bin/enableAutoUpdate && apt-get -y upgrade
/usr/local/bin/localSUS && /usr/local/bin/enableAutoUpdate

apt-get install -y python-software-properties software-properties-common
add-apt-repository -y cloud-archive:liberty

# Install Rabbit first - normally taken care of by Puppet
# Rabbit 3.4.4 (RAC)
wget https://www.rabbitmq.com/releases/rabbitmq-server/v3.4.4/rabbitmq-server_3.4.4-1_all.deb -O rabbitmq.deb
# Rabbit 3.5.7 (LMC)
# wget https://www.rabbitmq.com/releases/rabbitmq-server/v3.5.7/rabbitmq-server_3.5.7-1_all.deb -O rabbitmq.deb
dpkg -i rabbitmq.deb
apt-get install -yf

apt-get update

export MYSQL_PASSWORD="openstack"

sudo debconf-set-selections <<< "mysql-server mysql-server/root_password password ${MYSQL_PASSWORD}"
sudo debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${MYSQL_PASSWORD}"

# Stick with Trusty/Kilo packages for rest of services
apt-get install -y wget apache2 mysql-server keystone openstack-dashboard designate designate-mdns designate-pool-manager designate-zone-manager pdns-server pdns-backend-mysql memcached 
apt-get remove -y openstack-dashboard-ubuntu-theme

# MySQL Databases

mysql -uroot -p${MYSQL_PASSWORD} -e "CREATE DATABASE keystone;"
mysql -uroot -p${MYSQL_PASSWORD} -e "CREATE DATABASE designate;"
#mysql -uroot -p${MYSQL_PASSWORD} -e "CREATE DATABASE designate_pool_manager;"
mysql -uroot -p${MYSQL_PASSWORD} -e "CREATE DATABASE pdns default character set utf8 default collate utf8_general_ci;"

# Create users for MySQL and Rabbit
# Normally taken care of by Puppet
mysql -uroot -p${MYSQL_PASSWORD} -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';"
mysql -uroot -p${MYSQL_PASSWORD} -e "GRANT ALL PRIVILEGES ON designate.* TO 'designate'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';"
#mysql -uroot -p${MYSQL_PASSWORD} -e "GRANT ALL PRIVILEGES ON designate_pool_manager.* TO 'designate'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';"
mysql -uroot -p${MYSQL_PASSWORD} -e "GRANT ALL PRIVILEGES ON pdns.* TO 'pdns'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';"

rabbitmqctl add_vhost openstack
rabbitmqctl add_user keystone ${MYSQL_PASSWORD}
rabbitmqctl add_user designate ${MYSQL_PASSWORD}
rabbitmqctl set_permissions -p openstack keystone ".*" ".*" ".*"
rabbitmqctl set_permissions -p openstack designate ".*" ".*" ".*"

# Load config files
mv /home/ubuntu/files/keystone.conf /etc/keystone/keystone.conf
mv /home/ubuntu/files/designate.conf /etc/designate/designate.conf
mv /home/ubuntu/files/keystone-catalog /etc/keystone/default_catalog.templates
mv /home/ubuntu/files/pdns-gmysql.conf /etc/powerdns/pdns.d/pdns.local.gmysql.conf
mv /home/ubuntu/files/pdns.conf /etc/powerdns/pdns.conf
rm /etc/powerdns/pdns.d/pdns.simplebind.conf

service keystone restart
keystone-manage db_sync


touch /var/log/designate/desigate-api.log
touch /var/log/designate/desigate-central.log
touch /var/log/designate/desigate-manage.log
touch /var/log/designate/desigate-mdns.log
touch /var/log/designate/desigate-pool-manager.log
touch /var/log/designate/desigate-zone-manager.log
chown -R designate:designate /var/log/designate/*

designate-manage database sync
# Sync first database target
designate-manage powerdns sync 0117acbc-3dd6-4555-8d74-bb929df1e26d
service pdns restart
for i in designate-central designate-api; do service $i restart; done
#Pool Manager and mdns aren't in Ubuntu's distro? ugh.
#for i in designate-central designate-api designate-pool-manager designate-mdns; do service $i restart; done

# Create OpenStack Users

export OS_SERVICE_TOKEN=password
export OS_SERVICE_ENDPOINT=http://localhost:35357/v2.0

keystone tenant-create --name admin --description "admin"
keystone tenant-create --name services --description "services"
keystone tenant-create --name gooduser --description "gooduser"
keystone tenant-create --name gooduser2 --description "gooduser2"

keystone user-create --name admin --tenant admin --pass password --email root@localhost
keystone user-create --name gooduser --tenant gooduser --pass password --email root@localhost
keystone user-create --name gooduser2 --tenant gooduser2 --pass password --email root@localhost

keystone user-create --name keystone --tenant services --pass password --email root@localhost
keystone user-create --name designate --tenant services --pass password --email root@localhost

keystone role-create --name admin
keystone role-create --name Member

keystone user-role-add --user admin --role admin --tenant admin
keystone user-role-add --user keystone --role admin --tenant services
keystone user-role-add --user designate --role admin --tenant services

keystone user-role-add --user gooduser --role Member --tenant gooduser
keystone user-role-add --user gooduser2 --role Member --tenant gooduser2

unset OS_SERVICE_TOKEN
unset OS_SERVICE_ENDPOINT

source /home/ubuntu/files/openrc

# Designate initial setup

designate server-create --name ns.standalone.cybera.ca. 

#Horizon plugin

apt-get install -y python-pip git python-tox python-dev python3-dev

git clone https://github.com/openstack/designate-dashboard
cd designate-dashboard
git checkout stable/liberty
pip install -r requirements.txt --allow-all-external
tox -evenv -- python setup.py sdist
pip install dist/*.tar.gz
cp designatedashboard/enabled/_70_dns_add_group.py /usr/share/openstack-dashboard/openstack_dashboard/local/enabled
cp designatedashboard/enabled/_71_dns_project.py /usr/share/openstack-dashboard/openstack_dashboard/local/enabled
# Screw you pbr - per http://eavesdrop.openstack.org/irclogs/%23openstack-dns/%23openstack-dns.2015-09-14.log.html
echo '' > /usr/local/lib/python2.7/dist-packages/designatedashboard/__init__.py
service apache2 restart

# Add lines to /usr/share/openstack-dashboard/openstack_dashboard/settings.py!!!
mv /home/ubuntu/files/horizonsettings.py /usr/share/openstack-dashboard/settings.py
