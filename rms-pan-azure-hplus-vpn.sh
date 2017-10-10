#!/bin/bash
VARS_FILES=ansible/roles/pan-vpn-creator/vars
LOGIN_VARIABLES="./vpan-vars"
DIALOG=`which dialog`
ANSIBLE_PLAYBOOK=`which ansible-playbook`
AZ=`which az`

function get_routes {
    c=true
    list=()
    while $c; do 
        a=$(dialog --inputbox "Route:" 20 60 "" 2>&1 > /dev/tty);
        if [ -z "${a}" ]; then
            c=false;
        else 
            list+=("$a"); 
        fi; 
    done

    echo "---" > $VARS_FILES/main.yml
    echo "routes:" >> $VARS_FILES/main.yml
    for i in ${list[@]}; do
        echo "- $i" >> $VARS_FILES/main.yml
    done
}

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
		;;
	CAE)
		location="canadaeast"
		;;
		*) 
		echo "Invalid Input"
		exit 1
		;;
esac
VFW_RG="$region-TEN$tenantID-VFW-RG"
VFW_NAME="${region_lower}ten${tenantID}vfw"
VFW_FQDN="$VFW_NAME.$location.cloudapp.azure.com"
VFW_NSG="$region-TEN$tenantID-NSG"
VFW_VR="$region-Ten$tenantID-VR"



get_route=true
if [ $# -eq 1 ]; then
    get_route=false
    cp $1 $VARS_FILES/main.yml
fi

while $get_route; do
    get_routes
    dialog --title "Is this correct" --yesno "$(cat $VARS_FILES/main.yml)" 20 60;
    response=$?
    case $response in
        0)
            clear
            echo "continuing"
            get_route=false
            ;;
        1)
            clear
            echo "Trying again"
            ;;
        255)
            clear
            echo "Escaping"
            exit 1
            ;;
    esac
done

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
vnet_name_sub1=$(echo ${vnet_vars[10]} | cut -d\" -f1)
read -a vnet_vars <<< "${vnet_array[1]}"
unset IFS
vnet_name_sub_pre=$(sed 's/.\{1\}$//' <<< "$vnet_name_sub1")
#Get Subnet1 info to determine /21 starting range
vnet_sub1_range=$($AZ network vnet subnet show -n $vnet_name_sub1 --resource-group $vnet_rg --vnet-name $vnet_name | grep Prefix |cut -f4 -d\" | cut -f 1 -d/)
vnet_tenant_supernet="$vnet_sub1_range/21"

LOCALHOST_VARS="./ansible/host_vars/localhost"
touch $LOCALHOST_VARS
echo "---" > $LOCALHOST_VARS
echo "vfw_rg: $VFW_RG" >> $LOCALHOST_VARS
echo "vfw_nsg: $VFW_NSG" >> $LOCALHOST_VARS
echo "vfw_fqdn: $VFW_FQDN" >> $LOCALHOST_VARS
echo "vfw_vr: $VFW_VR" >> $LOCALHOST_VARS
echo "vpan_name: $VFW_NAME" >> $LOCALHOST_VARS
echo "vfw_tenant_supernet: $vnet_tenant_supernet" >> $LOCALHOST_VARS
echo "client_id: $username" >> $LOCALHOST_VARS
echo "tenant: $tenant" >> $LOCALHOST_VARS
echo "secret: $password" >> $LOCALHOST_VARS
echo "subscription_id: $account" >> $LOCALHOST_VARS

VFW_INVENTORY="./ansible/hosts/inventory"
touch $VFW_INVENTORY
echo "$VFW_FQDN" > $VFW_INVENTORY
#if ansible dir exists
cd ansible
$ANSIBLE_PLAYBOOK basic_vpn_config.yml

exit 0