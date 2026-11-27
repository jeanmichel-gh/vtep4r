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
    #
    # Ports open and close at run time, for vni.add and vni.del: +opener+
    # makes the socket for a name. Thread safe: the worker opens and
    # closes, each port's reader receives.
    class Ports
      def self.linux(names)
        new(names, opener: ->(n) { Datalink::Socket.new(n, backend: :linux, ignore_outgoing: true).open })
      end

      # EtherType 0x8847, MPLS unicast (RFC 3032 section 5).
      MPLS = 0x8847

      # The MPLS edge's core devices: only frames of EtherType 0x8847 are
      # read, and the host's own are skipped. The kernel drops what it
      # has no label route for, and this socket still gets its copy
      # (bgp4r docs/design/evpn-mpls.md, measured).
      def self.linux_mpls(names)
        new(names, opener: lambda { |n|
          Datalink::Socket.new(n, backend: :linux, protocol: MPLS, ignore_outgoing: true).open
        })
      end

      # For tests: +wires+ is name => Datalink::Backends::Loopback::Wire,
      # and +names+ the ones open at start (all of them by default).
      def self.loopback(wires, names = wires.keys)
        require 'datalink/backends/loopback'
        new(names, opener: ->(n) { Datalink::Socket.new(n, backend: :loopback, wire: wires.fetch(n)).open })
      end

      def initialize(names = [], opener: nil, sockets: nil)
        @opener = opener
        @lock = Mutex.new
        @sockets = sockets || {}
        names.each { |n| open(n) }
      end

      def names
        @lock.synchronize { @sockets.keys }
      end

      def open?(name)
        @lock.synchronize { @sockets.key?(name) }
      end

      # Opens +name+ unless it is open; true when it opened it.
      def open(name)
        @lock.synchronize do
          return false if @sockets.key?(name)
          raise ArgumentError, "no way to open port #{name}" unless @opener

          @sockets[name] = @opener.call(name)
          true
        end
      end

      # Closes +name+; its reader sees an IOError or open? false and stops.
      def close_port(name)
        s = @lock.synchronize { @sockets.delete(name) }
        s&.close
        !s.nil?
      end

      def send(name, octets)
        socket(name).send(octets)
      end

      # The next frame's octets on +name+, or nil after +timeout+.
      def recv(name, timeout)
        s = socket(name)
        s.recv_timeout = timeout
        s.recv.bytes.b
      rescue Datalink::TimeoutError
        nil
      end

      def close
        @lock.synchronize { @sockets.values.tap { @sockets.clear } }.each(&:close)
      end

      private

      def socket(name)
        @lock.synchronize { @sockets[name] } or raise IOError, "port #{name} is not open"
      end
    end
  end
end
