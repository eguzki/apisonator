require File.expand_path(File.dirname(__FILE__) + '/../../test_helper')

class AuthrepLimitHeadersTest < Test::Unit::TestCase
  include TestHelpers::Fixtures
  include TestHelpers::Integration
  include TestHelpers::Extensions
  include TestHelpers::AuthRep

  def setup
    @storage = Storage.instance(true)
    @storage.flushdb

    Resque.reset!
    Memoizer.reset!

    setup_oauth_provider_fixtures

    @application = Application.save(service_id: @service.id,
                                    id: next_id,
                                    state: :active,
                                    plan_id: @plan_id,
                                    plan_name: @plan_name)

    @metric_id = next_id
    Metric.save(service_id: @service.id, id: @metric_id, name: 'hits')
  end

  test_authrep 'response headers include limit headers when asked via extensions' do |e|
    metric1_id = @metric_id
    metric2_id = next_id
    metric2_name = 'metric2'
    Metric.save(service_id: @service.id, id: metric2_id, name: metric2_name)

    # Let's define stricter limits for metric1
    limit_metric1 = 100
    limit_metric2 = limit_metric1*2
    reported = 10
    remaining_times = (limit_metric1/reported) - 1

    limit_attrs = { service_id: @service.id,
                    plan_id: @plan_id,
                    metric_id: metric1_id,
                    day: limit_metric1 }
    UsageLimit.save(limit_attrs)

    limit_attrs = { service_id: @service.id,
                    plan_id: @plan_id,
                    metric_id: metric1_id,
                    hour: limit_metric1 } # same limits, but smaller period
    UsageLimit.save(limit_attrs)

    limit_attrs = { service_id: @service.id,
                    plan_id: @plan_id,
                    metric_id: metric2_id,
                    day: limit_metric2 }
    UsageLimit.save(limit_attrs)

    current_time = Time.now.utc

    Timecop.freeze(current_time) do
      get e,
          { provider_key: @provider_key, app_id: @application.id,
            usage: { 'hits' => reported, metric2_name => reported } },
          'HTTP_3SCALE_OPTIONS' => Extensions::LIMIT_HEADERS
    end

    assert_equal remaining_times,
                 last_response.header['3scale-limit-remaining']

    remaining_secs_in_day = (Period::Day.new(current_time).finish - current_time).ceil
    assert_equal remaining_secs_in_day,
                 last_response.header['3scale-limit-reset']
  end

  test_authrep 'remaining in limit headers is 0 when over limits' do |e|
    limit = 100
    limit_attrs = { service_id: @service.id,
                    plan_id: @plan_id,
                    metric_id: @metric_id,
                    day: limit }
    UsageLimit.save(limit_attrs)

    current_time = Time.now.utc

    Timecop.freeze(current_time) do
      Transactor.report(@provider_key, @service_id,
                        0 => { 'app_id' => @application.id,
                               'usage' => { 'hits' => limit + 1 } })
      Resque.run!

      get e,
          { provider_key: @provider_key, app_id: @application.id },
          'HTTP_3SCALE_OPTIONS' => Extensions::LIMIT_HEADERS
    end

    assert_equal 0, last_response.header['3scale-limit-remaining']

    remaining_secs_in_day = (Period::Day.new(current_time).finish - current_time).ceil
    assert_equal remaining_secs_in_day,
                 last_response.header['3scale-limit-reset']
  end

  test_authrep 'when a usage is passed, only take into account the metrics in the usage' do |e|
    # For this test, define two metrics, go over limits with one of them,
    # report the other one, and check that the limit headers refer to the
    # reported one.

    non_usage_metric_id = @metric_id
    usage_metric_id = 'a_metric_id'
    usage_metric_name = 'a_metric'
    Metric.save(service_id: @service.id, id: usage_metric_id, name: usage_metric_name)

    limit = 100
    reported = 10
    remaining_times = (limit/reported) - 1

    UsageLimit.save({ service_id: @service.id,
                      plan_id: @plan_id,
                      metric_id: non_usage_metric_id,
                      day: 0 })

    UsageLimit.save({ service_id: @service.id,
                      plan_id: @plan_id,
                      metric_id: usage_metric_id,
                      day: limit })

    current_time = Time.now.utc

    Timecop.freeze(current_time) do
      get e,
          { provider_key: @provider_key,
            app_id: @application.id,
            usage: { usage_metric_name => reported } },
          'HTTP_3SCALE_OPTIONS' => Extensions::LIMIT_HEADERS
    end

    assert_equal remaining_times,
                 last_response.header['3scale-limit-remaining']

    assert_equal (Period::Day.new(current_time).finish - current_time).ceil,
                 last_response.header['3scale-limit-reset']
  end

  test_authrep 'when a usage is passed, remaining/reset can refer to a parent metric' do |e|
    parent_id = next_id
    child_id = next_id
    metric = Metric.new(service_id: @service.id, id: parent_id, name: 'parent')
    metric.children << Metric.new(id: child_id, name: 'child')
    metric.save

    parent_limit = 10
    child_limit = parent_limit*2
    reported_usage = 2
    remaining_times = parent_limit/reported_usage - 1

    UsageLimit.save({ service_id: @service.id,
                      plan_id: @plan_id,
                      metric_id: parent_id,
                      day: parent_limit })

    UsageLimit.save({ service_id: @service.id,
                      plan_id: @plan_id,
                      metric_id: child_id,
                      day: child_limit })

    current_time = Time.now.utc

    Timecop.freeze(current_time) do
      get e,
          { provider_key: @provider_key,
            app_id: @application.id,
            usage: { 'child' => reported_usage } },
          'HTTP_3SCALE_OPTIONS' => Extensions::LIMIT_HEADERS
    end

    assert_equal remaining_times,
                 last_response.header['3scale-limit-remaining']

    assert_equal (Period::Day.new(current_time).finish - current_time).ceil,
                 last_response.header['3scale-limit-reset']
  end

  test_authrep 'remaining and reset in headers are negative when there are no limits' do |e|
    get e,
        { provider_key: @provider_key, app_id: @application.id,
          usage: { 'hits' => 10 } }, # We didn't set any limits for hits
        'HTTP_3SCALE_OPTIONS' => Extensions::LIMIT_HEADERS

    assert last_response.header['3scale-limit-remaining'].to_i < 0
    assert last_response.header['3scale-limit-reset'].to_i < 0
  end

  test_authrep 'reset in limit headers is negative when the period is eternity' do |e|
    limit = 100
    reported = 2
    remaining_times = (limit/reported) - 1

    limit_attrs = { service_id: @service.id,
                    plan_id: @plan_id,
                    metric_id: @metric_id,
                    eternity: limit }
    UsageLimit.save(limit_attrs)

    get e,
        { provider_key: @provider_key, app_id: @application.id,
          usage: { 'hits' => reported } },
        'HTTP_3SCALE_OPTIONS' => Extensions::LIMIT_HEADERS

    assert_equal remaining_times,
                 last_response.header['3scale-limit-remaining']

    assert last_response.header['3scale-limit-reset'].to_i < 0
  end

  test_authrep 'limit headers are not returned when there is an error != limits exceeded' do |e|
    # It is important to test two cases here. For some validations, like
    # invalid provider key, the code raises and returns a response without
    # generating a status object. However, for the checks performed by the
    # 'Validators', a status is generated and the code executed follows a
    # different path.

    # metric_invalid as an example of check not performed in a validator.
    get '/transactions/authorize.xml',
        { provider_key: @provider_key, app_id: @application.id,
          usage: { 'invalid_metric' => 1 } },
        'HTTP_3SCALE_OPTIONS' => Extensions::LIMIT_HEADERS

    assert_nil last_response.header['3scale-limit-reset']
    assert_nil last_response.header['3scale-limit-remaining']

    # application_key_invalid as an example of check performed in a validator.
    @application.create_key('foo')

    get e,
        { provider_key: @provider_key, app_id: @application.id,
          usage: { 'invalid_metric' => 1 } },
        'HTTP_3SCALE_OPTIONS' => Extensions::LIMIT_HEADERS

    assert_nil last_response.header['3scale-limit-reset']
    assert_nil last_response.header['3scale-limit-remaining']
  end

  test_authrep 'response headers do not include limit headers whe not asked via extensions' do |e|
    limit_attrs = { service_id: @service.id,
                    plan_id: @plan_id,
                    metric_id: @metric_id,
                    day: 100 }
    UsageLimit.save(limit_attrs)

    get e, { provider_key: @provider_key, app_id: @application.id }

    assert_nil last_response.header['3scale-limit-remaining']
    assert_nil last_response.header['3scale-limit-reset']
  end
end
