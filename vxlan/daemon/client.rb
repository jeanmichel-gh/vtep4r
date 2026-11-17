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
require 'socket'

module VXLAN
  module Daemon
    # The other half of vtep4rd's socket: one request line, one reply
    # line. See vxlan/daemon/api.rb for the envelope.
    class Client
      DEFAULT_DIR = '/run/vtep4r'
      DEFAULT_SOCKET = 'vtep4rd.sock'

      class Error < StandardError; end

      # $VTEP4R_SOCKET, else the first of /run/vtep4r,
      # $XDG_RUNTIME_DIR/vtep4r and $TMPDIR/vtep4r this process may create,
      # as bgp4r's: no root in the ordinary case. Both programs work it out
      # the same way, so neither has to be told. +dirs+ is the seam tests use.
      def self.default_socket(env = ENV, dirs = nil)
        return env['VTEP4R_SOCKET'] if env['VTEP4R_SOCKET'] && !env['VTEP4R_SOCKET'].empty?

        dir = (dirs || candidates(env)).find { |d| writable_parent?(d) }
        File.join(dir || DEFAULT_DIR, DEFAULT_SOCKET)
      end

      def self.candidates(env = ENV)
        tmp = %w[TMPDIR TMP TEMP].map { |n| env[n] }.find { |v| v && !v.empty? && File.directory?(v) } || '/tmp'
        [DEFAULT_DIR, env['XDG_RUNTIME_DIR'] && File.join(env['XDG_RUNTIME_DIR'], 'vtep4r'),
         File.join(tmp, 'vtep4r')].compact
      end

      def self.writable_parent?(dir)
        return File.writable?(dir) if File.directory?(dir)

        parent = File.dirname(dir)
        File.directory?(parent) && File.writable?(parent)
      end

      attr_reader :path

      def initialize(path = nil, env = ENV)
        @path = path || Client.default_socket(env)
        @id = 0
      end

      # One method's result, or Error with vtep4rd's own message.
      def call(method, params = {})
        @sock ||= UNIXSocket.new(@path)
        @id += 1
        @sock.write("#{JSON.generate(id: @id, method: method, params: params)}\n")
        line = @sock.gets or raise Error, 'vtep4rd closed the connection'
        reply = JSON.parse(line)
        raise Error, reply['error'] if reply['error']

        reply['result']
      rescue Errno::ENOENT, Errno::ECONNREFUSED
        raise Error, "no vtep4rd answers on #{@path}"
      rescue Errno::EACCES
        raise Error, "no permission on #{@path}"
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        @sock = nil
        raise Error, 'lost the connection to vtep4rd'
      rescue JSON::ParserError => e
        raise Error, "vtep4rd answered something that is not JSON: #{e.message[0, 120]}"
      end

      def close
        @sock&.close
        @sock = nil
      end
    end
  end
end
