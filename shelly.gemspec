# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "shelly/version"

Gem::Specification.new do |s|
  s.name        = "shelly"
  s.version     = Shelly::VERSION
  s.authors     = ["Shelly Cloud team"]
  s.email       = ["support@shellycloud.com"]
  s.homepage    = "http://shellycloud.com"
  s.summary     = %q{Shelly Cloud command line tool}
  s.description = %q{Tool for managing applications and clouds at shellycloud.com}

  s.rubyforge_project = "shelly"
  s.add_development_dependency "rspec", "~> 2.11.0"
  s.add_development_dependency "rake"
  s.add_development_dependency "guard"
  s.add_development_dependency "guard-rspec"
  s.add_development_dependency "simplecov"
  if RUBY_PLATFORM =~ /darwin/
    s.add_development_dependency "ruby_gntp"
    s.add_development_dependency "rb-fsevent"
  end
  s.add_development_dependency "fakefs"
  s.add_development_dependency "fakeweb"
  s.add_runtime_dependency "wijet-thor", "~> 0.14.7"
  s.add_runtime_dependency "rest-client"
  s.add_runtime_dependency "json"
  s.add_runtime_dependency "progressbar"
  s.add_runtime_dependency "grit"
  s.add_runtime_dependency "launchy"
  s.add_runtime_dependency "shelly-dependencies", "~> 0.2.1"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
end

