#!/bin/bash
set -u
: "${KEYSTONE_ADMIN_PASSWORD:?Set KEYSTONE_ADMIN_PASSWORD before running this archived deployment script}"
export HOME=/root PATH=/snap/bin:/usr/bin:/bin J=/snap/bin/juju
if $J list-applications -m openstack 2>/dev/null | grep -q "^dashboard-mysql-router[[:space:]]"; then
  echo "SKIP dashboard-mysql-router"
else
  echo "DEPLOY dashboard-mysql-router"
  $J deploy mysql-router dashboard-mysql-router --series focal --channel 8.0/stable --revision 257 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^glance[[:space:]]"; then
  echo "SKIP glance"
else
  echo "DEPLOY glance"
  $J deploy glance glance --series focal --channel ussuri/stable --revision 589 --num-units 1 --to 12 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^glance-mysql-router[[:space:]]"; then
  echo "SKIP glance-mysql-router"
else
  echo "DEPLOY glance-mysql-router"
  $J deploy mysql-router glance-mysql-router --series focal --channel 8.0/stable --revision 257 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^keystone[[:space:]]"; then
  echo "SKIP keystone"
else
  echo "DEPLOY keystone"
  $J deploy keystone keystone --series focal --channel ussuri/stable --revision 691 --num-units 1 --to 5 --config "admin-password=$KEYSTONE_ADMIN_PASSWORD" -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^keystone-mysql-router[[:space:]]"; then
  echo "SKIP keystone-mysql-router"
else
  echo "DEPLOY keystone-mysql-router"
  $J deploy mysql-router keystone-mysql-router --series focal --channel 8.0/stable --revision 257 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^mysql-innodb-cluster[[:space:]]"; then
  echo "SKIP mysql-innodb-cluster"
else
  echo "DEPLOY mysql-innodb-cluster"
  $J deploy mysql-innodb-cluster mysql-innodb-cluster --series focal --channel 8.0/stable --revision 159 --num-units 3 --to '2,3,4' --config 'innodb-buffer-pool-size=256M' -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^neutron-api[[:space:]]"; then
  echo "SKIP neutron-api"
else
  echo "DEPLOY neutron-api"
  $J deploy neutron-api neutron-api --series focal --channel ussuri/stable --revision 588 --num-units 1 --to 10 --config 'dns-domain=test-b.example.com' --config 'enable-ml2-port-security=true' --config 'flat-network-providers=physnet1' --config 'neutron-security-groups=true' -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^neutron-api-plugin-ovn[[:space:]]"; then
  echo "SKIP neutron-api-plugin-ovn"
else
  echo "DEPLOY neutron-api-plugin-ovn"
  $J deploy neutron-api-plugin-ovn neutron-api-plugin-ovn --series focal --channel ussuri/stable --revision 98 --config 'ovn-dhcp4-global-options=' -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^neutron-mysql-router[[:space:]]"; then
  echo "SKIP neutron-mysql-router"
else
  echo "DEPLOY neutron-mysql-router"
  $J deploy mysql-router neutron-mysql-router --series focal --channel 8.0/stable --revision 257 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^nova-cloud-controller[[:space:]]"; then
  echo "SKIP nova-cloud-controller"
else
  echo "DEPLOY nova-cloud-controller"
  $J deploy nova-cloud-controller nova-cloud-controller --series focal --channel ussuri/stable --revision 748 --num-units 1 --to 6 --config 'network-manager=Neutron' -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^nova-mysql-router[[:space:]]"; then
  echo "SKIP nova-mysql-router"
else
  echo "DEPLOY nova-mysql-router"
  $J deploy mysql-router nova-mysql-router --series focal --channel 8.0/stable --revision 257 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^nrpe[[:space:]]"; then
  echo "SKIP nrpe"
else
  echo "DEPLOY nrpe"
  $J deploy nrpe nrpe --series focal --channel stable --revision 157 --config 'nagios_master=192.168.122.53,192.168.165.109' -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^ntp[[:space:]]"; then
  echo "SKIP ntp"
else
  echo "DEPLOY ntp"
  $J deploy ntp ntp --series focal --channel stable --revision 52 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^openstack-dashboard[[:space:]]"; then
  echo "SKIP openstack-dashboard"
else
  echo "DEPLOY openstack-dashboard"
  $J deploy openstack-dashboard openstack-dashboard --series focal --channel ussuri/stable --revision 723 --num-units 1 --to 11 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^ovn-central[[:space:]]"; then
  echo "SKIP ovn-central"
else
  echo "DEPLOY ovn-central"
  $J deploy ovn-central ovn-central --series focal --channel 20.03/stable --revision 35 --num-units 3 --to '8,14,15' -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^placement[[:space:]]"; then
  echo "SKIP placement"
else
  echo "DEPLOY placement"
  $J deploy placement placement --series focal --channel ussuri/stable --revision 99 --num-units 1 --to 13 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^placement-mysql-router[[:space:]]"; then
  echo "SKIP placement-mysql-router"
else
  echo "DEPLOY placement-mysql-router"
  $J deploy mysql-router placement-mysql-router --series focal --channel 8.0/stable --revision 257 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^rabbitmq-server[[:space:]]"; then
  echo "SKIP rabbitmq-server"
else
  echo "DEPLOY rabbitmq-server"
  $J deploy rabbitmq-server rabbitmq-server --series focal --channel 3.8/stable --revision 222 --num-units 1 --to 18 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^vault[[:space:]]"; then
  echo "SKIP vault"
else
  echo "DEPLOY vault"
  $J deploy vault vault --series focal --channel 1.7/stable --revision 371 --num-units 1 --to 7 -m openstack 2>&1 | tail -1
fi
if $J list-applications -m openstack 2>/dev/null | grep -q "^vault-mysql-router[[:space:]]"; then
  echo "SKIP vault-mysql-router"
else
  echo "DEPLOY vault-mysql-router"
  $J deploy mysql-router vault-mysql-router --series focal --channel 8.0/stable --revision 257 -m openstack 2>&1 | tail -1
fi
echo "--- wait 30s ---"; sleep 30
$J add-relation -m openstack 'nova-cloud-controller:identity-service' 'keystone:identity-service' 2>&1 | tail -1
$J add-relation -m openstack 'glance:identity-service' 'keystone:identity-service' 2>&1 | tail -1
$J add-relation -m openstack 'neutron-api:identity-service' 'keystone:identity-service' 2>&1 | tail -1
$J add-relation -m openstack 'neutron-api:amqp' 'rabbitmq-server:amqp' 2>&1 | tail -1
$J add-relation -m openstack 'glance:amqp' 'rabbitmq-server:amqp' 2>&1 | tail -1
$J add-relation -m openstack 'nova-cloud-controller:image-service' 'glance:image-service' 2>&1 | tail -1
$J add-relation -m openstack 'nova-cloud-controller:amqp' 'rabbitmq-server:amqp' 2>&1 | tail -1
$J add-relation -m openstack 'openstack-dashboard:identity-service' 'keystone:identity-service' 2>&1 | tail -1
$J add-relation -m openstack 'nova-cloud-controller:neutron-api' 'neutron-api:neutron-api' 2>&1 | tail -1
$J add-relation -m openstack 'keystone:shared-db' 'keystone-mysql-router:shared-db' 2>&1 | tail -1
$J add-relation -m openstack 'glance:shared-db' 'glance-mysql-router:shared-db' 2>&1 | tail -1
$J add-relation -m openstack 'nova-cloud-controller:shared-db' 'nova-mysql-router:shared-db' 2>&1 | tail -1
$J add-relation -m openstack 'neutron-api:shared-db' 'neutron-mysql-router:shared-db' 2>&1 | tail -1
$J add-relation -m openstack 'openstack-dashboard:shared-db' 'dashboard-mysql-router:shared-db' 2>&1 | tail -1
$J add-relation -m openstack 'vault:shared-db' 'vault-mysql-router:shared-db' 2>&1 | tail -1
$J add-relation -m openstack 'keystone-mysql-router:db-router' 'mysql-innodb-cluster:db-router' 2>&1 | tail -1
$J add-relation -m openstack 'nova-mysql-router:db-router' 'mysql-innodb-cluster:db-router' 2>&1 | tail -1
$J add-relation -m openstack 'glance-mysql-router:db-router' 'mysql-innodb-cluster:db-router' 2>&1 | tail -1
$J add-relation -m openstack 'neutron-mysql-router:db-router' 'mysql-innodb-cluster:db-router' 2>&1 | tail -1
$J add-relation -m openstack 'dashboard-mysql-router:db-router' 'mysql-innodb-cluster:db-router' 2>&1 | tail -1
$J add-relation -m openstack 'vault-mysql-router:db-router' 'mysql-innodb-cluster:db-router' 2>&1 | tail -1
$J add-relation -m openstack 'neutron-api-plugin-ovn:neutron-plugin' 'neutron-api:neutron-plugin-api-subordinate' 2>&1 | tail -1
$J add-relation -m openstack 'ovn-central:certificates' 'vault:certificates' 2>&1 | tail -1
$J add-relation -m openstack 'ovn-central:ovsdb-cms' 'neutron-api-plugin-ovn:ovsdb-cms' 2>&1 | tail -1
$J add-relation -m openstack 'neutron-api:certificates' 'vault:certificates' 2>&1 | tail -1
$J add-relation -m openstack 'vault:certificates' 'neutron-api-plugin-ovn:certificates' 2>&1 | tail -1
$J add-relation -m openstack 'vault:certificates' 'glance:certificates' 2>&1 | tail -1
$J add-relation -m openstack 'vault:certificates' 'keystone:certificates' 2>&1 | tail -1
$J add-relation -m openstack 'vault:certificates' 'nova-cloud-controller:certificates' 2>&1 | tail -1
$J add-relation -m openstack 'vault:certificates' 'openstack-dashboard:certificates' 2>&1 | tail -1
$J add-relation -m openstack 'vault:certificates' 'mysql-innodb-cluster:certificates' 2>&1 | tail -1
$J add-relation -m openstack 'placement-mysql-router:db-router' 'mysql-innodb-cluster:db-router' 2>&1 | tail -1
$J add-relation -m openstack 'placement:shared-db' 'placement-mysql-router:shared-db' 2>&1 | tail -1
$J add-relation -m openstack 'placement:identity-service' 'keystone:identity-service' 2>&1 | tail -1
$J add-relation -m openstack 'placement:certificates' 'vault:certificates' 2>&1 | tail -1
$J add-relation -m openstack 'nova-cloud-controller:placement' 'placement:placement' 2>&1 | tail -1
$J add-relation -m openstack 'nrpe:general-info' 'keystone:juju-info' 2>&1 | tail -1
$J add-relation -m openstack 'nrpe:general-info' 'glance:juju-info' 2>&1 | tail -1
$J add-relation -m openstack 'nrpe:general-info' 'neutron-api:juju-info' 2>&1 | tail -1
$J add-relation -m openstack 'nrpe:general-info' 'nova-cloud-controller:juju-info' 2>&1 | tail -1
$J add-relation -m openstack 'nrpe:general-info' 'rabbitmq-server:juju-info' 2>&1 | tail -1
$J add-relation -m openstack 'nrpe:general-info' 'mysql-innodb-cluster:juju-info' 2>&1 | tail -1
$J add-relation -m openstack 'nrpe:general-info' 'vault:juju-info' 2>&1 | tail -1
$J add-relation -m openstack 'nrpe:general-info' 'openstack-dashboard:juju-info' 2>&1 | tail -1
$J add-relation -m openstack 'nrpe:general-info' 'placement:juju-info' 2>&1 | tail -1
$J add-relation -m openstack 'nrpe:general-info' 'ovn-central:juju-info' 2>&1 | tail -1
$J add-relation -m openstack 'glance:nrpe-external-master' 'nrpe:nrpe-external-master' 2>&1 | tail -1
$J add-relation -m openstack 'keystone:nrpe-external-master' 'nrpe:nrpe-external-master' 2>&1 | tail -1
$J add-relation -m openstack 'neutron-api:nrpe-external-master' 'nrpe:nrpe-external-master' 2>&1 | tail -1
$J add-relation -m openstack 'nova-cloud-controller:nrpe-external-master' 'nrpe:nrpe-external-master' 2>&1 | tail -1
$J add-relation -m openstack 'openstack-dashboard:nrpe-external-master' 'nrpe:nrpe-external-master' 2>&1 | tail -1
$J add-relation -m openstack 'ovn-central:nrpe-external-master' 'nrpe:nrpe-external-master' 2>&1 | tail -1
$J add-relation -m openstack 'rabbitmq-server:nrpe-external-master' 'nrpe:nrpe-external-master' 2>&1 | tail -1
$J add-relation -m openstack 'vault:nrpe-external-master' 'nrpe:nrpe-external-master' 2>&1 | tail -1
echo DEPLOY-SCRIPT-DONE
