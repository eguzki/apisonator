require_relative '../../../spec_helper'

module ThreeScale
  module Backend
    module Analytics
      module Kinesis
        describe Job do
          subject { described_class }

          # I use to_i so we do not take into account milliseconds. Otherwise,
          # the expectation of the mocks used below would fail
          let(:end_time_utc) { Time.at(Time.now.to_i).utc }
          let(:bucket_reader) { double }
          let(:kinesis_adapter) { double }
          let(:bucket_storage) { double }
          let(:lock_key) { '123' } # Does not matter for these tests
          let(:max_buckets) { subject.const_get(:MAX_BUCKETS) }

          before do
            # I use a mock for the bucket reader because otherwise, I would
            # need to store buckets, the event keys, the value for each event,
            # etc. That would complicate this test a lot and would duplicate
            # work already done in the BucketReader tests. Same for the Kinesis
            # adapter

            allow(subject).to receive(:bucket_reader).and_return(bucket_reader)
            allow(subject).to receive(:kinesis_adapter).and_return(kinesis_adapter)
            allow(subject).to receive(:bucket_storage).and_return(bucket_storage)
          end

          describe '.perform_logged' do
            context 'when there are pending events' do
              let(:events) do
                { 'stats/{service:s1}/metric:m1/day:20151210' => '10',
                  'stats/{service:s1}/metric:m1/day:20151211' => '20' }
              end

              let(:bucket_timestamp) do
                DateTime.parse(bucket).to_time.utc.strftime('%Y%m%d %H:%M:%S')
              end

              let(:events_to_send) do
                events.map do |k, v|
                  Stats::StatsParser.parse(k, v).merge!(time_gen: bucket_timestamp)
                end
              end

              let(:bucket) { '20150101000000' }

              context 'when pending events does not contain events that need to be filtered' do
                before do
                  allow(bucket_reader)
                    .to receive(:pending_events_in_buckets)
                    .with(end_time_utc: end_time_utc, max_buckets: max_buckets)
                    .and_return({ events: events, latest_bucket: bucket })

                  allow(bucket_reader).to receive(:latest_bucket_read=).with(bucket)
                  allow(kinesis_adapter).to receive(:send_events).with(events_to_send)
                  allow(bucket_storage).to receive(:delete_range).with(bucket)
                end

                it 'returns array with format [true, msg]' do
                  expect(subject.perform_logged(end_time_utc.to_s, lock_key, end_time_utc))
                    .to eq [true, subject.send(:msg_events_sent, events.size)]
                end
              end

              context 'when pending events contains some events that need to be filtered' do
                let(:events_to_filter) do
                  { 'stats/{service:s1}/metric:m1/eternity' => '10',
                    'stats/{service:s1}/metric:m1/week:20151228' => '20' }
                end
                let(:pending_events) { events.merge(events_to_filter) }

                before do
                  allow(bucket_reader)
                    .to receive(:pending_events_in_buckets)
                    .with(end_time_utc: end_time_utc, max_buckets: max_buckets)
                    .and_return({ events: pending_events, latest_bucket: bucket })

                  allow(bucket_reader).to receive(:latest_bucket_read=).with(bucket)
                  allow(kinesis_adapter).to receive(:send_events).with(events_to_send)
                  allow(bucket_storage).to receive(:delete_range).with(bucket)
                end

                it 'returns array with format [true, msg]' do
                  expect(subject.perform_logged(end_time_utc.to_s, lock_key, end_time_utc))
                    .to eq [true, subject.send(:msg_events_sent, events.size)]
                end
              end
            end

            context 'when there is an invalid event in the list of pending ones' do
              let(:invalid_events) do
                { 'stats/{service:s1}/metric:m1/$ay:20151209' => '5' }
              end

              let(:valid_events) do
                { 'stats/{service:s1}/metric:m1/day:20151210' => '10',
                  'stats/{service:s1}/metric:m1/day:20151211' => '20' }
              end

              let(:events) { valid_events.merge(invalid_events) }

              let(:events_to_send) do # Only send the valid ones
                valid_events.map do |k, v|
                  Stats::StatsParser.parse(k, v).merge!(time_gen: bucket_timestamp)
                end
              end

              let(:bucket) { '20150101000000' }
              let(:bucket_timestamp) do
                DateTime.parse(bucket).to_time.utc.strftime('%Y%m%d %H:%M:%S')
              end

              before do
                allow(bucket_reader)
                  .to receive(:pending_events_in_buckets)
                  .with(end_time_utc: end_time_utc, max_buckets: max_buckets)
                  .and_return({ events: events, latest_bucket: bucket })

                allow(bucket_reader).to receive(:latest_bucket_read=).with(bucket)
                allow(kinesis_adapter).to receive(:send_events).with(events_to_send)
                allow(bucket_storage).to receive(:delete_range).with(bucket)
                allow(subject.logger).to receive(:notify)
              end

              it 'notifies that an invalid event has been found' do
                invalid_events.each do |k, v|
                  expect(subject.logger)
                    .to receive(:notify)
                    .with("Invalid stats key-value. k: #{k}. v: #{v}")
                end

                subject.perform_logged(end_time_utc.to_s, lock_key, end_time_utc)
              end

              it 'returns array with format [true, msg] without counting the invalid events' do
                expect(subject.perform_logged(end_time_utc.to_s, lock_key, end_time_utc))
                  .to eq [true, subject.send(:msg_events_sent, valid_events.size)]
              end
            end

            context 'when there are not any pending events' do
              before do
                allow(bucket_reader)
                  .to receive(:pending_events_in_buckets)
                  .with(end_time_utc: end_time_utc, max_buckets: max_buckets)
                  .and_return({ events: { }, latest_bucket: nil })
              end

              it 'does not send anything to the kinesis adapter' do
                expect(kinesis_adapter).not_to receive(:send_events)
                subject.perform_logged(end_time_utc.to_s, lock_key, end_time_utc)
              end

              it 'does not mark any bucket as the latest read' do
                expect(bucket_reader).not_to receive(:latest_bucket_read=)
                subject.perform_logged(end_time_utc.to_s, lock_key, end_time_utc)
              end

              it 'does not delete any buckets' do
                expect(bucket_storage).not_to receive(:delete_range)
                subject.perform_logged(end_time_utc.to_s, lock_key, end_time_utc)
              end

              it 'returns array with format [true, msg]' do
                expect(subject.perform_logged(end_time_utc.to_s, lock_key, end_time_utc))
                  .to eq [true, subject.send(:msg_events_sent, 0)]
              end
            end
          end
        end
      end
    end
  end
end
