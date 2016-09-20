
lock '3.2.1'

set :application, 'my_app_name'
set :repo_url, ENV["cap_git_repo_url"]
set :branch, ENV["cap_reference_name"] || ENV["cap_branch_name"] || "master" 

# Default branch is :master
# ask :branch, proc { `git rev-parse --abbrev-ref HEAD`.chomp }.call

# Default deploy_to directory is /var/www/my_app
set :deploy_to, ENV["destination_folder"]

# Default value for :scm is :git
set :scm, :git

# Default value for :format is :pretty
set :format, :pretty

# Default value for :log_level is :debug
# set :log_level, :debug

# Default value for :pty is false
set :pty, true

# Default value for :linked_files is []
# set :linked_files, %w{config/database.yml}

# Default value for linked_dirs is []
# set :linked_dirs, %w{bin log tmp/pids tmp/cache tmp/sockets vendor/bundle public/system}
# set :use_sudo, true
# set :pty, true
# default_run_options[:pty] = true

set :ssh_options, {
  forward_agent: false,
  keys: [ENV["cap_access_password"]]
}

server ENV["cap_ip_address"], user: ENV["cap_access_user"], port: 22, password: ENV["cap_access_password"], roles: %w{app}

# Default value for default_env is {}
# set :default_env, { path: "/usr/local/rvm/rubies/ruby-2.1.2/bin/:/usr/local/rvm/gems/ruby-2.1.2/bin/:$PATH" }

# Default value for keep_releases is 5
set :keep_releases, 50000

after 'deploy', 'prepare_puppet_and_execute'

require "rvm/capistrano"
set :rvm_ruby_string, :local

namespace :deploy do

  desc 'Restart application'
  task :restart do
    on roles(:app), in: :sequence, wait: 5 do
      # Your restart mechanism here, for example:
      # execute :touch, release_path.join('tmp/restart.txt')
    end
  end

  after :publishing, :restart

  after :restart, :clear_cache do
    on roles(:web), in: :groups, limit: 3, wait: 10 do
      # Here we can do anything such as:
      # within release_path do
      #   execute :rake, 'cache:clear'
      # end
    end
  end

end
