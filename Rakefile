require "bundler/gem_tasks"
require 'rake'
require 'rake/testtask'
require './lib/xmodem/version.rb'

Rake::TestTask.new(:test) do |test|
	test.libs << 'lib' << 'test'
	test.pattern = 'test/**/test_*.rb'
	test.verbose = true
end

begin
	require 'rcov/task'
	Rcov::RcovTask.new do |test|
		test.libs << 'test'
		test.pattern = 'test/**/test_*.rb'
		test.verbose = true
	end
rescue LoadError
	task :rcov do
		abort 'RCov is not available. In order to run rcov, you must: gem install rcov'
	end
end

task :default => :test
