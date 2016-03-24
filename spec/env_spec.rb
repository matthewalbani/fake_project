require "spec_helper"
require "pp"

describe FakedProject do
  it "should output env" do
    pp ENV['TEST_ENV_NUMBER']
    pp ENV['PARALLEL_TEST_GROUPS']
  end

end
