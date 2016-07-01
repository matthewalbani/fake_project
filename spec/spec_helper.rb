require 'simplecov'
SimpleCov.star
require "bundler/setup"

require "codeclimate-test-reporter"
CodeClimate::TestReporter.start

require "faked_project"
