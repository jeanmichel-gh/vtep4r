#--
# Copyright 2026 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of VTEP4R.
#
# VTEP4R is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# VTEP4R is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VTEP4R.  If not, see <http://www.gnu.org/licenses/>.
#++

require 'vxlan/logging'
require 'vxlan/vtep/tunnel'
require 'vxlan/sim/config'
require 'vxlan/sim/injector'
require 'vxlan/sim/http'

module VXLAN
  module Sim
    # The vtep4r-sim program: reads its file, starts the injector and its
    # HTTP API, and runs until INT or TERM.
    class Server
      USAGE = <<~TEXT
        Usage: vtep4r-sim -f FILE [--api HOST:PORT] [--log FILE] [-d] [-v] [-h]

          -f, --file FILE     the configuration: local, api, port
              --api ADDR      the HTTP API, HOST:PORT or PORT (default 127.0.0.1:8080)
              --log FILE      where to log; - is standard output, the default
          -d, --debug         log at debug
          -v, --version       the version
          -h, --help          this help
      TEXT

      def initialize(err = $stderr)
        @err = err
      end

      def start(argv)
        opts = parse(argv)
        return usage(0) if opts[:help]
        if opts[:version]
          puts VXLAN::VERSION
          return 0
        end
        return usage(1) if opts[:error] || opts[:file].nil?

        config = Config.load(opts[:file])
        addr = Http.address(opts[:api] || config.api)
        logger = Logging.to_io(opts[:log] || '-', level: opts[:debug] ? :debug : :info)
        sender = Vtep::UdpSender.new(config.local, port: config.port)
        injector = Injector.new(config, sender: sender, logger: logger)
        http = Http.new(injector, bind: addr[:bind], port: addr[:port], logger: logger).start
        logger.call(:info, "vtep4r-sim #{config.local}: API on http://#{addr[:bind]}:#{http.port}")
        wait_for_signal
        logger.call(:info, 'vtep4r-sim stopping')
        injector.act('stop', {})
        http.stop
        sender.close
        0
      rescue Config::Error, ArgumentError, SystemCallError => e
        @err.puts "vtep4r-sim: #{e.message}"
        1
      end

      private

      def wait_for_signal
        r, w = IO.pipe
        %w[INT TERM].each do |sig|
          Signal.trap(sig) do
            w.write_nonblock('x')
          rescue IOError, SystemCallError
            nil
          end
        end
        r.read(1)
      end

      def usage(status)
        (status.zero? ? $stdout : @err).print USAGE
        status
      end

      def parse(argv)
        opts = {}
        i = 0
        while i < argv.size
          case argv[i]
          when '-f', '--file' then opts[:file] = argv[i += 1]
          when '--api' then opts[:api] = argv[i += 1]
          when '--log' then opts[:log] = argv[i += 1]
          when '-d', '--debug' then opts[:debug] = true
          when '-v', '--version' then opts[:version] = true
          when '-h', '--help' then opts[:help] = true
          else opts[:error] = true
          end
          i += 1
        end
        opts
      end
    end
  end
end
