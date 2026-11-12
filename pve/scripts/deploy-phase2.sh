#!/bin/bash
set -u
export HOME=/home/ubuntu PATH=/snap/bin:/usr/bin:/bin J=/snap/bin/juju
M="-m openstack"

dep() {
  local app=$1; shift
  if $J list-applications $M 2>/dev/null | grep -q "^$app[[:space:]]"; then
    echo "SKIP $app"
  else
    echo "DEPLOY $app"
    $J deploy "${@}" 2>&1 | tail -1
  fi
}

dep ceph-mon ceph-mon --series focal --channel octopus/stable --revision 177 --num-units 1 --to 9 \
  --config 'expected-osd-count=2' --config 'monitor-count=1' --config 'source=distro' \
  --config 'ceph-public-network=192.168.13.0/24' --config 'ceph-cluster-network=192.168.14.0/24' -m openstack
dep ceph-osd ceph-osd --series focal --channel octopus/stable --revision 617 --num-units 2 --to '0,1' \
  --config 'osd-devices=/dev/osd-block' --config 'source=distro' \
  --config 'ceph-public-network=192.168.13.0/24' --config 'ceph-cluster-network=192.168.14.0/24' -m openstack
dep ceph-fs ceph-fs --series focal --channel octopus/stable --revision 45 --num-units 1 --to 25 \
  --config 'ceph-osd-replication-count=2' -m openstack
dep ceph-radosgw ceph-radosgw --series focal --channel octopus/stable --revision 543 --num-units 1 --to 24 -m openstack
dep nova-compute nova-compute --series focal --channel ussuri/stable --revision 779 --num-units 2 --to '0,1' \
  --config 'config-flags=default_ephemeral_format=ext4' --config 'enable-live-migration=true' \
  --config 'enable-resize=true' --config 'migration-auth-type=ssh' --config 'virt-type=qemu' -m openstack
dep nova-compute-kvm nova-compute --series focal --channel ussuri/stable --revision 779 --num-units 1 --to 23 \
  --config 'config-flags=default_ephemeral_format=ext4' --config 'enable-live-migration=true' \
  --config 'enable-resize=true' --config 'migration-auth-type=ssh' --config 'use-internal-endpoints=true' -m openstack
dep ovn-chassis ovn-chassis --series focal --channel 20.03/stable --revision 321 \
  --config 'ovn-bridge-mappings=physnet1:br-ex' \
  --config 'bridge-interface-mappings=br-ex:ens22' -m openstack

echo "--- wait 30s ---"; sleep 30
rel() { echo "REL $1 <-> $2"; $J add-relation -m openstack "$1" "$2" 2>&1 | tail -1; }

rel 'ceph-osd:mon' 'ceph-mon:osd'
rel 'ceph-fs:ceph-mds' 'ceph-mon:mds'
rel 'ceph-radosgw:mon' 'ceph-mon:radosgw'
rel 'ceph-radosgw:identity-service' 'keystone:identity-service'
rel 'ceph-fs:certificates' 'vault:certificates'
rel 'ceph-radosgw:certificates' 'vault:certificates'
rel 'ceph-mon:client' 'glance:ceph'
rel 'ceph-mon:client' 'nova-compute:ceph'
rel 'ceph-mon:client' 'nova-compute-kvm:ceph'
rel 'nova-compute:amqp' 'rabbitmq-server:amqp'
rel 'nova-compute:image-service' 'glance:image-service'
rel 'nova-compute:cloud-compute' 'nova-cloud-controller:cloud-compute'
rel 'nova-compute-kvm:amqp' 'rabbitmq-server:amqp'
rel 'nova-compute-kvm:image-service' 'glance:image-service'
rel 'nova-compute-kvm:cloud-compute' 'nova-cloud-controller:cloud-compute'
rel 'nova-compute-kvm:cloud-credentials' 'keystone:identity-credentials'
rel 'ovn-chassis:nova-compute' 'nova-compute:neutron-plugin'
rel 'ovn-chassis:nova-compute' 'nova-compute-kvm:neutron-plugin'
rel 'ovn-chassis:certificates' 'vault:certificates'
rel 'ovn-chassis:ovsdb' 'ovn-central:ovsdb'
rel 'ntp:juju-info' 'nova-compute:juju-info'
rel 'ntp:juju-info' 'nova-compute-kvm:juju-info'
rel 'nrpe:general-info' 'nova-compute:juju-info'
rel 'nrpe:general-info' 'nova-compute-kvm:juju-info'
rel 'nrpe:general-info' 'ceph-osd:juju-info'
rel 'nrpe:general-info' 'ceph-mon:juju-info'
rel 'nova-compute:nrpe-external-master' 'nrpe:nrpe-external-master'
rel 'nova-compute-kvm:nrpe-external-master' 'nrpe:nrpe-external-master'
rel 'ceph-mon:nrpe-external-master' 'nrpe:nrpe-external-master'
rel 'ceph-osd:nrpe-external-master' 'nrpe:nrpe-external-master'
echo DEPLOY-PHASE2-DONE
