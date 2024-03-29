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

        def create_server(server_name, flavour, os, key_name, ssh_key, subnet_id, security_group_ids, ebs_size, hdd_device_path, ami_image_id, availability_zone, additional_hdds={}, vpc=nil, created_by=nil, custom_tags={}, root_username=nil, create_elastic_ip=false, encrypt_root=false ,root_encryption_key=nil, delete_root_disk=true, root_disk_type='gp2', root_disk_iops=0, root_disk_throughput=0, private_ip=nil, public_ip=nil)
            # Permit named instances from DEFAULT_FLAVOURS
            flavour = flavour || "t2.micro"
            os = os || "ubuntu-14"
            ami_image_id = ami_image_id || "ami-f0b11187"
            device_name = hdd_device_path || '/dev/sda1'

            root_user = root_username || user_from_os(os)
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
                logger.debug "root user          - #{root_user}"
                logger.debug "subnet_id          - #{subnet_id}"
                logger.debug "security_group_ids - #{security_group_ids}"
                logger.debug "region             - #{@region}"
                logger.debug "availability_zone  - #{availability_zone}"
                logger.debug "ebs_size           - #{ebs_size}"
                logger.debug "hdd_device_path    - #{device_name}"
                logger.debug "additional_hdds    - #{additional_hdds}"
                logger.debug "vpc                - #{vpc}"
                logger.debug "create_elastic_ip  - #{create_elastic_ip}"
                logger.debug "custom_private_ip  - #{private_ip}"

                elastic_ip_address = nil

                # if a public IP has been specified, try to lookup the elastic IP and use it
                if public_ip
                    require "resolv"
                    # we can find IP based on either its address or its Name tag, if the provided value is not an IP try by tag
                    if public_ip  =~ Resolv::IPv4::Regex
                        found_eip = connect.describe_addresses('public-ip' => [public_ip])
                    else
                        found_eip = connect.describe_addresses('tag:Name' => [public_ip])
                    end
                    if ! found_eip.data[:body]['addressesSet'][0].nil?
                        # if we have found the IP and its not already associated use it
                        if found_eip.data[:body]['addressesSet'][0]['publicIp'] and ! found_eip.data[:body]['addressesSet'][0]['associationId']
                            elastic_ip =found_eip.data[:body]['addressesSet'][0]
                            elastic_ip_address = elastic_ip['publicIp']
                            logger.debug "Requested Elastic IP found and is unallocated, an attempt to attach this to the VM will be made"
                        else
                             logger.warn "Requested Elastic IP exist but is already allocated, the system will be created but will NOT use this IP"
                        end
                    else
                        logger.warn "Requested Elastic IP does not exist, the system will be created but will NOT use this IP"
                    end
                end

                create_ebs_volume = nil
                if ebs_size
                    # in case of centos ami we need to use /dev/xvda this is ami dependent
                    root_disk = { 
                        :DeviceName => device_name,
                        'Ebs.VolumeType' => root_disk_type,
                        'Ebs.VolumeSize' => ebs_size,
                    } 
                    # if the root disk is to be encrypted set te "Encrypted" flag to true, if there is an optional KMS Key ID send that,
                    # if not set to nil and thereby defalt to the default key for EBS
                    if encrypt_root
                        root_disk.merge!('Ebs.Encrypted' => true, 'Ebs.KmsKeyId' => root_encryption_key||nil )
                    end

                    # if we do not want to delete the root disk with the VM set the flag
                    if delete_root_disk == false || delete_root_disk == 'false'
                        root_disk.merge!('Ebs.DeleteOnTermination' => false)
                    end

                    # if this is a provisioned IOPS disk set the iops value
                    if root_disk_type == 'io1' or root_disk_type == 'io2'
                        root_disk.merge!('Ebs.Iops' => root_disk_iops)
                    elsif root_disk_type == 'gp3'
                        # set default GP3 values if no valued provided
                        root_disk_iops = 3000 if root_disk_iops == 0
                        root_disk_throughput = 125 if root_disk_throughput == 0

                        root_disk.merge!('Ebs.Iops' => root_disk_iops)
                        root_disk.merge!('Ebs.Throughput' => root_disk_throughput)
                    end
                    # add the root disk as the first entry in the array of disks to create/attach
                    create_ebs_volume = [ root_disk ] 

                    if additional_hdds and additional_hdds.is_a?(Hash)
                        additional_hdds.each_value do |disk|
                            volume_type = disk['volume_type'] || 'gp2'
                            if disk['device_name'] && disk['ebs_size']
                                disk_hash = {
                                    :DeviceName => disk['device_name'],
                                    'Ebs.VolumeType' => volume_type,
                                    'Ebs.VolumeSize' => disk['ebs_size']
                                }
                                # if the additional disk is to be encrypted set te "Encrypted" flag to true, if there is an optional KMS Key ID send that,
                                # if not set to nil and thereby defalt to the default key for EBS
                                if disk['encrypted']
                                    disk_hash.merge!('Ebs.Encrypted' => true, 'Ebs.KmsKeyId' => disk['encryption_key_id'] || nil)
                                end

                                # if we do not want to delete the additional disk with the VM set the flag
                                if disk['delete_disk_with_vm'] == false || disk['delete_disk_with_vm'] == 'false'
                                    disk_hash.merge!('Ebs.DeleteOnTermination' => false)
                                end

                                # if the additional disk is an provisioned IOPS disk set the iops value
                                if volume_type == 'io1' or volume_type == 'io2'
                                    disk_hash.merge!('Ebs.Iops' => disk['volume_iops'] || 0)
                                elsif volume_type == 'gp3'
                                    disk_hash.merge!('Ebs.Iops' => disk['volume_iops'] || 3000)
                                    disk_hash.merge!('Ebs.Throughput' => disk['volume_throughput'] || 125)
                                end

                                # add this disk to the array of all disks to create/attach
                                create_ebs_volume << disk_hash
                            else
                                logger.warn "Failed to create additional hdd, required params device_name (e.g. /dev/sda1) or ebs_size missing: #{disk}"
                            end 
                        end 
                    end
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
                                                :vpc => vpc,
                                                :private_ip_address => private_ip
                
                result_server = AvstCloud::AwsServer.new(server, server_name, nil, root_user, ssh_key)
                # result_server.logger = logger
                # Check every 5 seconds to see if server is in the active state (ready?).
                # If the server has not been built in 5 minutes (600 seconds) an exception will be raised.
                result_server.wait_for_state() {|serv| serv.ready?}

                logger.debug "[DONE]\n\n"

                # create Elastic IP Address if required
                if create_elastic_ip  
                    if elastic_ip_address.nil?
                        logger.debug("Attempting to create elastic IP address")
                        elastic_ip = connect.allocate_address("vpc").body
                        elastic_ip_address = elastic_ip['publicIp']
                        logger.warn "Elastic IP creation failed, proceeding with non Elastic IP\n\n"  if ! elastic_ip_address
                    else
                        logger.warn "You have asked to create an Elastic IP and ALSO use an existing one"
                        logger.warn "The existing IP is avaliable and as such will be used INSTEAD of creating a new one!"
                    end
                end

                # if we have a server id and an Elastic public IP attempt to join the two togehter
                if server.id and elastic_ip_address
                    logger.debug ("Attempting to allocate Elastic IP #{elastic_ip_address} to server")
                    connect.associate_address(server.id, elastic_ip_address)
                    # reacquire server object as IP has, probably, changed
                    server = find_fog_server(server_name)

                    # create tag on the Elastic IP 
                    # TODO: add ability for other tags to be defined by the user
                    logger.debug("Creating tags on Elastic IP Address #{elastic_ip}\n\n")
                    connect.tags.create(:resource_id => elastic_ip['allocationId'], :key => "Name", :value => server_name)
                else
                    logger.warn("EAllocation of Elastic IP failed, proceeding with non Elastic IP\n\n")
                end

                logger.debug "The server has been successfully created, to login onto the server:\n"
                logger.debug "\t ssh -i #{ssh_key} #{root_user}@#{server.public_ip_address}\n"
                if create_ebs_volume
                    logger.debug("Creating tags on ebs volumes")
                    ebs_volumes = server.block_device_mapping
                    logger.debug("Creating tags on ebs volumes #{ebs_volumes}")
                    ebs_volumes.each do |ebs_volume|
                        if ebs_volume['volumeId']
                            tags.each do |key, value|
                                connect.tags.create(:resource_id => ebs_volume['volumeId'], :key => key, :value => value)
                            end
                        end
                    end
                end
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

        def delete_elastic_ip(ip_address)
            address = is_elastic_ip(ip_address)
            if address
                logger.debug "Found Elastic IP #{address.public_ip}, attempting to delete"
                logger.debug "Elastic IP #{ip_address} deleted" if address.destroy 
                return true
            else
                logger.debug "IP #{ip_address} does NOT appear to be an Elastic IP"
            end
            return false
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

        def is_elastic_ip(ip_address)
            connect.addresses.each do |address|
                if address.public_ip == ip_address
                    return address
                end
            end
            return false
        end
    end
end
