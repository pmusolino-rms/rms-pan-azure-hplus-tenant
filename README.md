# rms-pan-azure-hplus-tenant
version 2.0

Requirements:
Linux/MacOS

dialog
Ansible (and any prerequisites)
python 2.7 
python_setuptools
gcc
pip

PaloAltoNetworks Ansible Modules
pandevice 0.5.1
pan-python
napalm
napalm-ansible
pyopenssl that supports TLS1.2
Azure CLI 2.0

Edit your vpan-vars file to add username, password, tenant, and optionally account for your azure access
Also add vpan_admin and vpan_password for the credentials you will set for the firewall during deployment
Edit ansible/group_vars/all with the same credential variables and values for configuration
edit ansible/ansible.cfg and update the library variable in the defaults section to the location of your napalm_ansible install (typically in your python/site-packages/napalm_anaible dir)
