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

module AvstCloud
    
    class AwsConnection < AvstCloud::CloudConnection
        
        attr_accessor :region

        def initialize(provider_user, provider_pass, region)
            super('aws', provider_user, provider_pass)
            @region = region
        end
        
        def server(server_name, root_user, root_password, os=nil)
            server = find_fog_server(server_name)
            if !root_user and os
                root_user = user_from_os(os)
            end
            AvstCloud::AwsServer.new(server, server_name, server.public_ip_address, root_user, root_password)
        end

        def create_server(server_name, flavour, os, key_name, ssh_key, subnet_id, security_group_ids, ebs_size, hdd_device_path, ami_image_id, availability_zone, vpc=nil, created_by=nil, custom_tags={})

            # Permit named instances from DEFAULT_FLAVOURS
            flavour = flavour || "t2.micro"
            os = os || "ubuntu-14"
            ami_image_id = ami_image_id || "ami-f0b11187"
            device_name = hdd_device_path || '/dev/sda1'

            root_user = user_from_os(os)
            unless File.file?(ssh_key)
                logger.error "Could not find local SSH key '#{ssh_key}'".red
                raise "Could not find local SSH key '#{ssh_key}'"
            end

            existing_servers    = all_named_servers(server_name)
            restartable_servers = existing_servers.select{ |serv| serv.state == 'stopped' }
            running_servers     = existing_servers.select{ |serv| serv.state != 'stopped' && serv.state != 'terminated' }

            if running_servers.length > 0
                running_servers.each do |server|
                    logger.error "Server #{server_name} with id #{server.id} found in state: #{server.state}".yellow
                end
                raise "Server with the same name found!"

            elsif restartable_servers.length > 0
                if restartable_servers.length > 1
                    running_servers.each do |server|
                        logger.error "Server #{server_name} with id #{server.id} found in state: #{server.state}. Can not restart".yellow
                    end
                    raise "Too many servers can be restarted."
                end
                server = restartable_servers.first
                server.start
                result_server = AvstCloud::AwsServer.new(server, server_name, server.public_ip_address, root_user, ssh_key)
                result_server.wait_for_state() {|serv| serv.ready?}
                logger.debug "[DONE]\n\n"
                logger.debug "The server was successfully re-started.\n\n"
                result_server
            else
                logger.debug "Creating EC2 server:"
                logger.debug "Server name        - #{server_name}"
                logger.debug "Operating system   - #{os}"
                logger.debug "image_template_id  - #{ami_image_id}"
                logger.debug "flavour            - #{flavour}"
                logger.debug "key_name           - #{key_name}"
                logger.debug "ssh_key            - #{ssh_key}"
                logger.debug "subnet_id          - #{subnet_id}"
                logger.debug "security_group_ids - #{security_group_ids}"
                logger.debug "region             - #{@region}"
                logger.debug "availability_zone  - #{availability_zone}"
                logger.debug "ebs_size           - #{ebs_size}"
                logger.debug "hdd_device_path    - #{device_name}"
                logger.debug "vpc                - #{vpc}"

                create_ebs_volume = nil
                if ebs_size
                    # in case of centos ami we need to use /dev/xvda this is ami dependent
                    create_ebs_volume = [ 
                                            { 
                                                :DeviceName => device_name,
                                                'Ebs.VolumeType' => 'gp2',
                                                'Ebs.VolumeSize' => ebs_size,
                                            } 
                                        ]
                end
                tags = {
                    'Name' => server_name,
                    'os' => os
                }
                if created_by 
                    tags['created_by'] = created_by
                end
                tags.merge!(custom_tags)
                # create server
                server = connect.servers.create :tags => tags,
                                                :flavor_id => flavour,
                                                :image_id => ami_image_id,
                                                :key_name => key_name,
                                                :subnet_id => subnet_id,
                                                :associate_public_ip => true,
                                                :security_group_ids => security_group_ids,
                                                :availability_zone => availability_zone,
                                                :block_device_mapping => create_ebs_volume,
                                                :vpc => vpc

                
                result_server = AvstCloud::AwsServer.new(server, server_name, nil, root_user, ssh_key)
                # result_server.logger = logger
                # Check every 5 seconds to see if server is in the active state (ready?).
                # If the server has not been built in 5 minutes (600 seconds) an exception will be raised.
                result_server.wait_for_state() {|serv| serv.ready?}

                logger.debug "[DONE]\n\n"

                logger.debug "The server has been successfully created, to login onto the server:\n"
                logger.debug "\t ssh -i #{ssh_key} #{root_user}@#{server.public_ip_address}\n"
            
                result_server.ip_address = server.public_ip_address
                result_server
            end
        end

        def server_status(server_name)
            servers = all_named_servers(server_name).select{|serv| serv.state != 'terminated'}
            if servers.length > 0
                servers.each do |server|
                    logger.debug "Server #{server.id} with name '#{server_name}' exists and has state: #{server.state}"
                end
            else
                logger.debug "Server not found for name: #{server_name}"
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
            servers = all_named_servers(server_name).select{|serv| serv.state != 'terminated'}
            unless servers.length == 1    
                logger.debug "Found #{servers.length} servers for name: #{server_name}".yellow
                if should_fail
                    raise "Found #{servers.length} servers for name: #{server_name}"
                end
            end
            servers.first
        end

    private
        def user_from_os(os)
            case os.to_s
                when /^ubuntu/
                    user = "ubuntu"
                when /^debian/
                    user = "admin"
                when /^centos/
                    user = "ec2-user"
                when /^redhat/
                    user = "ec2-user"
                else
                    user = "root"
            end
            user
        end
        def connect
            unless @connection
                logger.debug "Creating new connection to AWS"
                @connection = Fog::Compute.new({
                    :provider               => 'AWS',
                    :region                 => @region,
                    :aws_access_key_id      => @provider_access_user,
                    :aws_secret_access_key  => @provider_access_pass
                })
            end
            @connection
        end
        
        def all_named_servers(server_name)
            connect.servers.all({'tag:Name' => server_name})
        end
    end
end