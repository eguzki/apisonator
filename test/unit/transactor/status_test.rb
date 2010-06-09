require File.dirname(__FILE__) + '/../../test_helper'

module Transactor
  class StatusTest < Test::Unit::TestCase
    include TestHelpers::EventMachine
    include TestHelpers::StorageKeys

    def setup
      @storage = Storage.instance(true)
      @storage.flushdb
    end

    def test_status_contains_usage_entries
      service_id  = 1001
      plan_id     = 2001
      contract_id = 3001
      metric_id   = 4001

      contract = Contract.new(:service_id => service_id,
                              :id         => contract_id,
                              :plan_id    => plan_id)
      Metric.save(:service_id => service_id, :id => metric_id, :name => 'foos')
      UsageLimit.save(:service_id => service_id,
                      :plan_id    => plan_id,
                      :metric_id  => metric_id,
                      :month      => 2000)

      time = Time.utc(2010, 5, 17, 12, 42)
      usage = {:month => {metric_id.to_s => 429}}

      Timecop.freeze(time) do
        status = Transactor::Status.new(contract, usage)

        assert_equal 1, status.usage_reports.count

        report = status.usage_reports.first
        assert_equal :month,               report.period
        assert_equal 'foos',               report.metric_name
        assert_equal Time.utc(2010, 5, 1), report.period_start
        assert_equal Time.utc(2010, 6, 1), report.period_end
        assert_equal 2000,                 report.max_value
        assert_equal 429,                  report.current_value
      end
    end
  end
end
