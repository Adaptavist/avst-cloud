# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
    spec.name          = "avst-cloud"
    spec.version       = '0.1.42'
    spec.authors       = ["Martin Brehovsky", "Jon Bevan", "Matthew Hope"]
    spec.email         = ["mbrehovsky@adaptavist.com", "jbevan@adaptavist.com", "mhope@adaptavist.com"]
    spec.summary       = %q{Automated creation, bootstrapping and provisioning of servers }
    spec.description   = %q{Automated creation, bootstrapping and provisioning of servers}
    spec.homepage      = "http://www.adaptavist.com"

    spec.files         = `git ls-files -z`.split("\x0")
    spec.executables   = ["avst-cloud", "avst-cloud-puppet", "avst-cloud-rackspace", "avst-cloud-azure", "avst-cloud-azure-rm"]
    spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
    spec.require_paths = ["lib"]
    spec.required_ruby_version = '~> 2.6.0'
    spec.add_development_dependency "bundler", "2.2.33"
    spec.add_development_dependency "rake"
    spec.add_dependency "fog"
    spec.add_dependency "fog-core", "1.43.0"
    ###spec.add_dependency "fog-azure"
    ###spec.add_dependency "fog-azure-rm", "0.0.3"
    spec.add_dependency "fog-google", "1.8.2"
    ###spec.add_dependency "azure"
    spec.add_dependency "rvm-capistrano"
    spec.add_dependency "capistrano", "3.4.1"
    spec.add_dependency "capistrano-rvm"
    spec.add_dependency "net-ssh", "4.2.0"
    spec.add_dependency "sshkit", "~> 1.16.0"
    spec.add_dependency "derelict"
    spec.add_dependency "docopt", ">= 0.5.0"
    spec.add_dependency "rainbow", '3.0.0'
    spec.add_dependency "nokogiri", "~> 1.13.9"
    spec.add_dependency "signet", "0.14.1"
end


