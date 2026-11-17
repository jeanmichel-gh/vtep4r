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

require 'datalink'

module VXLAN
  module Vtep
    # The port edge: one datalink-socket per host port. On Linux it skips
    # the frames this host sends out of the port (datalink-socket's
    # ignore_outgoing, from routescope's trial 1); without that, a VTEP
    # forwards its own namespace's traffic.
    class Ports
      def self.linux(names)
        new(names.to_h { |n| [n, Datalink::Socket.new(n, backend: :linux, ignore_outgoing: true).open] })
      end

      # Each name on its own loopback wire, for tests: wires is name =>
      # Datalink::Backends::Loopback::Wire.
      def self.loopback(wires)
        require 'datalink/backends/loopback'
        new(wires.to_h { |n, w| [n, Datalink::Socket.new(n, backend: :loopback, wire: w).open] })
      end

      attr_reader :sockets

      def initialize(sockets)
        @sockets = sockets
      end

      def names
        @sockets.keys
      end

      def send(name, octets)
        @sockets.fetch(name).send(octets)
      end

      # The next frame's octets on +name+, or nil after +timeout+.
      def recv(name, timeout)
        s = @sockets.fetch(name)
        s.recv_timeout = timeout
        s.recv.bytes.b
      rescue Datalink::TimeoutError
        nil
      end

      def close
        @sockets.each_value(&:close)
      end
    end
  end
end
