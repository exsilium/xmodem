# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'xmodem/version'

Gem::Specification.new do |spec|
  spec.name          = "xmodem"
  spec.version       = XMODEM::VERSION
  spec.authors       = ["Jonno Downes", "Sten Feldman"]
  spec.email         = ["exile@chamber.ee"]
  spec.summary       = %q{A pure XMODEM implementation in Ruby for sender and receiver. Compatible with Ruby 1.9.3+}
  spec.description   = %q{A simple gem for XMODEM client and server application. Forked from modem_protocols and made to work with newer Rubies. Today the XMODEM protocol is widely used in embedded systems for OTA application firmware transfer.}
  spec.homepage      = "https://github.com/exsilium/xmodem"
  spec.license       = "Mozilla Public License 1.1"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.has_rdoc      = true
  spec.rdoc_options  = %w(--charset=UTF-8)
  spec.extra_rdoc_files = %w(LICENSE.txt doc/xmodem.txt doc/xmodem1k.txt doc/xmodmcrc.txt doc/ymodem.txt)

  spec.add_runtime_dependency "log4r", "~> 1.1"

  spec.add_development_dependency "bundler",            "~> 1.6"
  spec.add_development_dependency "rake",               "~> 0"
  spec.add_development_dependency "VersionCheck",       "~> 1.0"
  spec.add_development_dependency "simplecov",          "~> 0.9"
  spec.add_development_dependency "minitest",           "~> 5.5"
  spec.add_development_dependency "minitest-reporters", "~> 1.0"
  spec.add_development_dependency "coveralls",          "~> 0.7"
end
