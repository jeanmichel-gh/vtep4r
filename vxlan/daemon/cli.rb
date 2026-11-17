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

require 'json'
require 'vxlan/version'
require 'vxlan/daemon/client'

module VXLAN
  module Daemon
    # vtep4r-cli: one API method, its result printed as JSON.
    class CLI
      USAGE = <<~TEXT
        Usage: vtep4r-cli [options] METHOD [JSON | KEY=VALUE...]

          vtep4r-cli api.info                      the version and the methods
          vtep4r-cli show.vnis                     each VNI, its ports and flood list
          vtep4r-cli show.macs vni=100             a VNI's MAC table
          vtep4r-cli show.counters                 frames per port and peer, drops
          vtep4r-cli vni.flood.add vni=100 vtep=10.255.0.13
          vtep4r-cli mac.add vni=100 mac=02:00:00:00:01:09 vtep=10.255.0.13 seq=1
          vtep4r-cli mac.flush '{"vni":100,"origin":"learned"}'
          vtep4r-cli vni.add vni=200 ports='["eth3"]'   (a list as JSON)
          vtep4r-cli config.reload                 the file again, as SIGHUP
          vtep4r-cli events.subscribe kinds=mac    a stream, one line per event

        Options:
          -s, --socket PATH   vtep4rd's socket (default: $VTEP4R_SOCKET, else
                              /run/vtep4r/vtep4rd.sock or $XDG_RUNTIME_DIR/vtep4r)
              --pretty        indent the JSON
          -v, --version       the version
          -h, --help          this help
      TEXT

      def initialize(out = $stdout, err = $stderr, client = nil)
        @out = out
        @err = err
        @client = client
      end

      def start(argv, env = ENV)
        opts = parse(argv)
        return help(0) if opts[:help]
        if opts[:version]
          @out.puts VXLAN::VERSION
          return 0
        end
        return help(1) if opts[:error] || opts[:method].nil?

        params = CLI.params(opts[:args])
        client = @client || Client.new(opts[:socket], env)
        return subscribe(client, params) if opts[:method] == 'events.subscribe'

        result = client.call(opts[:method], params)
        @out.puts(opts[:pretty] ? JSON.pretty_generate(result) : JSON.generate(result))
        0
      rescue Client::Error, ArgumentError, JSON::ParserError => e
        @err.puts "vtep4r-cli: #{e.message}"
        1
      ensure
        client&.close
      end

      # A JSON object, or KEY=VALUE words. A value of digits is a number,
      # and one that starts with [ or { is JSON, so a list can be given.
      def self.params(words)
        return {} if words.empty?

        if words[0].start_with?('{')
          h = JSON.parse(words.join(' '))
          raise ArgumentError, 'the parameters are a JSON object' unless h.is_a?(Hash)

          return h
        end
        words.to_h do |w|
          k, v = w.split('=', 2)
          raise ArgumentError, "#{w.inspect} is not KEY=VALUE" if v.nil? || k.empty?

          value = if v.match?(/\A\d+\z/) then Integer(v)
                  elsif v.start_with?('[', '{') then JSON.parse(v)
                  else v
                  end
          [k, value]
        end
      end

      private

      # One line per event or keepalive, until interrupted.
      def subscribe(client, params)
        client.stream('events.subscribe', params) do |line|
          raise Client::Error, line['error'] if line['error'] && line.key?('id') && !line.key?('result')

          @out.puts(JSON.generate(line))
        end
        0
      rescue Interrupt
        client.unsubscribe
        0
      end

      def help(status)
        (status.zero? ? @out : @err).print USAGE
        status
      end

      def parse(argv)
        opts = { args: [] }
        i = 0
        while i < argv.size
          case argv[i]
          when '-h', '--help' then opts[:help] = true
          when '-v', '--version' then opts[:version] = true
          when '-s', '--socket'
            opts[:socket] = argv[i += 1]
            opts[:error] = true unless opts[:socket]
          when '--pretty' then opts[:pretty] = true
          else opts[:method] ? opts[:args] << argv[i] : opts[:method] = argv[i]
          end
          i += 1
        end
        opts
      end
    end
  end
end
