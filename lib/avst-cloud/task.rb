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

require_relative './logging.rb'

module AvstCloud
    class Task
        include Logging
        def initialize(debug = false)
            @debug = debug
        end
        def execute(server)
            raise 'Unimplemented...'
        end
    end

    class SshTask < AvstCloud::Task
        include Logging
        def execute(server)
            unless server.ip_address
                logger.error 'Can not find host'.red
                raise 'Can not find ip address, access_user or access_password'
            end

            unless server.access_user
                logger.error 'Access user not found. Please provide username for this server.'.red
                raise 'Access user not found. Please provide username for this server.'
            end

            unless server.access_password
                logger.error 'Password not found. Please provide password or pem key for this server.'.red
                raise 'Password not found. Please provide root_password in config. for this server.'
            end

            logger.debug "Using #{server.access_user}@#{server.ip_address} with #{server.access_password} to perform ssh task."
            attempts = 1
            success = false
            max_attempts = 50
            while attempts < max_attempts and !success
                begin
                    Net::SSH.start(server.ip_address, server.access_user, :password => server.access_password, :keys => [server.access_password]) do |session|
                        ssh_command session
                    end
                    success = true
                rescue Errno::ECONNREFUSED
                    logger.debug "Connection refused. Server may not have booted yet. Sleeping #{attempts}/#{max_attempts}"
                    sleep(10)
                    attempts=attempts+1
                rescue Errno::ETIMEDOUT
                    logger.debug "Connection timed out. Server may not have booted yet. Sleeping #{attempts}/#{max_attempts}"
                    sleep(10)
                    attempts=attempts+1
                end
            end
            unless success
                logger.error 'Bootstrapping: failed to find server to connect to'
                raise 'Bootstrapping: failed to find server to connect to'
            end
        end

        def ssh_command(session)
            raise 'Unimplemented...'
        end
    end

    class SshCommandTask < AvstCloud::SshTask
        include Logging

        def initialize(cmds, debug = false, structured_log = false)
            @cmds = cmds
            @debug = debug
            @structured_log = structured_log
        end

        def ssh_command(session)
            Array(@cmds).each do |cmd|
                next unless cmd
                cmd.strip!
                next if cmd == ""
                logger.debug("Running command on server as root: sudo su -c \"#{cmd}\"")
                start_time = Time.now

                session.exec!("sudo su -c \"#{cmd}\"") do |ch, stream, data|
                    if @debug
                        logger.debug "Got this on the #{stream} stream: "
                        if @structured_log && logger.methods.include?(:log_structured_code)
                            logger.log_structured_code(data)
                        else
                            logger.debug(data)
                        end
                    end
                end
                total_time = Time.now - start_time
                logger.debug("Completed in #{total_time} seconds")
            end
        end
    end

    # In case Requiretty is set in sudoers disable it for bootstrapping and provisioning
    # for user that performs it
    class DisableRequireTty < AvstCloud::SshTask
        include Logging
        def initialize(for_user)
            @for_user = for_user
        end
        def ssh_command(session)
            session.open_channel do |channel|
                channel.request_pty do |ch, success|
                    raise 'Error requesting pty' unless success

                    ch.send_channel_request('shell') do |ch, success|
                        raise 'Error opening shell' unless success
                    end
                end
                channel.on_data do |ch, data|
                    if @debug
                        STDOUT.print data
                    end
                end
                channel.on_extended_data do |ch, type, data|
                    STDOUT.print "Error: #{data}\n"
                end
                channel.send_data("sudo su -c 'echo 'Defaults:#{@for_user}\\ \\!requiretty' >> /etc/sudoers'\n")
                channel.send_data("exit\n")
                session.loop
            end
        end
    end

    class WaitUntilReady < AvstCloud::SshTask
        include Logging

        def ssh_command(session)
            session.open_channel do |channel|
                channel.request_pty do |ch, success|
                    raise 'Error requesting pty' unless success

                    ch.send_channel_request("shell") do |ch, success|
                        raise 'Error opening shell' unless success
                    end
                end
                channel.on_data do |ch, data|
                    if @debug
                        STDOUT.print data
                    end
                end
                channel.on_extended_data do |ch, type, data|
                    STDOUT.print "Error: #{data}\n"
                end
                channel.send_data("echo \"ready\"\n")
                channel.send_data("exit\n")
                session.loop
            end
        end
    end

    class CapistranoDeploymentTask < AvstCloud::Task
        include Logging

        def initialize(git, branch, server_tmp_folder = "/tmp/avst_cloud_tmp_#{Time.now.to_i}", reference = nil, custom_provisioning_commands = [], puppet_runner = nil, puppet_runner_prepare = nil, destination_folder = '/var/opt/puppet')
            unless git and (branch or reference)
                logger.debug "You have to provide git repo url #{git} and git branch #{branch} or git tag reference #{reference}".red
                raise "You have to provide git repo url #{git} and git branch #{branch} or git tag reference #{reference}"
            end

            @git = git
            @branch = branch
            @server_tmp_folder = server_tmp_folder
            @reference = reference
            @custom_provisioning_commands = custom_provisioning_commands || []
            @puppet_runner = puppet_runner
            @puppet_runner_prepare = puppet_runner_prepare
            @destination_folder = destination_folder || '/var/opt/puppet'
        end

        def execute(server)
            unless server.ip_address
                logger.error 'Can not find host'.red
                raise 'Can not find ip address, access_user or access_password'
            end

            unless server.access_user
                logger.error 'Access user not found. Please provide username for this server.'.red
                raise 'Access user not found. Please provide username for this server.'
            end

            unless server.access_password
                logger.error 'Password not found. Please provide password or pem key for this server.'.red
                raise 'Password not found. Please provide root_password in config. for this server.'
            end

            logger.debug "Using #{server.access_user}@#{server.ip_address} with #{server.access_password}"


            # Initiate capistrano deploy script to download the laters code and provision the server
            require 'capistrano/all'
            require 'capistrano/setup'
            require 'capistrano/deploy'
            Dir.glob("#{File.dirname __dir__}/capistrano/tasks/*.rake").each { |r| load r }
            # cap production deploy
            ENV['cap_git_repo_url'] = @git
            ENV['cap_branch_name'] = @branch
            ENV['cap_reference_name'] = @reference
            ENV['cap_ip_address'] = server.ip_address
            ENV['cap_access_password'] = server.access_password
            ENV['cap_access_user'] = server.access_user
            ENV['server_name'] = server.server_name
            ENV['puppet_runner'] = @puppet_runner
            ENV['puppet_runner_prepare'] = @puppet_runner_prepare
            ENV['avst_cloud_tmp_folder'] = @server_tmp_folder
            ENV['custom_provisioning_commands'] = @custom_provisioning_commands.to_json
            ENV['destination_folder'] = @destination_folder
            logger.debug "Using git #{@git} branch #{@branch} to provision #{server.ip_address}"

            Capistrano::Application.invoke('production')
            Capistrano::Application.invoke('deploy')
            logger.debug "You can connect to server on #{server.ip_address}"
        end
    end

    class PostProvisionCleanup < AvstCloud::SshCommandTask

        def initialize(os, debug, tmp_folder = "/tmp/avst_cloud_tmp_#{Time.now.to_i}")
            super(make_commands(os, tmp_folder), debug, false)
        end

        def make_commands(os, tmp_folder)
            cmds = []
            case os
                when /ubuntu/, /debian/
                    cmds << 'apt-get clean'

                when /centos/, /redhat/
                    cmds << 'yum clean all'
            end
            cmds << "rm -rf #{tmp_folder}"
            cmds
        end
    end

    class ScpTask < AvstCloud::Task
        include Logging

        def initialize(files)
            @files = files
        end

        def execute(server)
            unless server.ip_address
                logger.error 'Can not find host'.red
                raise 'Can not find ip address, access_user or access_password'
            end

            unless server.access_user
                logger.error 'Access user not found. Please provide username for this server.'.red
                raise 'Access user not found. Please provide username for this server.'
            end

            unless server.access_password
                logger.error 'Password not found. Please provide password or pem key for this server.'.red
                raise 'Password not found. Please provide root_password in config. for this server.'
            end

            logger.debug "Using #{server.access_user}@#{server.ip_address} with #{server.access_password}"
            Net::SCP.start( server.ip_address, server.access_user, :password => server.access_password, :keys => [server.access_password] ) do |scp|
                @files.each do |local_file, remote_path|
                    upload_file(scp, local_file, remote_path)
                end
            end
        end

        def upload_file(scp, local_path, remote_path)
            logger.debug("Uploading file on server: #{local_path} to #{remote_path}")
            scp.upload!( local_path, remote_path)
        end
    end
end
