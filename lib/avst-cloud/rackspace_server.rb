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

require_relative './cloud_server.rb'

module AvstCloud
    class RackspaceServer < AvstCloud::CloudServer

        def stop
            if @server
                logger.debug "Stopping #{@server_name}"
                shutdown_command = AvstCloud::SshCommandTask.new(['shutdown -h now'])
                begin
                    run_tasks([AvstCloud::WaitUntilReady.new, shutdown_command])
                rescue IOError => e
                    logger.debug "Connection closed #{e.message}"
                    unless e.message == "closed stream"
                        raise "Error while shutting down server. Expected Connection closed. Got #{e.message}"
                    end
                end
                logger.debug "Waiting for SHUTOFF state..."
                wait_for_state() {|serv| serv.state == 'SHUTOFF'}
                logger.debug "[DONE]\n\n"
                logger.debug "Server #{@server_name} stopped...".green
            else
                raise "Server #{@server_name} does not exist!".red
            end
        end
        
        def start
            if @server
                logger.debug "Starting #{@server_name}"
                @server.reboot 'HARD'
                logger.debug "Waiting for ACTIVE state..."
                wait_for_state() {|serv| serv.ready?}
                logger.debug "[DONE]\n\n"
                logger.debug "Server #{@server_name} started...".green
            else
                raise "Server #{@server_name} does not exist!".red
            end
        end

        def destroy
            if @server
                logger.debug "Killing #{@server_name}"
                @server.destroy
                logger.debug "Server #{@server_name} destroyed...".green
            else
                raise "Server #{@server_name} does not exist!".red
            end
        end
    end
end