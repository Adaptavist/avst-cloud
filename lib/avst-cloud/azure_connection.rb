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
require 'fog/azure'
require 'azure'

module AvstCloud
    
    class AzureConnection < AvstCloud::CloudConnection
        
        attr_accessor :provider_api_url

        def initialize(provider_user, provider_pass, provider_api_url='management.core.windows.net')
            super('azure', provider_user, provider_pass)
            @provider_api_url = provider_api_url
        end
        
        def server(server_name, root_user, root_password)
            server = find_fog_server(server_name)
            if !root_user
                root_user = get_root_user
            end
            AvstCloud::AzureServer.new(server, server_name, server.ipaddress, root_user, root_password)
        end

        def create_server(server_name, user, private_key_file, location, image_id, vm_size, storage_account_name)

            image_id = image_id || '0b11de9248dd4d87b18621318e037d37__RightImage-CentOS-7.0-x64-v14.1.5.1'
            location = location || 'West Europe'
            user = user || get_root_user
            vm_size = vm_size || "Small"
            storage_account_name = storage_account_name || "storage#{Time.now.to_i}"
            private_key_file = private_key_file || "~/.ssh/id_rsa"
            existing_server = find_fog_server(server_name, false)
            
            if existing_server and existing_server.deployment_status != 'Suspended'
                logger.error "Server #{server_name} found in state: #{existing_server.deployment_status}".yellow
                raise "Running server with the same name found!"
            elsif existing_server and existing_server.deployment_status == 'Suspended'
                result_server = AvstCloud::AzureServer.new(existing_server, server_name, existing_server.ipaddress, user, private_key_file)
                result_server.start
                wait_for_state(server_name, "ReadyRole")
                logger.debug "[DONE]\n\n"
                logger.debug "The server was successfully re-started.\n\n"
                result_server
            else
                logger.debug "Creating Azure server:"
                logger.debug "Server name          - #{server_name}"
                logger.debug "location             - #{location}"
                logger.debug "storage_account_name - #{storage_account_name}"
                logger.debug "vm_size              - #{vm_size}"
                logger.debug "image_template_id    - #{image_id}"
                logger.debug "user                 - #{user}"
                logger.debug "private_key_file     - #{private_key_file}"
                logger.debug "region               - #{@provider_api_url}"

                # create server
                server = connect.servers.create(
                    :image  => image_id,
                    # Allowed values are East US,South Central US,Central US,North Europe,West Europe,Southeast Asia,Japan West,Japan East
                    :location => location,
                    :vm_name => server_name,
                    :vm_user => user,
                    :storage_account_name => storage_account_name,
                    :vm_size => vm_size,
                    :private_key_file => File.expand_path(private_key_file),
                )
                
                result_server = AvstCloud::AzureServer.new(server, server_name, nil, user, File.expand_path(private_key_file))
                wait_for_state(server_name, "ReadyRole")
                ipaddress = find_fog_server(server_name).ipaddress
                logger.debug "[DONE]\n\n"
                logger.debug "The server has been successfully created, to login onto the server:\n"
                logger.debug "\t ssh -i #{private_key_file} #{user}@#{ipaddress} \n"
            
                result_server.ip_address = ipaddress
                result_server
            end
        end

        def delete_storage_account(storage_account_name)
            logger.debug "Deleting #{storage_account_name}"
            account = find_storage_account(storage_account_name)
            account.destroy
            logger.debug "Storage deleted"
        end

        def list_storage_accounts
            connect.storage_accounts.each do |storage_acc|
              logger.debug storage_acc.inspect
            end
        end

        def find_storage_account(storage_account_name)
            connect.storage_accounts.get(storage_account_name)
        end

        def find_storage_account_for_server(server_name)
            connect.storage_accounts.find{|sa| sa.label == server_name}
        end

        def server_status(server_name)
            server = find_fog_server(server_name, false)
            if server
                server.deployment_status
            else
                'not_created'
            end
        end

        def list_images
            connect.images.each do |im|
                logger.debug im.inspect
            end
        end
        
        # Returns list of servers from fog
        def list_known_servers
            connect.servers.each do |sr|
                logger.debug sr.inspect
            end
        end

        def find_fog_server(server_name, should_fail=true)
            serv = connect.servers.find{|serv| serv.vm_name == server_name}
            unless serv
                if should_fail
                    logger.debug "Server not found for name: #{server_name}"
                    raise "Server not found for name: #{server_name}"
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
                @connection = Fog::Compute.new({
                    :provider      => 'Azure',
                    :azure_sub_id  => @provider_access_user,
                    :azure_pem     => @provider_access_pass,
                    :azure_api_url => @provider_api_url
                })
            end
            @connection
        end
        
        def all_named_servers(server_name)
            connect.servers.find{|serv| serv.vm_name == server_name}
        end

        # tmp fix as fog-azure is failing
        def wait_for_state(server_name, state)
            (1..60).each do |c|
                srv = find_fog_server(server_name)
                if srv.status == state
                    break
                end
                sleep 60
            end
        end
    end
end