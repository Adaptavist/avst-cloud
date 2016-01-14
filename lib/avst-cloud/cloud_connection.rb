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
    class CloudConnection
        include Logging
        attr_accessor :connection, :provider, :provider_user, :provider_pass
        
        def initialize(provider, provider_user, provider_pass)
            @provider = provider
            @provider_access_user = provider_user
            @provider_access_pass = provider_pass
        end
        
        # Abstract classes to be implemented per provider
        UNIMPLEMENTED="Unimplemented..."        
        
        def server(server_name, root_user, root_password, os=nil)
            raise UNIMPLEMENTED
        end

        def list_known_servers
           raise UNIMPLEMENTED 
        end
    end
end