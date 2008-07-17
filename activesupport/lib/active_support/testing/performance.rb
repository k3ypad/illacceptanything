require 'rubygems'
gem 'ruby-prof', '>= 0.6.1'
require 'ruby-prof'

require 'fileutils'
require 'rails/version'

module ActiveSupport
  module Testing
    module Performance
      DEFAULTS =
        if benchmark = ARGV.include?('--benchmark')  # HAX for rake test
          { :benchmark => true,
            :runs => 4,
            :metrics => [:process_time, :memory, :objects, :gc_runs, :gc_time],
            :output => 'tmp/performance' }
        else
          { :benchmark => false,
            :runs => 1,
            :min_percent => 0.02,
            :metrics => [:process_time, :memory, :objects],
            :formats => [:flat, :graph_html, :call_tree],
            :output => 'tmp/performance' }
        end

      def self.included(base)
        base.class_inheritable_hash :profile_options
        base.profile_options = DEFAULTS.dup
      end

      def full_test_name
        "#{self.class.name}##{method_name}"
      end

      def run(result)
        return if method_name =~ /^default_test$/

        yield(self.class::STARTED, name)
        @_result = result

        run_warmup
        profile_options[:metrics].each do |metric_name|
          if klass = Metrics[metric_name.to_sym]
            run_profile(klass.new)
            result.add_run
          else
            $stderr.puts '%20s: unsupported' % metric_name.to_s
          end
        end

        yield(self.class::FINISHED, name)
      end

      def run_test(metric, mode)
        run_callbacks :setup
        setup
        metric.send(mode) { __send__ @method_name }
      rescue ::Test::Unit::AssertionFailedError => e
        add_failure(e.message, e.backtrace)
      rescue StandardError, ScriptError
        add_error($!)
      ensure
        begin
          teardown
          run_callbacks :teardown, :enumerator => :reverse_each
        rescue ::Test::Unit::AssertionFailedError => e
          add_failure(e.message, e.backtrace)
        rescue StandardError, ScriptError
          add_error($!)
        end
      end

      protected
        def run_warmup
          5.times { GC.start }

          time = Metrics::Time.new
          run_test(time, :benchmark)
          puts "%s (%s warmup)" % [full_test_name, time.format(time.total)]

          5.times { GC.start }
        end

        def run_profile(metric)
          klass = profile_options[:benchmark] ? Benchmarker : Profiler
          performer = klass.new(self, metric)

          performer.run
          puts performer.report
          performer.record
        end

      class Performer
        delegate :run_test, :profile_options, :full_test_name, :to => :@harness

        def initialize(harness, metric)
          @harness, @metric = harness, metric
        end

        def report
          rate = @total / profile_options[:runs]
          '%20s: %s' % [@metric.name, @metric.format(rate)]
        end

        protected
          def output_filename
            "#{profile_options[:output]}/#{full_test_name}_#{@metric.name}"
          end
      end

      class Benchmarker < Performer
        def run
          profile_options[:runs].to_i.times { run_test(@metric, :benchmark) }
          @total = @metric.total
        end

        def record
          avg = @metric.total / profile_options[:runs].to_i
          now = Time.now.utc.xmlschema
          with_output_file do |file|
            file.puts "#{avg},#{now},#{environment}"
          end
        end

        def environment
          unless defined? @env
            app = "#{$1}.#{$2}" if `git branch -v` =~ /^\* (\S+)\s+(\S+)/

            rails = Rails::VERSION::STRING
            if File.directory?('vendor/rails/.git')
              Dir.chdir('vendor/rails') do
                rails += ".#{$1}.#{$2}" if `git branch -v` =~ /^\* (\S+)\s+(\S+)/
              end
            end

            ruby = defined?(RUBY_ENGINE) ? RUBY_ENGINE : 'ruby'
            ruby += "-#{RUBY_VERSION}.#{RUBY_PATCHLEVEL}"

            @env = [app, rails, ruby, RUBY_PLATFORM] * ','
          end

          @env
        end

        protected
          HEADER = 'measurement,created_at,app,rails,ruby,platform'

          def with_output_file
            fname = output_filename

            if new = !File.exist?(fname)
              FileUtils.mkdir_p(File.dirname(fname))
            end

            File.open(fname, 'ab') do |file|
              file.puts(HEADER) if new
              yield file
            end
          end

          def output_filename
            "#{super}.csv"
          end
      end

      class Profiler < Performer
        def run
          RubyProf.measure_mode = @metric.measure_mode
          RubyProf.start
          RubyProf.pause
          profile_options[:runs].to_i.times { run_test(@metric, :profile) }
          @data = RubyProf.stop
          @total = @data.threads.values.sum(0) { |method_infos| method_infos.sort.last.total_time }
        end

        def record
          klasses = profile_options[:formats].map { |f| RubyProf.const_get("#{f.to_s.camelize}Printer") }.compact

          klasses.each do |klass|
            fname = output_filename(klass)
            FileUtils.mkdir_p(File.dirname(fname))
            File.open(fname, 'wb') do |file|
              klass.new(@data).print(file, profile_options.slice(:min_percent))
            end
          end
        end

        protected
          def output_filename(printer_class)
            suffix =
              case printer_class.name.demodulize
                when 'FlatPrinter'; 'flat.txt'
                when 'GraphPrinter'; 'graph.txt'
                when 'GraphHtmlPrinter'; 'graph.html'
                when 'CallTreePrinter'; 'tree.txt'
                else printer_class.name.sub(/Printer$/, '').underscore
              end

            "#{super()}_#{suffix}"
          end
      end

      module Metrics
        def self.[](name)
          klass = const_get(name.to_s.camelize)
          klass if klass::Mode
        rescue NameError
          nil
        end

        class Base
          attr_reader :total

          def initialize
            @total = 0
          end

          def name
            @name ||= self.class.name.demodulize.underscore
          end

          def measure_mode
            self.class::Mode
          end

          def measure
            0
          end

          def benchmark
            with_gc_stats do
              before = measure
              yield
              @total += (measure - before)
            end
          end

          def profile
            RubyProf.resume
            yield
          ensure
            RubyProf.pause
          end

          protected
            if GC.respond_to?(:enable_stats)
              def with_gc_stats
                GC.enable_stats
                yield
              ensure
                GC.disable_stats
              end
            else
              def with_gc_stats
                yield
              end
            end
        end

        class Time < Base
          def measure
            ::Time.now.to_f
          end

          def format(measurement)
            if measurement < 2
              '%d ms' % (measurement * 1000)
            else
              '%.2f sec' % measurement
            end
          end
        end

        class ProcessTime < Time
          Mode = RubyProf::PROCESS_TIME

          def measure
            RubyProf.measure_process_time
          end
        end

        class WallTime < Time
          Mode = RubyProf::WALL_TIME

          def measure
            RubyProf.measure_wall_time
          end
        end

        class CpuTime < Time
          Mode = RubyProf::CPU_TIME if RubyProf.const_defined?(:CPU_TIME)

          def initialize(*args)
            # FIXME: yeah my CPU is 2.33 GHz
            RubyProf.cpu_frequency = 2.33e9
            super
          end

          def measure
            RubyProf.measure_cpu_time
          end
        end

        class Memory < Base
          Mode = RubyProf::MEMORY if RubyProf.const_defined?(:MEMORY)

          # ruby-prof wrapper
          if RubyProf.respond_to?(:measure_memory)
            def measure
              RubyProf.measure_memory / 1024.0
            end

          # Ruby 1.8 + adymo patch
          elsif GC.respond_to?(:allocated_size)
            def measure
              GC.allocated_size / 1024.0
            end

          # Ruby 1.8 + lloyd patch
          elsif GC.respond_to?(:heap_info)
            def measure
              GC.heap_info['heap_current_memory'] / 1024.0
            end

          # Ruby 1.9 unpatched
          elsif GC.respond_to?(:malloc_allocated_size)
            def measure
              GC.malloc_allocated_size / 1024.0
            end
          end

          def format(measurement)
            '%.2f KB' % measurement
          end
        end

        class Objects < Base
          Mode = RubyProf::ALLOCATIONS if RubyProf.const_defined?(:ALLOCATIONS)

          if RubyProf.respond_to?(:measure_allocations)
            def measure
              RubyProf.measure_allocations
            end
          elsif ObjectSpace.respond_to?(:allocated_objects)
            def measure
              ObjectSpace.allocated_objects
            end
          end

          def format(measurement)
            measurement.to_i.to_s
          end
        end

        class GcRuns < Base
          Mode = RubyProf::GC_RUNS if RubyProf.const_defined?(:GC_RUNS)

          if RubyProf.respond_to?(:measure_gc_runs)
            def measure
              RubyProf.measure_gc_runs
            end
          elsif GC.respond_to?(:collections)
            def measure
              GC.collections
            end
          elsif GC.respond_to?(:heap_info)
            def measure
              GC.heap_info['num_gc_passes']
            end
          end

          def format(measurement)
            measurement.to_i.to_s
          end
        end

        class GcTime < Base
          Mode = RubyProf::GC_TIME if RubyProf.const_defined?(:GC_TIME)

          if RubyProf.respond_to?(:measure_gc_time)
            def measure
              RubyProf.measure_gc_time
            end
          elsif GC.respond_to?(:time)
            def measure
              GC.time
            end
          end

          def format(measurement)
            '%d ms' % (measurement / 1000)
          end
        end
      end
    end
  end
end
