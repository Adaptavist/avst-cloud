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
using Rainbow
module AvstCloud
    
    class RackspaceConnection < AvstCloud::CloudConnection
        
        attr_accessor :region

        def initialize(provider_access_user, provider_access_pass, region=:lon)
            super('rackspace',provider_access_user, provider_access_pass)
            @region = region
        end
        
        def server(server_name, root_user, root_password, os=nil)
            server = find_fog_server(server_name)
            if !root_user
                root_user = "root"
            end
            AvstCloud::RackspaceServer.new(server, server_name, server.public_ip_address, root_user, root_password)
        end

        def create_server(server_name, image_id, flavor_id='4', additional_hdds={})
            server_number, os="ubuntu14"
            
            logger.debug "Creating Rackspace server:"
            logger.debug "server_name      - #{server_name}"
            logger.debug "flavor_id        - #{flavor_id}"
            logger.debug "image_id         - #{image_id}"

            unless server_name and image_id
                raise "Please provide server_name, image_id and flavor_id"
            end

            # Check existing server
            existing_server = find_fog_server(server_name, false)
            if existing_server && existing_server.state != 'SHUTOFF'
                logger.debug "Server found in state: #{existing_server.state}"
                raise "Server with the same name found!"
            elsif existing_server && existing_server.state == 'SHUTOFF'
                logger.debug "Server found and is stopped, restarting it."
                existing_server.reboot 'HARD'
                result_server = AvstCloud::RackspaceServer.new(existing_server, server_name, nil, nil , nil)
                result_server.wait_for_state() {|serv| serv.ready?}
                logger.debug "[DONE]\n\n"
                logger.debug "The server was successfully re-started.\n\n"
            else
                # create server
                server = connect.servers.create :name => server_name,
                                                :flavor_id => flavor_id,
                                                :image_id => image_id
                begin
                    result_server = AvstCloud::RackspaceServer.new(server, server_name, nil, nil , nil)
                    # Check every 5 seconds to see if server is in the active state (ready?).
                    # If the server has not been built in 5 minutes (600 seconds) an exception will be raised.
                    result_server.wait_for_state() {|serv| serv.ready?}
                    logger.debug "[DONE]\n\n"

                    logger.debug "The server has been successfully created, to login onto the server:\n\n"
                    logger.debug "\t ssh #{server.username}@#{server.public_ip_address}\n\n"
                    if additional_hdds and additional_hdds.is_a?(Hash)
                        additional_hdds.each do |disk_name, disk|
                            if disk['device_name'] && disk['ebs_size']
                                volume_type = disk['volume_type'] || 'SSD'
                                volume = storageService.volumes.create(:size => disk['ebs_size'], :display_name => disk_name, :volume_type => volume_type)
                                if volume && volume.id
                                    wait_for_hdd(volume.id, 'available')
                                    server.attach_volume volume.id, disk['device_name'] 
                                else
                                    logger.error "Failed to create volume, #{disk_name}"
                                end
                            else
                                logger.warn "Failed to create additional hdd, required params device_name (e.g. /dev/sda1) or ebs_size missing: #{disk}"
                            end 
                        end 
                    end
                rescue Fog::Errors::TimeoutError
                    logger.debug "[TIMEOUT]\n\n"
                    logger.debug "This server is currently #{server.progress}% into the build process and is taking longer to complete than expected."
                    logger.debug "You can continute to monitor the build process through the web console at https://mycloud.rackspace.com/\n\n"
                    raise "Timeout while creating Rackspace server #{server_name}"
                end
                logger.debug "The #{server.username} password is #{Logging.mask_message(server.password)}\n\n"
            end
            result_server.access_user = server.username
            result_server.access_password = server.password
            result_server.ip_address =  server.public_ip_address
            result_server
        end

        def server_status(server_name)
            server = find_fog_server(server_name, false)
            if server
                logger.debug "Server with name '#{server_name}' exists and has state: #{server.state}"
                server.state
            else
                logger.debug "Server not found for name: #{server_name}"
                'not_created'
            end
        end

        def list_flavours
            connect.flavors.each do |fl|
                logger.debug fl.inspect
            end
        end

        def list_images
            connect.images.each do |im|
                logger.debug im.inspect
            end
        end
        
        # Returns list of servers from fog
        def list_known_servers
            connect.servers.all
        end

        def find_fog_server(server_name, should_fail=true)
            serv = connect.servers.find{|serv| serv.name == server_name}
            unless serv
                if should_fail
                    logger.debug "Server not found for name: #{server_name}"
                    raise "Server not found for name: #{server_name}"
                end
            end
            serv
        end

    private
        def connect
            unless @connection
                logger.debug "Creating new connection to rackspace: #{@provider_user} #{Logging.mask_message(@provider_pass)} #{@region}"
                @connection = Fog::Compute.new({
                    :provider             => 'Rackspace',
                    :rackspace_username   => @provider_access_user,
                    :rackspace_api_key    => @provider_access_pass,
                    :rackspace_auth_url  => Fog::Rackspace::UK_AUTH_ENDPOINT,
                    :version => :v2,  # Use Next Gen Cloud Servers
                    :rackspace_region => @region
                })
            end
            @connection
        end

        def storageService
            unless @storageService
                logger.debug "Creating new connection to rackspace storage service: #{@provider_user} #{Logging.mask_message(@provider_pass)} #{@region}"
                @storageService = Fog::Rackspace::BlockStorage.new({
                    :rackspace_username  => @provider_access_user,        # Your Rackspace Username
                    :rackspace_api_key   => @provider_access_pass,              # Your Rackspace API key
                    :rackspace_auth_url  => Fog::Rackspace::UK_AUTH_ENDPOINT,
                    :rackspace_region    => @region
                })
            end
            @storageService
        end

        def wait_for_hdd(id, expected_state)
            logger.debug "Waiting for hdd state change...".yellow
            (1..60).each do |c|
                hdd = storageService.volumes.get(id)
                if hdd.state == expected_state
                    break
                end
                sleep 60
            end
        end
    end
end
