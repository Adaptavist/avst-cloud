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
require 'json'

desc "Install stuff"
task :prepare_puppet_and_execute do
    on roles(:app) do |host|
        if ENV["puppet_runner"]
            SSHKit.config.command_map[:link_puppet] = "sudo su -c 'ln -s /var/opt/puppet/current /etc/puppet'"
            SSHKit.config.command_map[:link_hiera] = "sudo su -c 'cd /etc && sudo rm -f hiera.yaml && sudo ln -sf /var/opt/puppet/current/hiera.yaml .'"
            SSHKit.config.command_map[:clear_puppet] = "sudo su -c 'rm -fr /etc/puppet'"
            SSHKit.config.command_map[:create_puppet_files] = "sudo su -c 'if [ ! -d /var/opt/puppet/current/files ]; then mkdir /var/opt/puppet/current/files; fi'"
            SSHKit.config.command_map[:r10k] = "sudo su -c 'source /usr/local/rvm/scripts/rvm; r10k puppetfile install'"
            SSHKit.config.command_map[:execute_puppet_runner] = "sudo su -c 'source /usr/local/rvm/scripts/rvm; #{ENV["puppet_runner"]}'"
            SSHKit.config.command_map[:cleanup_configs_from_hiera_configs] = "sudo su -c 'find /var/opt/puppet/current/hiera-configs -maxdepth 1 -type f ! -name \'puppetfile_dictionary_v4.yaml\' ! -name \'puppetfile_dictionary.yaml\' ! -name \'#{ENV["server_name"]}.yaml\' ! -name \'#{ENV["server_name"]}_facts.yaml\' -exec rm -f {} + '"

            # create folder in /tmp to store custom configs, this will be deleted by clean command
            avst_cloud_tmp_folder = ENV["avst_cloud_tmp_folder"]
            execute "mkdir #{avst_cloud_tmp_folder}"

            if File.exist?("#{ENV["avst_cloud_config_dir"]}/custom_system_config")
                upload! "#{ENV["avst_cloud_config_dir"]}/custom_system_config", avst_cloud_tmp_folder, recursive: true
                execute "cp -rf #{avst_cloud_tmp_folder}/custom_system_config/* /var/opt/puppet/current/."
            end

            execute :cleanup_configs_from_hiera_configs

            if ENV['puppet_runner_prepare']
                SSHKit.config.command_map[:puppet_runner_prepare] = "sudo su -c 'source /usr/local/rvm/scripts/rvm; #{ENV["puppet_runner_prepare"]}'"
                within '/var/opt/puppet/current' do
                    execute :puppet_runner_prepare
                end
            end

            within '/var/opt/puppet/current' do
                execute :r10k
            end
            
            puts "Done r10k puppetfile install"

            execute :clear_puppet
            execute :create_puppet_files
            execute :link_puppet
            execute :link_hiera

            if File.exist?("#{ENV["avst_cloud_config_dir"]}/keys")
                upload! "#{ENV["avst_cloud_config_dir"]}/keys", "/etc/puppet/config", recursive: true
            end

            within '/etc/puppet' do
                begin
                        execute :execute_puppet_runner
                rescue Exception => e
                        # Puppet apply is running with --detailed-exitcodes, exit codes are:
                        #  '2' means there were changes, an exit code of '4' means there were failures during the transaction, 
                        # and an exit code of '6' means there were both changes and failures.
                        ret_code = e.message.gsub("execute_puppet_runner exit status: ", "").strip.to_i
                        # in case the code is not 2, raise exception as there were failures
                        if ( ret_code != 2)
                                raise e
                        end
                end
            end
        end

        if ENV["custom_provisioning_commands"]
            parsed = JSON.parse(ENV["custom_provisioning_commands"])
            if parsed.is_a?(Array)
                parsed.each do |command|
                    command_name = command.to_sym
                    SSHKit.config.command_map[command_name] = command
                    execute command_name
                end
            else
                SSHKit.config.command_map[:custom_provisioning_commands] = ENV["custom_provisioning_commands"]
                execute :custom_provisioning_commands
            end
        end

        puts "Done running puppet apply"
    end
end
