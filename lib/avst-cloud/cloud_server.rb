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
require_relative './task.rb'

module AvstCloud
    class CloudServer
        include Logging
        attr_accessor :server, :server_name, :ip_address, :access_user, :access_password

        def initialize(server, server_name, ip_address, access_user, access_password)
            @server = server
            @ip_address = ip_address
            @server_name = server_name
            @access_user = access_user
            @access_password = access_password
        end 

        def bootstrap(pre_upload_commands, custom_file_uploads, post_upload_commands, remote_server_debug, debug_structured_log, enable_sudo="false")
            logger.debug "Bootstrapping #{server_name}...".green
            run_tasks([AvstCloud::WaitUntilReady.new])
            disable_tty_task = AvstCloud::DisableRequireTty.new(@access_user, @access_password, enable_sudo)
            pre_upload_commands_tasks = AvstCloud::SshCommandTask.new(pre_upload_commands, remote_server_debug, debug_structured_log)
            custom_file_uploads_tasks = AvstCloud::ScpTask.new(custom_file_uploads)
            post_upload_commands_tasks = AvstCloud::SshCommandTask.new(post_upload_commands, remote_server_debug, debug_structured_log)
            run_tasks([disable_tty_task, pre_upload_commands_tasks, custom_file_uploads_tasks, post_upload_commands_tasks])
            logger.debug "Bootstrap done. You can connect to server as #{@access_user} on #{@ip_address}"
        end

        def provision(git, branch, server_tmp_folder, reference, custom_provisioning_commands, puppet_runner, puppet_runner_prepare, destination_folder)
            logger.debug "Provisioning #{@server_name}..."
            provision_task = AvstCloud::CapistranoDeploymentTask.new(git, branch, server_tmp_folder, reference, custom_provisioning_commands, puppet_runner, puppet_runner_prepare, destination_folder)
            run_tasks([AvstCloud::WaitUntilReady.new, provision_task])
            logger.debug "Provisioning done. You can connect to server on #{@ip_address}"
        end

        def post_provisioning_cleanup(custom_commands, os, remote_server_debug, server_tmp_folder)
            logger.debug "Cleaning up after provisioning #{server_name}..."
            custom_cleanup_commands = AvstCloud::SshCommandTask.new(custom_commands, remote_server_debug, true)
            run_tasks([AvstCloud::WaitUntilReady.new, AvstCloud::PostProvisionCleanup.new(os, remote_server_debug, server_tmp_folder), custom_cleanup_commands])
            logger.debug "Post provisioning cleanup done. You can connect to server as #{@access_user} on #{@ip_address}"
        end

        def run_tasks(tasks)
            Array(tasks).each do |task|
                task.execute self
            end
        end

        def status
            @server.state
        end

        def wait_for_state(&cond)
            logger.debug "Waiting for state change...".yellow
            @server.wait_for(600, 5) do
                print "."
                STDOUT.flush
                cond.call(self)
            end
        end

        # Abstract classes to be implemented per provider
        UNIMPLEMENTED="Unimplemented..."
        def stop
            raise UNIMPLEMENTED
        end

        def start
            raise UNIMPLEMENTED
        end

        def destroy
            raise UNIMPLEMENTED
        end
    end
end