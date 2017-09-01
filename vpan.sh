#!/bin/bash

#source variables file - should include 
# username = application-id or username
# password = app or user password
# tenant = application tenant id
# account = optional account/subscription id
LOGIN_VARIABLES="./vpan-vars"
DIALOG=`which dialog`

if ! [ -x "$(command -v dialog)" ]; then
	echo 'Error: dialog not installed.  Please install.' >&2
	exit 1
fi

if ! [ -f $LOGIN_VARIABLES ]; then
	echo 'Unable to find Login variables file $LOGIN_VARIABLES'
	exit 1
fi

if ! grep -q -e username -e password -e tenant $LOGIN_VARIABLES; then
	echo "Login variable file is missing either username, password, or tenant variable"
	exit 1
fi

source $LOGIN_VARIABLES


region=$($DIALOG --radiolist "Regions" 20 60 12 "CAE" "Canada East" "off" "EUN" "Europe North" "on"  2>&1 > /dev/tty)
tenantID=$($DIALOG --inputbox "Tenant ID:" 20 60 "9999" 2>&1 > /dev/tty)
# Make sure logged out already
az logout
# Login
login=$(az login -u $username --service-principal --tenant $tenant -p $password)
if [ -z "${login}" ]; then
	echo "Failed to log in"
	exit 1
fi
# Set optional account.  This will default to your accounts default subscription set otherwise
if [ -n "${account}" ]; then
	az account set --subscription $account
fi
#Get vnet variables for tenant ID provided and place into an array.  
vnet_string=$(az network vnet list | grep $tenantID | grep $region | grep id | grep -e Sub8 -e Sub1)
if [ -z "${vnet_string}" ]; then 
	echo "Could not find a network in $region with tenant id $tenantID.  Exiting..."
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
#Get Subnet1 info to determine /21 starting range
vnet_sub1_range=$(az network vnet subnet show -n $vnet_name_sub1 --resource-group $vnet_rg --vnet-name $vnet_name | grep Prefix |cut -f4 -d\" | cut -f 1 -d/)
vnet_tenant_supernet="$vnet_sub1_range/21"

#echo $vnet_tenant_supernet
# Get Hosting Plus subscription list
#subscription_string=`az account list  | grep $region-HOSTINGPLUS | cut -f2 -d: | cut -f 1 -d, | sort`

# get number lines in subscription
#num_subs=`echo $subscription_string | wc -l`
# Convert multiline string into array
#subscription_array=()
#while read -r line; do
#	subscription_array+=("$line")
#done <<< "$subscription_string"

# Build Dialog around list of subscriptions matching region
#subscription_dialog="$DIALOG --radiolist "Subscriptions" 20 60 12 "
#for i in $subscription_string
#do
#	subscription_dialog+="$i $i on " 
#done
#subscription=$($subscription_dialog 2>&1 > /dev/tty)

#Variable outputs for debugging
#echo $subscription_dialog
#echo $region
#echo $tenantID
#echo $subs
#echo $subscription
echo $vnet_tenant_supernet
echo $vnet_name_sub1
echo $vnet_name_sub8
echo $vnet_name
echo $vnet_rg
#log out of azure
az logout
exit 0