#!/bin/bash

#source variables file - should include 
# username=application-id or username
# password=app or user password
# tenant=application tenant id
# account=optional account/subscription id
# vpan_admin=name of username for firewall
# vpan_password=password for vpan_admin
LOGIN_VARIABLES="./vpan-vars"
DIALOG=`which dialog`
ANSIBLE_PLAYBOOK=`which ansible-playbook`
AZ=`which az`


if ! [ -x "$(command -v dialog)" ]; then
	echo 'Error: dialog not installed.  Please install.' >&2
	exit 1
fi

if ! [ -x "$(command -v ansible-playbook)" ]; then
	echo 'Error: ansible not installed.  Please install.' >&2
	exit 1
fi

if ! [ -x "$(command -v az)" ]; then
	echo 'Error: azure cli 2.0 not installed.  Please install.' >&2
	exit 1
fi

if ! [ -f $LOGIN_VARIABLES ]; then
	echo 'Unable to find Login variables file $LOGIN_VARIABLES'
	exit 1
fi

if ! grep -q -e username -e password -e tenant -e vpan_admin -e vpan_password $LOGIN_VARIABLES; then
	echo "Login variable file is missing either username, password, tenant, or a vpan credentials variable"
	exit 1
fi

source $LOGIN_VARIABLES

region=$($DIALOG --radiolist "Regions" 20 60 12 "CAE" "Canada East" "off" "EUN" "Europe North" "on"  2>&1 > /dev/tty)
region_lower=$(echo "$region" | tr '[:upper:]' '[:lower:]')

tenantID=$($DIALOG --inputbox "Tenant ID:" 20 60 "9999" 2>&1 > /dev/tty)

case "$region" in
	EUN)
		location="northeurope"
		shared_services="10.112.0.0/16"
		shared_services_fw="10.112.0.69"
		;;
	CAE)
		location="canadaeast"
		shared_services="10.114.0.0/16"
        shared_services_fw="10.114.0.69"

		;;
		*) 
		echo "Invalid Input"
		exit 1
		;;
esac
VFW_RG="$region-TEN$tenantID-VFW-RG"
VFW_STORAGE="${region_lower}ten${tenantID}vfw"
VFW_MGMT_PUBLIC_IP_DNS="${region_lower}ten${tenantID}vfw"
VFW_UNTRUST_PUBLIC_IP_DNS="${region_lower}ten${tenantID}vfw-pub"
VFW_NAME="${region_lower}ten${tenantID}vfw"
VFW_MGMT_NAME="$region-TEN$tenantID-Sub8-MGMT"
VFW_UNTRUST_NAME="$region-TEN$tenantID-Sub8-Untrust"
VFW_TRUST_NAME="$region-TEN$tenantID-Sub8-Trust"
VFW_FQDN="$VFW_NAME.$location.cloudapp.azure.com"
VFW_UNTRUST_NIC="$VFW_NAME-eth1"
VFW_UNTRUST_IPCONFIG="ipconfig-untrust"
VFW_NSG="$region-TEN$tenantID-NSG"
VFW_VR="$region-Ten$tenantID-VR"
# Make sure logged out already
echo "Forcing logout of an existing session"
az logout
# Login
login=$($AZ login -u $username --service-principal --tenant $tenant -p $password)
if [ -z "${login}" ]; then
	echo "Failed to log in"
	exit 1
fi
# Set optional account.  This will default to your accounts default subscription set otherwise
if [ -n "${account}" ]; then
	$AZ account set --subscription $account
fi
#Get vnet variables for tenant ID provided and place into an array.
echo "Determining network information"
vnet_string=$($AZ network vnet list | grep $tenantID | grep $region | grep id | grep -e Sub[1,8])
if [ -z "${vnet_string}" ]; then 
	echo "Could not find a network in $region with tenant id $tenantID.  Exiting..."
	$AZ logout
	exit 1
fi
if [ -z "${account}" ]; then
    account=$(echo $vnet_string | cut -d: -f2 | cut -d/ -f3)
	$AZ account set --subscription $account
fi
subscription_name=$($AZ account show -s $account -o tsv | cut -f 4)
vnet_array=()
while read -r line; do
	vnet_array+=("$line")
done <<< "$vnet_string"

IFS=/
#The relevant indexes are 4, 8, 10 which are RG, VNET, and SUBNET respectively
read -a vnet_vars <<< "${vnet_array[0]}"
vnet_rg=${vnet_vars[4]}
vnet_name=${vnet_vars[8]}
vnet_name_sub=$(echo ${vnet_vars[10]} | cut -d\" -f1 | cut -d'-' -f1-3)
declare -a vnet_subnets
vnet_subnets+=("$vnet_name_sub")
read -a vnet_vars <<< "${vnet_array[1]}"
vnet_name_sub=$(echo ${vnet_vars[10]} | cut -d\" -f1 | cut -d'-' -f1-3)
vnet_subnets+=("$vnet_name_sub")
IFS=$'\n' sorted_subnets=($(sort <<< "${vnet_subnets[*]}"))
unset IFS
vnet_name_sub1=${sorted_subnets[0]}
vnet_name_sub8=${sorted_subnets[1]}

vnet_name_sub_pre=$(sed 's/.\{1\}$//' <<< "${vnet_name_sub1}")
#Get Subnet1 info to determine /21 starting range
vnet_sub1_range=$($AZ network vnet subnet show -n $vnet_name_sub1 --resource-group $vnet_rg --vnet-name $vnet_name | grep Prefix |cut -f4 -d\" | cut -f 1 -d/)
vnet_tenant_supernet="$vnet_sub1_range/21"
classb=$(echo $vnet_sub1_range | cut -d. -f1-2)
thrid_octet=$(echo $vnet_sub1_range | cut -d. -f3)
sub8_octet=$(( $third_octet + 7 ))
vnet_sub8_range=$($AZ network vnet subnet show -n $vnet_name_sub8 --resource-group $vnet_rg --vnet-name $vnet_name | grep Prefix |cut -f4 -d\" | cut -f 1 -d/)
vnet_sub8_net=$(sed 's/.\{2\}$//' <<< "$vnet_sub8_range")
if [ -z "${vnet_sub8_net}" ]; then
    vnet_sub8_net=${classb}.${sub8_octet}
fi
vnet_prefix=$($AZ network vnet show -n $vnet_name -g $vnet_rg --query [addressSpace.addressPrefixes] | grep '/')
vnet_prefix=$(echo $vnet_prefix | sed -e 's/^"//' -e 's/"$//')
$DIALOG --title "Confirm" --backtitle "Azure VPAN Creation" --yesno "Region: ${region}, Tenant: ${tenantID}, RG: ${vnet_rg},\nVnet: ${vnet_name}, IP Space ${vnet_tenant_supernet}, Subscription: ${subscription_name}" 7 60
response=$?
case $response in
    0) 
	    echo "Continuing..."
		;;
	1) 
	    echo "Not continuing"
		$AZ logout
		exit 1
		;;
	255)
	    echo "Escaped out"
		$AZ logout
		exit 1
		;;
esac
# Prefixes
VFW_MGMT_PREFIX="$vnet_sub8_net.0/28"
VFW_UNTRUST_PREFIX="$vnet_sub8_net.16/28"
VFW_TRUST_PREFIX="$vnet_sub8_net.32/28"
#Define Subnet ip information based off values obtained above
VFW_MGMT_START="$vnet_sub8_net.4"
VFW_UNTRUST_START="$vnet_sub8_net.20"
VFW_TRUST_START="$vnet_sub8_net.36"
VFW_UNTRUST_NEXTHOP="$vnet_sub8_net.17"
VFW_TRUST_NEXTHOP="$vnet_sub8_net.33"
#Set up ansible host vars
# create and echo variables into host_vars/$VFW_NAME.FQDN
echo "Starting Ansible configuration"
LOCALHOST_VARS="./ansible/host_vars/localhost"
VFW_HOST_VARS="./ansible/host_vars/$VFW_FQDN"
ALL_VARS="./ansible/group_vars/all"
touch $ALL_VARS
touch $LOCALHOST_VARS
echo "---" > $LOCALHOST_VARS
echo "tenant_subnet8: $vnet_name_sub8" >> $LOCALHOST_VARS
echo "tenant_vnet: $vnet_name" >> $LOCALHOST_VARS
echo "tenant_rg: $vnet_rg" >> $LOCALHOST_VARS
echo "subnets:" >> $LOCALHOST_VARS
echo "    - { name: $VFW_MGMT_NAME, prefix: $VFW_MGMT_PREFIX }" >> $LOCALHOST_VARS
echo "    - { name: $VFW_UNTRUST_NAME, prefix: $VFW_UNTRUST_PREFIX }" >> $LOCALHOST_VARS
echo "    - { name: $VFW_TRUST_NAME, prefix: $VFW_TRUST_PREFIX }" >> $LOCALHOST_VARS
echo "location: $location" >> $LOCALHOST_VARS
echo "vfw_rg: $VFW_RG" >> $LOCALHOST_VARS
echo "vfw_sa: $VFW_STORAGE" >> $LOCALHOST_VARS
echo "tenant_prefix: $vnet_prefix" >> $LOCALHOST_VARS
echo "tenant_vfw_mgmt: $VFW_MGMT_NAME" >> $LOCALHOST_VARS
echo "tenant_vfw_untrust: $VFW_UNTRUST_NAME" >> $LOCALHOST_VARS
echo "tenant_vfw_trust: $VFW_TRUST_NAME" >> $LOCALHOST_VARS
echo "tenant_vfw_mgmt_prefix: $VFW_MGMT_PREFIX" >> $LOCALHOST_VARS
echo "tenant_vfw_untrust_prefix: $VFW_UNTRUST_PREFIX" >> $LOCALHOST_VARS
echo "tenant_vfw_trust_prefix: $VFW_TRUST_PREFIX" >> $LOCALHOST_VARS
echo "vfw_mgmt_ip: $VFW_MGMT_START" >> $LOCALHOST_VARS
echo "vfw_untrust_ip: $VFW_UNTRUST_START" >> $LOCALHOST_VARS
echo "vfw_trust_ip: $VFW_TRUST_START" >> $LOCALHOST_VARS
echo "vpan_name: $VFW_NAME" >> $LOCALHOST_VARS
echo "vfw_untrust_ip_dns: $VFW_UNTRUST_PUBLIC_IP_DNS"  >> $LOCALHOST_VARS
echo "vfw_untrust_ipconfig: $VFW_UNTRUST_IPCONFIG" >> $LOCALHOST_VARS
echo "vfw_untrust_nic: $VFW_UNTRUST_NIC" >> $LOCALHOST_VARS
echo "client_id: $username" >> $LOCALHOST_VARS
echo "tenant: $tenant" >> $LOCALHOST_VARS
echo "secret: $password" >> $LOCALHOST_VARS
echo "subscription_id: $account" >> $LOCALHOST_VARS

touch $VFW_HOST_VARS
echo "---" > $VFW_HOST_VARS
echo "vpan_name: $VFW_NAME" >> $VFW_HOST_VARS
echo "vfw_fqdn: $VFW_FQDN" >> $VFW_HOST_VARS
echo "region: $region">> $VFW_HOST_VARS
echo "vfw_tenant_id: $tenantID" >> $VFW_HOST_VARS
echo "vfw_tenant_supernet: $vnet_tenant_supernet" >> $VFW_HOST_VARS
echo "vfw_tenant_nexthop: $VFW_TRUST_NEXTHOP" >> $VFW_HOST_VARS
echo "vfw_default_nexthop: $VFW_UNTRUST_NEXTHOP" >> $VFW_HOST_VARS
echo "vfw_untrust_ip: $VFW_UNTRUST_START" >> $VFW_HOST_VARS
echo "vfw_trust_ip: $VFW_TRUST_START" >> $VFW_HOST_VARS
echo "vfw_rg: $VFW_RG" >> $VFW_HOST_VARS
echo "vfw_nsg: $VFW_NSG" >> $VFW_HOST_VARS
echo "vfw_vr: $VFW_VR" >> $VFW_HOST_VARS

VFW_INVENTORY="./ansible/hosts/inventory"
touch $VFW_INVENTORY
echo "$VFW_FQDN" > $VFW_INVENTORY
#if ansible dir exists
cd ansible

$ANSIBLE_PLAYBOOK basic_network_config.yml -e "vfw_fqdn=$VFW_FQDN"
echo "associate Public IP with Untrust"
nic=$AZ network nic ip-config update -g $VFW_RG --nic-name $VFW_UNTRUST_NIC -n $VFW_UNTRUST_IPCONFIG --public-ip-address $VFW_UNTRUST_PUBLIC_IP_DNS
# Tag VM  - need to figure out what to use for values - from salesforce?
#az resource tag --tags CustomerID=1570 CustomerName="Cloud Operations" Description="Test FW Deploy" EnvironmentType=Internal-Dev Product-Line="Non-RMS(one)" ProductSKU=MGMT ProjectCode="N/A" RequestID="N/A" -g $VFW_RG -n $VFW_NAME --resource-type "Microsoft.Compute/virtualMachines"

# Post Config azure routing/acls
# Not supported by Azure Ansible Yet
#UDRs
echo "Creating UDRs and associating with subnets"
VFW_RT_NAME="$region-TEN$tenantID-RT1"
rt_create=$AZ network route-table create -n $VFW_RT_NAME -g $VFW_RG -l $location
rt_add=$AZ network route-table route create --address-prefix $shared_services -n "Shared Services" --next-hop-type "VirtualAppliance" -g $VFW_RG --route-table-name $VFW_RT_NAME --next-hop-ip-address $shared_services_fw
#grab route table ID
route_id=$(az network route-table show -n $VFW_RT_NAME -g $VFW_RG -o tsv | cut -f2)
for i in `seq 1 7`
    do
	$AZ network vnet subnet update --route-table $route_id -g $vnet_rg --vnet-name $vnet_name -n ${vnet_name_sub_pre}${i}
	done

#log out of azure
az logout
exit 0