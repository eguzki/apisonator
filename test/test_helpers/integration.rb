module TestHelpers
  # Support for integration tests.
  module Integration
    def self.included(base)
      base.class_eval do
        include Rack::Test::Methods
      end
    end
  
    def app
      Rack::Builder.new do
        use Rack::RestApiVersioning, :default_version => '1.1'
        run ThreeScale::Backend::Endpoint.new
      end
    end

    private

    def assert_error_response(options = {})
      options = {:status       => 403, 
                 :content_type => 'application/vnd.3scale-v1.1+xml'}.merge(options)

      assert_equal options[:status],       last_response.status
      assert_equal options[:content_type], last_response.content_type

      doc = Nokogiri::XML(last_response.body)
      node = doc.at('error:root')

      assert_not_nil node
      assert_equal options[:code],    node['code'] if options[:code]
      assert_equal options[:message], node.content if options[:message]
    end
  end
end
