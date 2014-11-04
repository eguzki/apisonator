require_relative '../spec_helper'

module ThreeScale
  module Backend
    describe BackgroundJob do
      class FooJob < BackgroundJob

        def self.perform_logged
          sleep 0.15
        end

        def self.success_log_message
          'job was successful'
        end
      end

      describe 'logging' do
        before do
          allow(Worker).to receive(:logger).and_return(
            ::Logger.new(@log = StringIO.new))
          FooJob.perform(Time.now.getutc.to_f)
          @log.rewind
        end

        it 'logs class name' do
          @log.read.should =~ /FooJob/
        end

        it 'logs job message' do
          @log.read.should =~ /job was successful/
        end

        it 'logs execution time' do
          @log.read.should =~ /0\.15/
        end
      end
    end
  end
end

