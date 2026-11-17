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
require 'vxlan/daemon/config'
require 'vxlan/daemon/vtepd'
require 'vxlan/daemon/api'
require 'vxlan/daemon/client'

module VXLAN
  module Daemon
    # The vtep4rd program: reads the file, opens the ports and the tunnel,
    # starts the Vtepd and its API, and runs until INT or TERM.
    class Server
      USAGE = <<~TEXT
        Usage: vtep4rd -f FILE [--socket PATH] [--log FILE] [-d] [-v] [-h]

          -f, --file FILE     the configuration (docs/design/vtep4r.md, "Its file")
          -s, --socket PATH   the API socket (default: the file's socket, else
                              $VTEP4R_SOCKET, /run/vtep4r or $XDG_RUNTIME_DIR/vtep4r)
              --log FILE      where to log; - is standard output, the default
          -d, --debug         log at debug
          -v, --version       the version
          -h, --help          this help
      TEXT

      def initialize(err = $stderr)
        @err = err
      end

      # Runs until a signal; answers the exit status. +edges+ is the seam
      # a test uses to run without root: ->(config) { [ports, tunnel] }.
      def start(argv, env = ENV, edges: nil)
        opts = parse(argv)
        return usage(0) if opts[:help]
        if opts[:version]
          puts VXLAN::VERSION
          return 0
        end
        return usage(1) if opts[:error] || opts[:file].nil?

        config = Config.load(opts[:file])
        logger = Logging.to_io(opts[:log] || '-', level: opts[:debug] ? :debug : :info)
        ports, tunnel = edges ? edges.call(config) : [Vtep::Ports.linux(config.ports), Vtep::UdpTunnel.new(config.local)]
        vtepd = Vtepd.new(config, ports: ports, tunnel: tunnel, logger: logger).start
        path = opts[:socket] || config.socket || Client.default_socket(env)
        api = Api.new(vtepd, path: path, logger: logger).start
        logger.call(:info, "vtep4rd answers on #{path}")
        wait_for_signal
        logger.call(:info, 'vtep4rd stopping')
        api.stop
        vtepd.stop
        0
      rescue Config::Error, Api::InUse, SystemCallError => e
        @err.puts "vtep4rd: #{e.message}"
        1
      end

      private

      def wait_for_signal
        r, w = IO.pipe
        %w[INT TERM].each { |s| Signal.trap(s) { w.write_nonblock('x') rescue nil } }
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
          when '-s', '--socket' then opts[:socket] = argv[i += 1]
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
