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

require 'socket'
require 'vxlan/vtep/forwarder'

module VXLAN
  module Vtep
    # The tunnel edge: VXLAN over UDP. send puts a packet's octets to a
    # VTEP from a given source port; recv answers [source address,
    # octets], or nil when nothing came within the timeout.
    #
    # RFC 7348 section 5 has the source port vary per flow, and a UDP
    # socket sends from the one port it is bound to. So UdpTunnel keeps a
    # small pool of sockets, one per source port in use, and falls back to
    # the receiving socket when a port cannot be bound.
    class UdpTunnel
      PORT = 4789   # IANA, RFC 7348 section 8
      POOL = 64

      def initialize(local, port: PORT)
        @local = local
        @port = port
        @rx = UDPSocket.new
        @rx.bind(local, port)
        @pool = {}
        @lock = Mutex.new
      end

      def send(octets, vtep, source_port)
        sock = sender(source_port)
        sock.send(octets, 0, vtep, @port)
      end

      def recv(timeout)
        return nil unless IO.select([@rx], nil, nil, timeout)

        data, from = @rx.recvfrom(65_535)
        [from[3], data.b]
      end

      def close
        @lock.synchronize { @pool.each_value(&:close) }
        @rx.close
      end

      private

      def sender(port)
        @lock.synchronize do
          @pool[port] ||= begin
            @pool.delete(@pool.keys.first)&.close if @pool.size >= POOL
            s = UDPSocket.new
            s.bind(@local, port)
            s
          rescue SystemCallError
            @rx
          end
        end
      end
    end

    # The same in memory, for tests: VTEPs on one Fabric reach each other
    # by address, with the source port recorded.
    class MemoryTunnel
      class Fabric
        def initialize
          @queues = {}
          @lock = Mutex.new
        end

        def attach(address)
          @lock.synchronize { @queues[address] ||= Queue.new }
        end

        def deliver(to, from, octets, source_port)
          q = @lock.synchronize { @queues[to] }
          q&.push([from, octets.b, source_port])
          !q.nil?
        end
      end

      attr_reader :sent

      def initialize(local, fabric)
        @local = local
        @fabric = fabric
        @queue = fabric.attach(local)
        @sent = Queue.new
      end

      def send(octets, vtep, source_port)
        @sent.push([vtep, octets.b, source_port])
        @fabric.deliver(vtep, @local, octets, source_port)
      end

      def recv(timeout)
        from, octets, = @queue.pop(timeout: timeout)
        from && [from, octets]
      end

      def close; end
    end
  end
end
