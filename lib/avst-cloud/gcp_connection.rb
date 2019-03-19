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
require 'fog/google'
using Rainbow
module AvstCloud
    
    class GcpConnection < AvstCloud::CloudConnection
        
        attr_accessor :region

        def initialize(provider_user, provider_pass, region, project)
            super('Google', provider_user, provider_pass)
            @region = region
            @project = project
        end
        
        def server(server_name, root_user, root_password, os=nil)
            server = find_fog_server(server_name)
            if !root_user and os
                root_user = user_from_key(os)
            end
            AvstCloud::GcpServer.new(server, server_name, server.public_ip_address, root_user, root_password)
        end

        def create_server(server_name, flavour, os, key_name, ssh_public_key, ssh_private_key, subnet_id, security_group_ids, root_disk_size, root_disk_type, machine_type_id, availability_zone, additional_hdds={}, vpc=nil, created_by=nil, custom_tags=[], root_username=nil, delete_root_disk=true)
            flavour = flavour || "g1-small"
            os = os || "centos-7"
            vpc_name = vpc || "default"
            subnet_name = subnet_id || "default"
            machine_type_id = machine_type_id || get_image_name(os) 
            if machine_type_id.nil? or machine_type_id.empty?
                machine_type_id = "centos-7-v20190312"
            end

            unless File.file?(ssh_public_key)
                logger.error "Could not find local public SSH key '#{ssh_key}'".red
                raise "Could not find local SSH public key '#{ssh_key}'"
            end

            unless File.file?(ssh_private_key)
                logger.error "Could not find local private SSH key '#{ssh_key}'".red
                raise "Could not find local SSH private key '#{ssh_key}'"
            end
            root_user = root_username || user_from_key(os)

            existing_servers    = all_named_servers(server_name)
            restartable_servers = existing_servers.select{ |serv| serv.status == 'TERMINATED' }
            #TODO, status is a guess, need to work out if "DELETED" is valid for GCP
            running_servers     = existing_servers.select{ |serv| serv.status != 'TERMINATED' && serv.status != 'DELETED' }

            if running_servers.length > 0
                running_servers.each do |server|
                    logger.error "Server #{server_name} with id #{server.id} found in state: #{server.status}".yellow
                end
                raise "Server with the same name found!"

            elsif restartable_servers.length > 0
                if restartable_servers.length > 1
                    running_servers.each do |server|
                        logger.error "Server #{server_name} with id #{server.id} found in state: #{server.status}. Can not restart".yellow
                    end
                    raise "Too many servers can be restarted."
                end
                server = restartable_servers.first
                server.start
                result_server = AvstCloud::GcpServer.new(server, server_name, server.public_ip_address, root_user, ssh_public_key)
                result_server.wait_for_state() {|serv| serv.ready?}
                logger.debug "[DONE]\n\n"
                logger.debug "The server was successfully re-started.\n\n"
                result_server
            else
                logger.debug "Creating GCP server:"
                logger.debug "Server name        - #{server_name}"
                logger.debug "Operating system   - #{os}"
                logger.debug "image_template_id  - #{machine_type_id}"
                logger.debug "flavour            - #{flavour}"
                logger.debug "key_name           - #{key_name}"
                logger.debug "Public ssh_key     - #{ssh_public_key}"
                logger.debug "Private ssh_key    - #{ssh_private_key}"
                logger.debug "root user          - #{root_user}"
                logger.debug "subnet_id          - #{subnet_name}"
                logger.debug "security_group_ids - #{security_group_ids}"
                logger.debug "region             - #{@region}"
                logger.debug "availability_zone  - #{availability_zone}"
                logger.debug "root_disk_size     - #{root_disk_size}"
                logger.debug "additional_hdds    - #{additional_hdds}"
                logger.debug "vpc                - #{vpc_name}"

                # Create root disk
                # TODO check if this exists and exit politely, or catch the exception and exit politely
                root_disk_type = root_disk_type || 'pd-standard'
                logger.debug "Creating root disk with type #{root_disk_type}"
                root_disk_url="https://www.googleapis.com/compute/v1/projects/#{@project}/zones/#{availability_zone}/diskTypes/#{root_disk_type}"
                disk = connect.disks.create :name => "#{server_name}-root",
                                            :size_gb => root_disk_size,
                                            :zone => availability_zone,
                                            :source_image => machine_type_id,
                                            :type => root_disk_url
                
                # wait for the disk to be ready
                logger.debug "Waiting for root disk to be ready"
                disk.wait_for { ready? }

                disk_to_attach=[disk.attached_disk_obj(boot: true, auto_delete: delete_root_disk)]

                # create additional HDD's if required
                if additional_hdds and additional_hdds.is_a?(Hash)
                    disk_count=1
                    additional_hdds.each_value do |disk|
                        #TODO wortk out how to set disk type!
                        if disk['disk_size']
                            disk_type = disk['disk_type'] || 'pd-standard'
                            logger.debug "Creating additional disk #{disk_count} with type #{disk_type}"
                            disk_url="https://www.googleapis.com/compute/v1/projects/#{@project}/zones/#{availability_zone}/diskTypes/#{disk_type}"
                            delete_disk_with_vm = disk['delete_disk_with_vm'] || false
                            additional_disk = connect.disks.create :name => "#{server_name}-disk#{disk_count}",
                                                                   :size_gb => disk['disk_size'],
                                                                   :zone => availability_zone,
                                                                   :type => disk_url
                            # wait for additional disk
                            logger.debug "Waiting for additional disk #{disk_count}"
                            additional_disk.wait_for { ready? }

                            # add disk to array of those to be mounted
                            disk_to_attach.push additional_disk.attached_disk_obj(boot: false, auto_delete: delete_disk_with_vm)

                            #blank the additional disk object for the next time around
                            attached_disk = nil

                            # increment disk counter
                            disk_count = disk_count +1
                        else
                            logger.warn "Failed to create additional hdd, required param disk_size missing: #{disk}"
                        end 
                    end 
                end

                ## GCP tags are not key value pairs
                tags = [server_name, os] + custom_tags

                # work out the URK for the subnetwork
                subnet_url = "https://www.googleapis.com/compute/v1/projects/#{@project}/regions/#{region}/subnetworks/#{subnet_name}"

                # create server
                logger.debug "Creating Server"
                server = connect.servers.create :name => server_name,
                                                :disks => disk_to_attach,
                                                :machine_type => flavour,
                                                :private_key_path => ssh_private_key,
                                                :public_key_path => ssh_public_key,
                                                :zone => availability_zone,
                                                :network_interfaces => [{ :network => "global/networks/#{vpc_name}",
                                                                          :subnetwork => subnet_url,
                                                                          :access_configs => [{
                                                                              :name => "External NAT",
                                                                              :type => "ONE_TO_ONE_NAT" }] 
                                                                        }],
                                                :username => root_user,
                                                :tags => tags

                result_server = AvstCloud::GcpServer.new(server, server_name, nil, root_user, ssh_public_key)
                # result_server.logger = logger
                # Check every 5 seconds to see if server is in the active state (ready?).
                # If the server has not been built in 5 minutes (600 seconds) an exception will be raised.
                result_server.wait_for_state() {|serv| serv.ready?}

                logger.debug "[DONE]\n\n"
                logger.debug "The server has been successfully created, to login onto the server:\n"
                logger.debug "\t ssh -i #{ssh_private_key} #{root_user}@#{server.public_ip_address}\n"
                result_server.ip_address = server.public_ip_address
                result_server
            end
        end

        def server_status(server_name)
            #TODO, status is a guess, need to work out if this is valid for GCP
            servers = all_named_servers(server_name).select{|serv| serv.status != 'DELETED'}
            if servers.length > 0
                servers.each do |server|
                    logger.debug "Server #{server.id} with name '#{server_name}' exists and has state: #{server.status}"
                end
            else
                logger.debug "Server not found for name: #{server_name}"
            end
        end

        def list_zones
            logger.debug connect.list_zones
        end

        def list_flavours(zone)
            logger.debug connect.list_machine_types(zone)
        end

        def list_images
            # Only list current images, not deprecated ones
            get_images.each do |im|
                logger.debug im.inspect
            end
        end
        
        def list_networks
            logger.debug connect.list_networks
        end

        def list_disk_types(availability_zone)
            logger.debug connect.list_disk_types(availability_zone)
        end

        # Returns list of servers from fog
        def list_known_servers
            connect.servers.all
        end

        def find_fog_server(server_name, should_fail=true)
            #TODO, status is a guess, need to work out if this is valid for GCP
            servers = all_named_servers(server_name).select{|serv| serv.status != 'DELETED'}
            unless servers.length == 1    
                logger.debug "Found #{servers.length} servers for name: #{server_name}".yellow
                if should_fail
                    raise "Found #{servers.length} servers for name: #{server_name}"
                end
            end
            servers.first
        end

    private
        # attempt to workout the user from the key comments! - TODO
        def user_from_key(os)
            raise "Function to extract username from key comment not yet implemented"
        end
        def connect
            unless @connection
                logger.debug "Creating new connection to GCP"
                @connection = Fog::Compute.new({
                    :provider                 => 'Google',
                    :google_project           => @project,
                    :google_client_email      => @provider_access_user,
                    :google_json_key_location => @provider_access_pass
                })
            end
            @connection
        end
        # get a list of images,
        def get_images(family=nil, deprecated=false)
            # if we are looking to include depreacted images get them all
            if deprecated 
                images = connect.images.all
            # if not just get the current ones
            else
                images = connect.images.current
            end

            # if we are to filter on a list of families do so
            if family
                final_images = Array.new
                images.each do |image|
                    if image.family == family
                        final_images.push image
                    end
                end
                # return the filtered list
                final_images
            # if not just return all results
            else
                # return the results
                images
            end
        end
        # get a single machine image by family
        def get_image_name(family)
            image = get_images(family, false)
            if image.length != 1
                raise "Too many images returned for family #{family}, #{image.length} were returned"
            end
            # return the image name
            image.first.name

        end
        
        def all_named_servers(server_name)
            # ***connect.servers.all does not accept any arguments in GCP***
            
            # create empty array
            named_servers=Array.new
            # get all servers
            connect.servers.all.each do | returned_server | 
                # if the server name matches what we are looking for add to the result array
                if returned_server.name == server_name
                    named_servers.push(returned_server)
                end
            end
            # return the list of servers
            named_servers
        end
    end
end
