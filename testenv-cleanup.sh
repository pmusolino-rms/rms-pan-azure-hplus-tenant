LOGIN_VARIABLES="./vpan-vars"
source $LOGIN_VARIABLES
az login -u $username --service-principal --tenant $tenant -p $password
az account set --subscription $account
for i in `seq 1 7`
    do
	az network vnet subnet update --route-table "" -g PM-TEST_RG --vnet-name EUN-HOSTINGPLUS-9-VNET-1 -n EUN-TEN9999-Sub${i}
	done
az network route-table delete -n EUN-TEN9999-RT1 -g PM-TEST_RG
az group delete -y -n EUN-TEN9999-VFW-RG
az network vnet subnet delete -n EUN-TEN9999-Sub8-MGMT -g PM-TEST_RG --vnet-name EUN-HOSTINGPLUS-9-VNET-1
az network vnet subnet delete -n EUN-TEN9999-Sub8-Untrust -g PM-TEST_RG --vnet-name EUN-HOSTINGPLUS-9-VNET-1
az network vnet subnet delete -n EUN-TEN9999-Sub8-Trust -g PM-TEST_RG --vnet-name EUN-HOSTINGPLUS-9-VNET-1
az network vnet subnet create -n EUN-TEN9999-Sub8 -g PM-TEST_RG --vnet-name EUN-HOSTINGPLUS-9-VNET-1 --address-prefix 10.249.15.0/24
az logout

