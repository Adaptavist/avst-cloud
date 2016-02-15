# avst-cloud gem

Automated creation, bootstrapping and provisioning of servers. Currently supports AWS and Rackspace

## Prerequisites
Make sure ruby 2.0 is installed.
The application depends on several gems listed in avst-cloud.gemspec file. Bundle install command will install all dependencies. The most important ones are [Fog.io](https://github.com/fog/fog) and [Derelict](https://rubygems.org/gems/derelict) for provider integration.

## Installation from source

- Download source
- Navigate to folder
- Run bundle install 
- Check the example, modify, try

## Server creation example

### AWS

```

    # Provide your AWS credentials, region, you can specify custom logger on conn object (defaults to: Logger.new(STDOUT))
    conn = AvstCloud::AwsConnection.new(provider_user, provider_pass, region)

    # Creates server on aws, if server exists and it is stopped it will start it
    #
    # server_name - name of newly created server
    # flavour - aws flavour name, defaults to t2.micro
    # os - operating system of ami provided, defaults to ubuntu-14
    # ami_image_id - aws ami id, defaults to ami-f0b11187 running ubuntu-14
    # key_name - aws ssh access key name, admin.pem
    # ssh_key  - lcoal aws ssh access key path - just to make sure you have it :) 
    # subnet_id - aws subnet id
    # security_group_ids - list of aws security groups
    # ebs_size - disk size
    # hdd_device_path - hdd device path, may differ per ami/os
    # availability_zone - aws availability zone
    # vpc - virtual private cloud, defaults to nil, make sure you adjust subned_id and security_group_ids accordingly when setting this option

    server = conn.create_server(server_name, flavour, os, key_name, ssh_key, subnet_id, security_group_ids, ebs_size, hdd_device_path, ami_image_id, availability_zone)
    
    # Stop server
    server.stop

    # Destroy server 
    server.destroy
    
    # Returns setver status
    server.status


```

### Rackspace

```

    conn = AvstCloud::RackspaceConnection.new(provider_user, provider_pass, region)
    # image_id - int representing rackspace image id e.g. '4' - "2GB-standard"
    server = conn.create_server(server_name, image_id)
    
    # Returns setver status
    server.status

    # Stop server
    server.stop

    # Destroy server 
    server.destroy
    

```

## Connecting to existing server

```

conn = AvstCloud::AwsConnection.new(provider_user, provider_pass, region)
# server_name - hostname
# access_user - user to access server as
# ssh_key - full path to access key for your server, or password
# os - if access_user is nil and os provided, it will try to use standard user based on os
server = conn.server(server_name, access_user, ssh_key, os)

```

## Bootstrap

Bootstrap executes pre_upload_commands, custom_file_uploads and post_upload_commands on the server. 

```
    
    server = FogAws::Server.new(provider_user, provider_pass, region)
    # Creates server
    server = conn.create_server(server_name, flavour, os, key_name, ssh_key, subnet_id, security_group_ids, ebs_size, hdd_device_path, ami_image_id, availability_zone)
    
    # Commands will run as "sudo su -c \"#{cmd}\""
    # List of commands running on server before files upload
    pre_upload_commands = [
      "echo 'I was here' >> /tmp/was_here",
    ]

    avst_cloud_base ="#{File.expand_path("../../", __FILE__)}"

    # To allow root user to connect to github and run capistrano provisioning in the next stage
    # Define hash of from_local_path and destination on the server
    custom_file_uploads = {
        "#{avst_cloud_base}/files/id_rsa" => "/tmp/.",
        "#{avst_cloud_base}/files/known_hosts" => "/tmp/."
    }

    post_upload_commands = [
        "mkdir /home/ubuntu/.ssh",
        "mv /tmp/id_rsa /home/ubuntu/.ssh/.",
        "mv /tmp/known_hosts /home/ubuntu/.ssh/.",
        "chmod 0600 /home/ubuntu/.ssh/known_hosts",
        "chmod 0600 /home/ubuntu/.ssh/id_rsa",
        "echo 'done here'"
    ]

    remote_server_debug = true
    debug_structured_log = false

    server.bootstrap(pre_upload_commands, custom_file_uploads, post_upload_commands, remote_server_debug, debug_structured_log)

```

## Provisioning

Uses Capistrano to download source from git repo (branch or tag) to destination_folder (defaults to /var/opt/puppet/current/ ) on the server. Make sure git is installed on the server and user has access to git repo provided. Make sure destination_folder exists and user (aws - ubuntu - ubuntu, centos - ec2-user, debian - admin) has ownership of it. 

If puppet_runner param is defined:

* create avst_cloud_tmp_folder on the server
* uploads the content of local folder config/custom_system_config to it and then moves it to destination_folder
* if puppet_runner_prepare is defined, it will run it 
* r10k puppetfile install
* clear /etc/puppet folder
* link /var/opt/puppet/current to /etc/puppet
* links /var/opt/puppet/current/hiera.yaml to /etc/hiera.yaml
* if config/keys folder exists it will upload it to /etc/puppet/config
* executes command passed as puppet_runner param in /etc/puppet folder on the server

If custom_provisioning_command is defined, it will run the command on the server.

```

    avst_cloud_tmp_folder = "/tmp/avst_cloud_tmp_#{Time.now.to_i}"
    reference = nil
    git = "ssh://git@stash.adaptavist.com:7999/pup/base_puppet_templates.git"
    branch = "master"
    puppet_runner = nil 
    puppet_runner_prepare = nil
    custom_provisioning_command = "echo 'done' >> /tmp/done",
    destination_folder = nil
    server.provision(git, branch, server_tmp_folder, reference, custom_provisioning_commands, puppet_runner, puppet_runner_prepare, destination_folder)


```

## Cleanup 

Cleans after provisioning. Runs yum clean all or apt-get clean based on os. Also removes avst_cloud_tmp_folder. You can specify custom commands to run afterwards.

```

  # avst_cloud_tmp_folder = "/tmp/avst_cloud_tmp_*"
  # server_name - name of newly created server
  # custom_cleanup_commands - list of commands to run
  # cloud_operating_system - os
  # remote_server_debug - enable debug

  server.post_provisioning_cleanup(custom_commands, cloud_operating_system, remote_server_debug, server_tmp_folder)


```

## Example no puppet run

See example executable bin/avst-cloud

## Example puppet run

Make sure that provided repo contains templates and base setup. An example is available in Adaptavist github account. Make sure ruby 2.0.0, git, puppet, puppet-runner,... is installed. Check full example in bin/avst-cloud-puppet

```

# url to git repo you want to upload to the server
git = "git@github.com:Adaptavist/base_puppet_templates.git" # url to git repo
branch = "master" # branch
reference = nil # tag
# In this example we are using puppet-runner to apply our puppet configs, check doco
puppet_runner = "puppet-runner start"
puppet_runner_prepare = "puppet-runner prepare -c ./hiera-configs -d ./hiera -f ./environments/production/modules/hosts/facts.d -t ./hiera-configs -r ./hiera-configs/puppetfile_dictionary.yaml -o ./Puppetfile -e /var/opt/puppet/secure/keys"

custom_provisioning_commands = ["echo 'done' >> /tmp/done"]
# defaults to /var/opt/puppet
destination_folder = nil

server.provision(git, branch, server_tmp_folder, reference, custom_provisioning_commands, puppet_runner, puppet_runner_prepare, destination_folder)

```
