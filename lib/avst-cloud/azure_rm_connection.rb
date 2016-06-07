# Copyright 2015 Adaptavist.com Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative './cloud_connection.rb'
require 'fog/azurerm'

module AvstCloud
    
    class AzureRmConnection < AvstCloud::CloudConnection
        
        attr_accessor :tenant_id, :subscription_id

        def initialize(client_id, client_secret, tenant_id, subscription_id)
            super('AzureRM', client_id, client_secret)
            @tenant_id = tenant_id
            @subscription_id = subscription_id
        end
        
        def server(server_name, resource_group, root_user, root_password, use_public_ip=true)
            server = find_fog_server(server_name, resource_group)
            if !root_user
                root_user = get_root_user
            end
            ip_address = nil
            if (server.network_interface_card_id)
                network_interface_card_name = server.network_interface_card_id.split("/")[-1]
                nic = connect_to_networks.network_interfaces(resource_group: resource_group).get(network_interface_card_name)
                if nic
                    if use_public_ip
                        if nic.public_ip_address_id
                            ip_configuration_name = nic.public_ip_address_id.split("/")[-1]
                            pip = connect_to_networks.public_ips(resource_group: resource_group).get(ip_configuration_name)
                            ip_address = pip.ip_address
                        else
                            logger.debug "Can not find public ip for server #{server_name} in resource_group #{resource_group}"
                            raise "Can not find public ip"
                        end
                    else
                        ip_address = nic.private_ip_address
                    end
                else
                    logger.debug "Can not find network interface card for server #{server_name} in resource_group #{resource_group}"
                    raise "Can not find network interface card"
                end
            else 
                logger.debug "Can not find network interface card for server #{server_name} in resource_group #{resource_group}"
                raise "Can not find network interface card"
            end

            AvstCloud::AzureRmServer.new(server, server_name, ip_address, root_user, root_password)
        end

        def create_server(server_name, 
            user, 
            password,
            publisher,
            offer,
            sku,
            version,
            location, 
            resource_group, 
            vm_size, 
            storage_account_name, 
            network_interface_name, 
            virtual_network_name, 
            subnet_name, 
            ip_configuration_name,
            private_ip_allocation_method,
            public_ip_allocation_method, 
            subnet_address_list, 
            dns_list, 
            network_address_list, 
            address_prefix,
            use_public_ip)

            location = location || 'West Europe'
            user = user || get_root_user
            vm_size = vm_size || "Basic_A0"
            
            # Check that resource_group exists if not create one
            check_create_resource_group(resource_group, location)
            
            existing_server = find_fog_server(server_name, resource_group, false)
            
            if existing_server
                logger.error "Server #{server_name} found. #{existing_server.inspect}".yellow
                raise "Running server with the same name found!"
            else
                logger.debug "Creating Azure server:"
                logger.debug "Server name          - #{server_name}"
                logger.debug "location             - #{location}"
                logger.debug "storage_account_name - #{storage_account_name}"
                logger.debug "vm_size              - #{vm_size}"
                logger.debug "user                 - #{user}"
                logger.debug "password             - #{password}"
                logger.debug "publisher            - #{publisher}"
                logger.debug "offer                - #{offer}"
                logger.debug "sku                  - #{sku}"
                logger.debug "version              - #{version}"

                # Check that storage_account exists if not create one
                check_create_storage_account(storage_account_name, location, resource_group)
                
                # Check if network_interface_card_id exists if not create one
                # If not, create one for virtual network provided with subnet, security group and also public ip name
                ip_address = check_create_network_interface(network_interface_name, resource_group, location, virtual_network_name, subnet_name, ip_configuration_name, private_ip_allocation_method, public_ip_allocation_method, subnet_address_list, dns_list, network_address_list, address_prefix, use_public_ip)
                
                # create server
                server = connect.servers.create(
                    name: server_name,
                    location: location,
                    resource_group: resource_group,
                    vm_size: vm_size,
                    storage_account_name: storage_account_name,
                    username: user,
                    password: password,
                    disable_password_authentication: false,
                    network_interface_card_id: "/subscriptions/#{@subscription_id}/resourceGroups/#{resource_group}/providers/Microsoft.Network/networkInterfaces/#{network_interface_name}",
                    publisher: publisher,
                    offer: offer,
                    sku: sku,
                    version: version
                )
                
                result_server = AvstCloud::AzureRmServer.new(server, server_name, ip_address, user, password)
                logger.debug "[DONE]\n\n"
                logger.debug "The server has been successfully created, to login onto the server:\n"
                logger.debug "\t ssh #{user}@#{ip_address} with pass #{password} \n"
                result_server
            end
        end

        def list_storage_accounts(storage_account_name, resource_group)
            storage_acc = connect_to_storages.storage_accounts(resource_group: resource_group)
                          .get(storage_account_name)
            logger.debug "#{storage_acc.inspect}"
        end

        def check_create_network_interface(network_interface_name, resource_group, location, virtual_network_name, subnet_name, ip_configuration_name, private_ip_allocation_method="Dynamic", public_ip_allocation_method="Static", subnet_address_list=nil, dns_list=nil, network_address_list=nil, address_prefix=nil, use_public_ip=true)
            nic = connect_to_networks.network_interfaces(resource_group: resource_group).get(network_interface_name)
        
            # check/create ip_configuration_name exists
            public_ip = check_create_ip_configuration(ip_configuration_name, resource_group, location, public_ip_allocation_method)
            unless nic
                # check/create  virtual_network exists
                vnet = check_create_virtual_network(virtual_network_name, resource_group, location, subnet_address_list, dns_list, network_address_list)
                
                # check if provided subnet exists, if nil then use default one
                unless subnet_name                    
                    subnets = connect_to_networks.subnets(resource_group: resource_group, virtual_network_name: virtual_network_name)
                    if subnets.length == 0
                        raise "Can not decide what subnet to choose. There are no subnets for virtual network #{virtual_network_name}."
                    elsif subnets.length != 1
                        raise "Can not decide what subnet to choose. Please specify subnet name."
                    end
                    subnet_name = subnets[0].name
                    logger.debug "Using subnet #{subnet_name}"
                end
                
                nic = connect_to_networks.network_interfaces.create(
                    name: network_interface_name,
                    resource_group: resource_group,
                    location: location,
                    subnet_id: "/subscriptions/#{@subscription_id}/resourceGroups/#{resource_group}/providers/Microsoft.Network/virtualNetworks/#{virtual_network_name}/subnets/#{subnet_name}",
                    ip_configuration_name: ip_configuration_name,
                    private_ip_allocation_method: private_ip_allocation_method
                )
            end
            if use_public_ip
                public_ip
            else
                nic.private_ip_address
            end
        end
        
        def find_network_interface_for_server(server_name, resource_group, should_fail=false)
            server = find_fog_server(server_name, resource_group)
            network_interface = nil
            if (server and server.network_interface_card_id)
                network_interface_card_name = server.network_interface_card_id.split("/")[-1]
                network_interface = connect_to_networks.network_interfaces(resource_group: resource_group).get(network_interface_card_name)
            else
                logger.debug "Can not find network interface card for server #{server_name} in resource_group #{resource_group}"
                raise "Can not find network interface card" if should_fail 
            end
            network_interface
        end

        def destroy_network_interface(network_interface_name, resource_group)
            logger.debug "Deleting #{network_interface_name}"
            network_interface = connect_to_networks.network_interfaces(resource_group: resource_group).get(network_interface_name)
            if network_interface
                network_interface.destroy
            end
            logger.debug "Network interface deleted"
        end

        def destroy_network_interface_for_server(server_name, resource_group, should_fail=false)
            server = find_fog_server(server_name, resource_group)
            if (server.network_interface_card_id)
                network_interface_card_name = server.network_interface_card_id.split("/")[-1]
                destroy_network_interface(network_interface_card_name, resource_group)
            else 
                logger.debug "Can not find network interface card for server #{server_name} in resource_group #{resource_group}"
                raise "Can not find network interface card" if should_fail
            end
        end

        def check_create_ip_configuration(ip_configuration_name, resource_group, location, public_ip_allocation_method="Static")
            ip_configuration = connect_to_networks.public_ips(resource_group: resource_group).get(ip_configuration_name)
            unless ip_configuration
                ip_configuration = connect_to_networks.public_ips.create(
                    name: ip_configuration_name,
                    resource_group: resource_group,
                    location: location,
                    public_ip_allocation_method: public_ip_allocation_method
                )
            end
            ip_configuration.ip_address
        end

        def destroy_ip_configuration(ip_configuration_name, resource_group)
            logger.debug "Deleting #{ip_configuration_name}"
            public_ip = connect_to_networks.public_ips(resource_group: resource_group).get(ip_configuration_name)
            if public_ip
                public_ip.destroy
            end
            logger.debug "Public IP deleted"
        end

        def destroy_ip_configuration_for_server(server_name, resource_group, should_fail=false)
            server = find_fog_server(server_name, resource_group)
            if (server.network_interface_card_id)
                network_interface_card_name = server.network_interface_card_id.split("/")[-1]
                nic = connect_to_networks.network_interfaces(resource_group: resource_group).get(network_interface_card_name)
                if nic
                    if nic.public_ip_address_id
                        ip_configuration_name = nic.public_ip_address_id.split("/")[-1]
                        destroy_ip_configuration(ip_configuration_name, resource_group)
                    else
                        logger.debug "Can not find public ip for server #{server_name} in resource_group #{resource_group}"
                        raise "Can not find public ip" if should_fail
                    end
                else
                    logger.debug "Can not find network interface card for server #{server_name} in resource_group #{resource_group}"
                    raise "Can not find network interface card" if should_fail
                end
            else 
                logger.debug "Can not find network interface card for server #{server_name} in resource_group #{resource_group}"
                raise "Can not find network interface card" if should_fail
            end
        end

        def check_create_subnet(subnet_name, resource_group, location, virtual_network_name, address_prefix=nil, subnet_address_list=nil, dns_list=nil, network_address_list=nil)
            subnet = connect_to_networks.subnets(resource_group: resource_group, virtual_network_name: virtual_network_name).get(subnet_name)
            unless subnet
                logger.debug "Subnet #{subnet_name} not found, creating new one"
                address_prefix = address_prefix || '10.1.0.0/24'                
                subnet = connect_to_networks.subnets.create(
                    name: subnet_name,
                    resource_group: resource_group,
                    virtual_network_name: virtual_network_name,
                    address_prefix: address_prefix
                )
            end
        end

        def destroy_subnet(subnet_name, resource_group, virtual_network_name)
            logger.debug "Deleting #{subnet_name}"
            subnet = connect_to_networks.subnets(resource_group: resource_group, virtual_network_name: virtual_network_name).get(subnet_name)
            if subnet
                subnet.destroy
            end
            logger.debug "Subnet deleted"
        end

        def destroy_subnet_for_server(server_name, resource_group, should_fail=false)
            server = find_fog_server(server_name, resource_group)
            if (server.network_interface_card_id)
                network_interface_card_name = server.network_interface_card_id.split("/")[-1]
                nic = connect_to_networks.network_interfaces(resource_group: resource_group).get(network_interface_card_name)
                if nic
                    if nic.subnet_id
                        subnet_id_name = nic.subnet_id.split("/")[-1]
                        virtual_network_name = nic.subnet_id.split("virtualNetworks/")[-1].split("/")[0]
                        destroy_subnet(subnet_id_name, resource_group, virtual_network_name)
                    else
                        logger.debug "Can not find subnet for server #{server_name} in resource_group #{resource_group}"
                        raise "Can not find subnet" if should_fail
                    end
                else
                    logger.debug "Can not find network interface card for server #{server_name} in resource_group #{resource_group}"
                    raise "Can not find network interface card" if should_fail
                end
            else 
                logger.debug "Can not find network interface card for server #{server_name} in resource_group #{resource_group}"
                raise "Can not find network interface card" if should_fail
            end
        end

        def check_create_virtual_network(virtual_network_name, resource_group, location, subnet_address_list=nil, dns_list=nil, network_address_list=nil)
            vnet = connect_to_networks.virtual_networks(resource_group: resource_group).get(virtual_network_name)
                                       # virtual_networks.get(virtual_network_name, resource_group)
            unless vnet
                logger.debug "Virtual network #{virtual_network_name} not found, creating new one"
                subnet_address_list = subnet_address_list || '10.1.0.0/24'
                dns_list = dns_list || '10.1.0.5,10.1.0.6'
                network_address_list = network_address_list || '10.1.0.0/16,10.2.0.0/16'
                vnet = connect_to_networks.virtual_networks.create(
                    name: virtual_network_name,
                    location: location,
                    resource_group: resource_group,
                    subnet_address_list: subnet_address_list,
                    dns_list: dns_list,
                    network_address_list: network_address_list
                )
            end
            vnet
        end

        def destroy_virtual_network_for_server(server_name, resource_group, should_fail=false)
            server = find_fog_server(server_name, resource_group)
            if (server.network_interface_card_id)
                network_interface_card_name = server.network_interface_card_id.split("/")[-1]
                nic = connect_to_networks.network_interfaces(resource_group: resource_group).get(network_interface_card_name)
                if nic
                    if nic.subnet_id
                        virtual_network_name = nic.subnet_id.split("virtualNetworks/")[-1].split("/")[0]
                        destroy_virtual_network(virtual_network_name, resource_group)
                    else
                        logger.debug "Can not find virtual network for server #{server_name} in resource_group #{resource_group}"
                        raise "Can not find subnet" if should_fail
                    end
                else
                    logger.debug "Can not find network interface card for server #{server_name} in resource_group #{resource_group}"
                    raise "Can not find network interface card" if should_fail
                end
            else 
                logger.debug "Can not find network interface card for server #{server_name} in resource_group #{resource_group}"
                raise "Can not find network interface card" if should_fail
            end
        end

        def destroy_virtual_network(virtual_network_name, resource_group)
            logger.debug "Deleting #{virtual_network_name}"
            vnet = connect_to_networks.virtual_networks(resource_group: resource_group).get(virtual_network_name)
            if vnet
                vnet.destroy
            end
            logger.debug "Virtual network deleted"
        end

        def check_create_storage_account(storage_account_name, location, resource_group)
            account = connect_to_storages.storage_accounts(resource_group: resource_group).get(storage_account_name)
            unless account
                logger.debug "Storage account #{storage_account_name} not found, creating new one"
                account = connect_to_storages.storage_accounts.create(
                    name:     storage_account_name,
                    location: location,
                    resource_group: resource_group
                )
            end
            account
        end

        def find_storage_account_name_for_server(server_name, resource_group, should_fail=false)
            server = find_fog_server(server_name, resource_group)
            storage_account_name = nil
            if (server and server.storage_account_name)
                storage_account_name = server.storage_account_name
            end
            storage_account_name
        end

        def destroy_storage_account_for_server(server_name, resource_group, should_fail=false)
            server = find_fog_server(server_name, resource_group)
            if (server.storage_account_name)
                storage_account_name = server.storage_account_name
                destroy_storage_account(storage_account_name, resource_group)
            else 
                logger.debug "Can not find storage account for server #{server_name} in resource_group #{resource_group}"
                raise "Can not find storage account" if should_fail
            end
        end

        def destroy_storage_account(storage_account_name, resource_group)
            logger.debug "Deleting #{storage_account_name}"
            account = connect_to_storages.storage_accounts(resource_group: resource_group).get(storage_account_name)
            if account
                account.destroy
            end
            logger.debug "Storage deleted"
        end

        def check_create_resource_group(resource_group, location)
            logger.debug "Searching for #{resource_group}"
            found_resource_group = connect_to_resources.resource_groups.get(resource_group)
            unless found_resource_group
                logger.debug "Resource group #{resource_group} not found, creating new one"
                found_resource_group = connect_to_resources.resource_groups.create(
                    name:     resource_group,
                    location: location
                )
            end
            found_resource_group
        end

        def destroy_resource_group(resource_group)
            logger.debug "Deleting #{resource_group}"
            found_resource_group = connect_to_resources.resource_groups.get(resource_group)
            if found_resource_group
                found_resource_group.destroy
            end
        end

        def server_status(server_name, resource_group)
            'unknown'
        end

        def list_images
            connect.images.each do |im|
                logger.debug im.inspect
            end
        end
        
        # Returns list of servers from fog
        def list_known_servers(resource_group)
            connect.servers(resource_group: resource_group).each do |sr|
                logger.debug sr.inspect
            end
        end

        def find_fog_server(server_name, resource_group, should_fail=true)
            serv = connect.servers(resource_group: resource_group).get(resource_group, server_name)
            unless serv
                if should_fail
                    logger.debug "Server not found for name: #{server_name} in resource group #{resource_group}"
                    raise "Server not found for name: #{server_name} in resource group #{resource_group}"
                end
            end
            serv
        end

    private
        def get_root_user
            "azureuser"
        end
        def connect
            unless @connection
                logger.debug "Creating new connection to Azure"
                
                @connection = Fog::Compute.new(
                    provider: 'AzureRM',
                    tenant_id: @tenant_id,
                    client_id:    @provider_access_user,
                    client_secret: @provider_access_pass,
                    subscription_id: @subscription_id
                )
            end
            @connection
        end

        def connect_to_networks
            unless @networks_connection
                logger.debug "Creating new connection to Azure networks"
                @networks_connection = Fog::Network::AzureRM.new(
                    tenant_id: @tenant_id,
                    client_id:    @provider_access_user,
                    client_secret: @provider_access_pass,
                    subscription_id: @subscription_id
                )
            end
            @networks_connection
        end

        def connect_to_storages
            unless @storage_connection
                logger.debug "Creating new connection to Azure storage accounts"
                @storage_connection = Fog::Storage.new(
                    provider: 'AzureRM',
                    tenant_id: @tenant_id,
                    client_id:    @provider_access_user,
                    client_secret: @provider_access_pass,
                    subscription_id: @subscription_id
                )
            end
            @storage_connection
        end

        def connect_to_resources
            unless @resources_connection
                logger.debug "Creating new connection to Azure resources"
                @resources_connection = Fog::Resources::AzureRM.new(
                    tenant_id: @tenant_id,
                    client_id:    @provider_access_user,
                    client_secret: @provider_access_pass,
                    subscription_id: @subscription_id
                )
            end
            @resources_connection
        end
    end
end