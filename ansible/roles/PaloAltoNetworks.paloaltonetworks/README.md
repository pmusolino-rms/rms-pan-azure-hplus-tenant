Role Name
=========

The Palo Alto Networks Ansible modules project is a collection of Ansible modules to automate configuration and
operational tasks on Palo Alto Networks *Next Generation Firewalls*. The underlying protocol uses API calls that
are wrapped withing Ansible framework.

https://galaxy.ansible.com/PaloAltoNetworks/paloaltonetworks/

Requirements
------------

- pip

Role Variables
--------------

N/A

Dependencies
------------

N/A

Example Playbook
----------------

Sample playbook that will inject security rule in the PANW Next Generation Firewall device.

    - hosts: localhost
    connection: local

    vars:
        mgmt_ip: "~~HIDDEN~~"
        admin_password: "~~HIDDEN~~"

    tasks:       
        # permit ssh to 1.1.1.1
        - name: permit ssh to 1.1.1.1
          panos_security_rule:
            ip_address: "{{ mgmt_ip }}"
            password: "{{admin_password}}"
            rule_name: 'SSH permit'
            description: 'SSH rule test'
            source_zone: ['untrust']
            destination_zone: ['trust']
            source_ip: ['any']
            source_user: ['any']
            destination_ip: ['1.1.1.1']
            category: ['any']
            application: ['ssh']
            service: ['application-default']
            hip_profiles: ['any']
            action: 'allow'
            operation: 'add'
            commit: false

    roles:
        - role: PaloAltoNetworks.paloaltonetworks

License
-------

Apache 2.0

Author Information
------------------

Ivan Bojer, @ivanbojer
