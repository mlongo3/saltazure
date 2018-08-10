#!/bin/bash

echo $(date +"%F %T%z") "starting script saltstackinstall.sh"

# arguments
adminUsername=${1}
adminPassword=${2}
storageName=${3}
vnetName=${4}
subnetName=${5}
clientid=${6}
secret=${7}
tenantid=${8}
nsgname=${9}
ingestionkey=${10}

echo "----------------------------------"
echo "INSTALLING SALT"
echo "----------------------------------"

curl -s -o $HOME/bootstrap_salt.sh -L https://bootstrap.saltstack.com
sh $HOME/bootstrap_salt.sh -M -p python-pip git 2017.7

easy_install-2.7 pip==9.0.1
yum install -y gcc gcc-c++ git make libffi-devel openssl-devel python-devel
curl -s -o $HOME/requirements.txt -L https://raw.githubusercontent.com/mlongo3/saltazure/master/requirements.txt
pip install -r $HOME/requirements.txt

vmPrivateIpAddress=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?api-version=2017-08-01&format=text")
vmLocation=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/location?api-version=2017-08-01&format=text")
resourceGroupName=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/resourceGroupName?api-version=2017-08-01&format=text")
subscriptionId=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/subscriptionId?api-version=2017-08-01&format=text")

echo "----------------------------------"
echo "CONFIGURING SALT-MASTER"
echo "----------------------------------"

# Configure state paths
echo "
interface: ${vmPrivateIpAddress}
file_roots:
  base:
    - /srv/salt
" | tee --append /etc/salt/master

systemctl restart salt-master.service
systemctl enable salt-master.service
salt-cloud -u

echo "----------------------------------"
echo "CONFIGURING SALT-CLOUD"
echo "----------------------------------"

# cloud providers
mkdir -p /etc/salt/cloud.providers.d
echo "
azurearm-conf:
  driver: azurearm
  subscription_id: $subscriptionId
  client_id: $clientid
  secret: $secret
  tenant: $tenantid
  grains:
    home: /home/$adminUsername
    provider: azure
    user: $adminUsername
" | tee /etc/salt/cloud.providers.d/azure.conf

# cloud profiles
mkdir -p /etc/salt/cloud.profiles.d
echo "
azure-vm:
  provider: azurearm-conf
  image: Canonical|UbuntuServer|18.04-LTS|18.04.201808080
  size: Standard_B1s
  location: ${vmLocation}
  ssh_username: $adminUsername
  ssh_password: $adminPassword
  storage_account: $storageName
  resource_group: ${resourceGroupName}
  security_group: $nsgname
  network_resource_group: ${resourceGroupName}
  network: $vnetName
  subnet: $subnetName
  public_ip: True
  minion:
    master: ${vmPrivateIpAddress}
    tcp_keepalive: True
    tcp_keepalive_idle: 180

azure-vm-esnode:
  extends: azure-vm
  size: Standard_B1s
  volumes:
    - {disk_size_gb: 50, name: 'datadisk1' }
  minion:
    grains:
      region: $vmLocation      

azure-vm-esmaster:
  extends: azure-vm
  size: Standard_B1s
  volumes:
    - {disk_size_gb: 50, name: 'datadisk1' }
  minion:
    grains:
      region: $vmLocation      
" | tee /etc/salt/cloud.profiles.d/azure.conf

# map file
mkdir /etc/salt/cloud.maps.d
echo "
azure-vm-esmaster:
  - ${resourceGroupName}-esmaster

azure-vm-esnode:
  - ${resourceGroupName}-esnode
" | tee /etc/salt/cloud.maps.d/azure-es-cluster.conf

echo "----------------------------------"
echo "PROVISION MACHINES WITH SALT-CLOUD"
echo "----------------------------------"

salt-cloud -m /etc/salt/cloud.maps.d/azure-es-cluster.conf -P -y

echo "----------------------------------"
echo "CONFIGURING ELASTICSEARCH"
echo "----------------------------------"

mkdir -p /srv/salt
echo "
base:
  '*':
    - common_packages    
" | tee /srv/salt/top.sls

echo "
common_packages:
    pkg.installed:
        - names:
            - git
            - tmux
            - tree
" | tee /srv/salt/common_packages.sls


echo $(date +"%F %T%z") "ending script saltstackinstall.sh"
