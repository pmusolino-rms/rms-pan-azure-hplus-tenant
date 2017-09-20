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
PAN_VERSION="latest"
PAN_SKU="byol"
STORAGE_SKU="Standard_LRS"
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
VFW_SIZE="Standard_D3_v2"

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
vnet_string=$($AZ network vnet list | grep $tenantID | grep $region | grep id | grep -e Sub[1,8])
if [ -z "${vnet_string}" ]; then 
	echo "Could not find a network in $region with tenant id $tenantID.  Exiting..."
	$AZ logout
	exit 1
fi
vnet_array=()
while read -r line; do
	vnet_array+=("$line")
done <<< "$vnet_string"

IFS=/
#The relevant indexes are 4, 8, 10 which are RG, VNET, and SUBNET respectively
read -a vnet_vars <<< "${vnet_array[0]}"
vnet_rg=${vnet_vars[4]}
vnet_name=${vnet_vars[8]}
vnet_name_sub1=$(echo ${vnet_vars[10]} | cut -d\" -f1)
read -a vnet_vars <<< "${vnet_array[1]}"
vnet_name_sub8=$(echo ${vnet_vars[10]} | cut -d\" -f1)
unset IFS
vnet_name_sub_pre=$(sed 's/.\{1\}$//' <<< "$vnet_name_sub1")
#Get Subnet1 info to determine /21 starting range
vnet_sub1_range=$($AZ network vnet subnet show -n $vnet_name_sub1 --resource-group $vnet_rg --vnet-name $vnet_name | grep Prefix |cut -f4 -d\" | cut -f 1 -d/)
vnet_sub8_range=$($AZ network vnet subnet show -n $vnet_name_sub8 --resource-group $vnet_rg --vnet-name $vnet_name | grep Prefix |cut -f4 -d\" | cut -f 1 -d/)
vnet_sub8_net=$(sed 's/.\{2\}$//' <<< "$vnet_sub8_range")
vnet_tenant_supernet="$vnet_sub1_range/21"
vnet_prefix=$($AZ network vnet show -n $vnet_name -g $vnet_rg --query [addressSpace.addressPrefixes] | grep '/')
vnet_prefix=$(echo $vnet_prefix | sed -e 's/^"//' -e 's/"$//')
$DIALOG --title "Confirm" --backtitle "Azure VPAN Creation" --yesno "Region: ${region}, Tenant: ${tenantID}, RG: ${vnet_rg},\nVnet: ${vnet_name}, IP Space ${vnet_tenant_supernet}" 7 60
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
touch $LOCALHOST_VARS
echo "---" > $LOCALHOST_VARS

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

VFW_INVENTORY="./ansible/hosts/inventory"
touch $VFW_INVENTORY
echo "$VFW_FQDN" > $VFW_INVENTORY
cd ansible
# Delete old subnet - check if exists first
#echo "Deleting subnet 8"
#$AZ network vnet subnet delete -n $vnet_name_sub8 -g $vnet_rg --vnet-name $vnet_name 

# Create new subnets - check if exists first
#echo 'Recreating Subnets as /28s'
#mgmt_create=$($AZ network vnet subnet create -g $vnet_rg --vnet-name $vnet_name -n $VFW_MGMT_NAME --address-prefix "$VFW_MGMT_PREFIX")
#untrust_create=$($AZ network vnet subnet create -g $vnet_rg --vnet-name $vnet_name -n $VFW_UNTRUST_NAME --address-prefix "$VFW_UNTRUST_PREFIX")
#trust_create=$($AZ network vnet subnet create -g $vnet_rg --vnet-name $vnet_name -n $VFW_TRUST_NAME --address-prefix "$VFW_TRUST_PREFIX")

# Create Resource group
#echo "Creating RG $VFW_RG"
#az group create --location $location -n $VFW_RG
# Create Storage account
#echo "Creating Storage account $VFW_STORAGE"
#storage_create=$($AZ storage account create -l $location -n $VFW_STORAGE -g $VFW_RG --sku $STORAGE_SKU)
#Deploy VM using local AzureDeploy.json file.  Could also use a URI including new Azure template storage which is currently in Preview
#echo "Starting deployment..."
#$AZ group deployment create -g $VFW_RG --template-file AzureDeploy.json --parameters '{
#	"vmName": {"value": "'$VFW_NAME'"},
#	"storageAccountName": {"value": "'$VFW_STORAGE'"},
#	"storageAccountExistingRG": {"value": "'$VFW_RG'"},
#	"vmSize": {"value": "'$VFW_SIZE'"},
#	"imageVersion": {"value": "'$PAN_VERSION'"},
#	"imageSku": {"value": "'$PAN_SKU'"},
#	"virtualNetworkName": {"value": "'$vnet_name'"},
#	"virtualNetworkAddressPrefix": {"value": "'$vnet_prefix'"},
#	"virtualNetworkExistingRGName": {"value": "'$vnet_rg'"},
#	"subnet0Name": {"value": "'$VFW_MGMT_NAME'"},
#	"subnet1Name": {"value": "'$VFW_UNTRUST_NAME'"},
#	"subnet2Name": {"value": "'$VFW_TRUST_NAME'"},
#	"subnet0Prefix": {"value": "'$VFW_MGMT_PREFIX'"},
#	"subnet1Prefix": {"value": "'$VFW_UNTRUST_PREFIX'"},
#	"subnet2Prefix": {"value": "'$VFW_TRUST_PREFIX'"},
#	"subnet0StartAddress": {"value": "'$VFW_MGMT_START'"},
#	"subnet1StartAddress": {"value": "'$VFW_UNTRUST_START'"},
#	"subnet2StartAddress": {"value": "'$VFW_TRUST_START'"},
#	"adminUsername": {"value": "'$vpan_admin'"},
#	"adminPassword": {"value": "'$vpan_password'"},
#	"publicIPAddressName": {"value": "'$VFW_MGMT_PUBLIC_IP_DNS'"}
#	}'
#echo "Deployment complete."
# Some logic to quit program if VM not created
# if az resource vm not exist then exit or store above command in variable
# will depend on if adding the $() will cause json formatting issues
# Post Deploy
# Create Untrust Public IP object and associate with untrust network interface
echo "Create public IPs and associate with Untrust"
$AZ network public-ip create --resource-group $VFW_RG -n $VFW_UNTRUST_PUBLIC_IP_DNS --allocation-method static --dns-name $VFW_UNTRUST_PUBLIC_IP_DNS -l $location
$AZ network nic ip-config update -g $VFW_RG --nic-name $VFW_UNTRUST_NIC -n $VFW_UNTRUST_IPCONFIG --public-ip-address $VFW_UNTRUST_PUBLIC_IP_DNS
# Tag VM  - need to figure out what to use for values - from salesforce?
#az resource tag --tags CustomerID=1570 CustomerName="Cloud Operations" Description="Test FW Deploy" EnvironmentType=Internal-Dev Product-Line="Non-RMS(one)" ProductSKU=MGMT ProjectCode="N/A" RequestID="N/A" -g $VFW_RG -n $VFW_NAME --resource-type "Microsoft.Compute/virtualMachines"

# Create inventory if not there and overwrite with current firewall

# Run that playbook
echo "waiting for firewall to finish booting"
sleep 90
echo "Configuring..."
$ANSIBLE_PLAYBOOK basic_network_config.yml -e "vfw_fqdn=$VFW_FQDN"

# Post Config azure routing/acls
#UDRs
echo "Creating UDRs and associating with subnets"
VFW_RT_NAME="$region-TEN$tenantID-RT1"
$AZ network route-table create -n $VFW_RT_NAME -g $vnet_rg -l $location
$AZ network route-table route create --address-prefix $shared_services -n "Shared Services" --next-hop-type "VirtualAppliance" -g $vnet_rg --route-table-name $VFW_RT_NAME --next-hop-ip-address $shared_services_fw
for i in `seq 1 7`
    do
	$AZ network vnet subnet update --route-table $VFW_RT_NAME -g $vnet_rg --vnet-name $vnet_name -n ${vnet_name_sub_pre}${i}
	done

#log out of azure
az logout
exit 0