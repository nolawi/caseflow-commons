# frozen_string_literal: true

##
# Stats is an interface to quickly access statistics and
# it is responsible for aggregating and caching statistics.
#
module Caseflow
  class Stats
    attr_accessor :interval, :time
    attr_writer :values

    TIMEZONE = "Eastern Time (US & Canada)"
    INTERVALS = [:hourly, :daily, :weekly, :monthly].freeze
    CALCULATIONS = {}.freeze

    def initialize(interval:, time:)
      self.interval = interval.to_sym
      self.time = time
    end

    def values
      @values ||= load_values || calculate_and_save_values!
    end

    def complete?
      values = load_values
      values && values[:complete]
    end

    def range
      range_start..range_finish
    end

    def range_start
      @range_start ||= {
        hourly: time.beginning_of_hour,
        daily: time.beginning_of_day,
        weekly: time.beginning_of_week,
        monthly: time.beginning_of_month
      }[interval]
    end

    def range_finish
      @range_finish ||= {
        hourly: range_start + 1.hour,
        daily: range_start + 1.day,
        weekly: range_start + 1.week,
        monthly: range_start.next_month
      }[interval]
    end

    def calculate_and_save_values!
      return true if complete?
      calculated_values = calculate_values
      calculated_values[:complete] = Stats.now >= range_finish
      Rails.cache.write(cache_id, calculated_values)
      calculated_values
    end

    def self.now
      Time.find_zone!(TIMEZONE).now
    end
    # rubocop:enable Rails/TimeZone

    def self.offset(interval:, time:, offset:)
      offset_time = time

      case interval
      when :monthly then offset_time -= offset.months
      when :weekly  then offset_time -= offset.weeks
      when :daily   then offset_time -= offset.days
      when :hourly  then offset_time -= offset.hours
      end

      new(interval: interval, time: offset_time)
    end

    def self.calculate_all!
      self::INTERVALS.each do |interval|
        {
          hourly: 0...24,
          daily: 0...30,
          weekly: 0...26,
          monthly: 0...24
        }[interval].each do |i|
          offset(interval: interval, time: Stats.now, offset: i)
            .calculate_and_save_values!
        end
      end
    end

    def self.percentile(attribute, collection, percentile)
      return nil if collection.empty?

      filtered = collection.reject { |model| model.send(attribute).nil? }
      sorted = filtered.sort_by(&attribute)
      percentile_model = sorted[((sorted.size - 1) * (percentile / 100.0)).ceil]
      percentile_model && percentile_model.send(attribute)
    end

    private

    def load_values
      Rails.cache.read(cache_id)
    end

    def calculate_values
      self.class::CALCULATIONS.each_with_object({}) do |(key, calculation), result|
        result[key] = calculation.call(range)
      end
    end

    def cache_id
      @id ||= calculate_cache_id
    end

    def calculate_cache_id
      id = "#{self.class.name}-#{range_start.year}"

      case interval
      when :monthly then id + "-#{range_start.month}"
      when :weekly  then id + "-w#{range_start.strftime('%U')}"
      when :daily   then id + "-#{range_start.month}-#{range_start.day}"
      when :hourly  then id + "-#{range_start.month}-#{range_start.day}-#{range_start.hour}"
      end
    end
  end
end
