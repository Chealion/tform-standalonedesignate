#! /bin/bash +x

# Install prereqs
export DEBIAN_FRONTEND=noninteractive

/usr/local/bin/localSUS && /usr/local/bin/enableAutoUpdate

apt-get install -y python-software-properties software-properties-common
add-apt-repository -y cloud-archive:mitaka

# Install Rabbit first - normally taken care of by Puppet
# Rabbit 3.5.7
wget https://www.rabbitmq.com/releases/rabbitmq-server/v3.5.7/rabbitmq-server_3.5.7-1_all.deb -O rabbitmq.deb
dpkg -i rabbitmq.deb
apt-get install -yf

echo " ====> Rabbit Installed"

apt-get update

export MYSQL_PASSWORD="openstack"

sudo debconf-set-selections <<< "mysql-server mysql-server/root_password password ${MYSQL_PASSWORD}"
sudo debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${MYSQL_PASSWORD}"

#Install Keystone
apt-get install -y wget apache2 mysql-server keystone libapache2-mod-wsgi

echo " ====> Keystone Package Installed"

# Install Horizon, Designate, PDNS
apt-get install -y openstack-dashboard designate designate-mdns designate-pool-manager designate-zone-manager pdns-server pdns-backend-mysql memcached 
apt-get remove -y openstack-dashboard-ubuntu-theme

echo " ====> Other packages Installed"

# MySQL Databases

mysql -uroot -p${MYSQL_PASSWORD} -e "CREATE DATABASE keystone;"
mysql -uroot -p${MYSQL_PASSWORD} -e "CREATE DATABASE designate;"
mysql -uroot -p${MYSQL_PASSWORD} -e "CREATE DATABASE designate_pool_manager;"
mysql -uroot -p${MYSQL_PASSWORD} -e "DROP DATABASE IF EXISTS `pdns`;"
mysql -uroot -p${MYSQL_PASSWORD} -e "CREATE DATABASE pdns default character set utf8 default collate utf8_general_ci;"

# Create users for MySQL and Rabbit
# Normally taken care of by Puppet
mysql -uroot -p${MYSQL_PASSWORD} -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';"
mysql -uroot -p${MYSQL_PASSWORD} -e "GRANT ALL PRIVILEGES ON designate.* TO 'designate'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';"
mysql -uroot -p${MYSQL_PASSWORD} -e "GRANT ALL PRIVILEGES ON designate_pool_manager.* TO 'designate'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';"
mysql -uroot -p${MYSQL_PASSWORD} -e "GRANT ALL PRIVILEGES ON pdns.* TO 'pdns'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';"

rabbitmqctl add_vhost openstack
rabbitmqctl add_user keystone ${MYSQL_PASSWORD}
rabbitmqctl add_user designate ${MYSQL_PASSWORD}
rabbitmqctl set_permissions -p openstack keystone ".*" ".*" ".*"
rabbitmqctl set_permissions -p openstack designate ".*" ".*" ".*"

# Load config files
mv /home/ubuntu/files/keystone.conf /etc/keystone/keystone.conf
mv /home/ubuntu/files/wsgi-keystone.conf /etc/apache2/sites-available/wsgi-keystone.conf
mv /home/ubuntu/files/designate.conf /etc/designate/designate.conf
mv /home/ubuntu/files/pools.yaml /etc/designate/pools.yaml
mv /home/ubuntu/files/keystone-catalog /etc/keystone/default_catalog.templates
mv /home/ubuntu/files/pdns-gmysql.conf /etc/powerdns/pdns.d/pdns.local.gmysql.conf
mv /home/ubuntu/files/pdns.conf /etc/powerdns/pdns.conf
rm /etc/powerdns/pdns.d/pdns.simplebind.conf

ln -s /etc/apache2/sites-available/wsgi-keystone.conf /etc/apache2/sites-enabled

echo " ====> MySQL and file injection"

#echo "ServerName controller" >> /etc/apache2/apache2.conf

# Configure Keystone
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

service pdns restart
for i in api agent central mdns pool-manager; do service designate-$i restart; done

echo " ====> Designate Sync Done"

# Create OpenStack Users

export OS_SERVICE_TOKEN=password
export OS_SERVICE_ENDPOINT=http://localhost:35357/v2.0

keystone-manage bootstrap --bootstrap-password password

unset OS_SERVICE_TOKEN
unset OS_SERVICE_ENDPOINT

source /home/ubuntu/files/openrc

echo " ====> Keystone bootstrap"

#openstack domain create --description "Default Domain" default
#openstack project create --description "admin" admin
openstack project create --description "services" services
openstack project create --description "gooduser" gooduser
openstack project create --description "gooduser2" gooduser2

#openstack user create --project admin --password password --email root@localhost admin
openstack user create --project gooduser --password password --email root@localhost gooduser
openstack user create --project gooduser2 --password password --email root@localhost gooduser2

openstack user create --project services --password password --email root@localhost keystone
openstack user create --project services --password password --email root@localhost designate

#openstack role create admin
openstack role create Member

#openstack role add --project admin --user admin admin
openstack role add --project services --user keystone admin
openstack role add --project services --user designate admin

openstack role add --project gooduser --user gooduser Member
openstack role add --project gooduser2 --user gooduser2 Member

echo " ====> OpenStack users created"

# Designate initial setup
designate-manage pool update --file /etc/designate/pools.yaml
for i in api agent central mdns pool-manager; do service designate-$i restart; done

echo " ====> Pools done"

# Sync first database target
designate-manage powerdns sync 64a70384-7639-4445-ad17-bab5073b8170 

echo " ====> PowerDNS Sync Done"

#Horizon plugin - confirmed broken as on July 5, 2016
apt-get install -y python-pip git python-tox python-dev python3-dev

git clone https://github.com/openstack/designate-dashboard
cd designate-dashboard
git checkout stable/mitaka
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

echo " ====> DONE"
