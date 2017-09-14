az group delete -y -n EUN-TEN9999-VFW-RG 
az network vnet subnet delete -n EUN-TEN9999-Sub8-MGMT -g PM-TEST_RG --vnet-name EUN-HOSTINGPLUS-9-VNET-1 
az network vnet subnet delete -n EUN-TEN9999-Sub8-Untrust -g PM-TEST_RG --vnet-name EUN-HOSTINGPLUS-9-VNET-1 
az network vnet subnet delete -n EUN-TEN9999-Sub8-Trust -g PM-TEST_RG --vnet-name EUN-HOSTINGPLUS-9-VNET-1 
az network vnet subnet create -n EUN-TEN9999-Sub8 -g PM-TEST_RG --vnet-name EUN-HOSTINGPLUS-9-VNET-1 --address-prefix 10.249.15.0/24
