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
    # socket sends from the one port it is bound to. So sending is a
    # UdpSender: a small pool of sockets, one per source port in use.
    class UdpTunnel
      PORT = 4789   # IANA, RFC 7348 section 8

      def initialize(local, port: PORT)
        @port = port
        @rx = UDPSocket.new
        @rx.bind(local, port)
        @tx = UdpSender.new(local, port: port, fallback: @rx)
      end

      def send(octets, vtep, source_port)
        @tx.send(octets, vtep, source_port)
      end

      def recv(timeout)
        return nil unless IO.select([@rx], nil, nil, timeout)

        data, from = @rx.recvfrom(65_535)
        [from[3], data.b]
      end

      def close
        @tx.close
        @rx.close
      end
    end

    # The sending half alone, which vtep4r-sim uses: it never binds the
    # VXLAN port, so it can share a namespace with a vtep4rd that does.
    #
    # Each source port gets a socket bound to (local, port), up to POOL of
    # them, the oldest closed first. A port that cannot be bound, such as
    # one vtep4rd holds, falls back to +fallback+, or to a socket on an
    # ephemeral port.
    class UdpSender
      POOL = 64

      def initialize(local, port: UdpTunnel::PORT, fallback: nil)
        @local = local
        @port = port
        @fallback = fallback
        @pool = {}
        @lock = Mutex.new
      end

      def send(octets, vtep, source_port)
        socket(source_port).send(octets, 0, vtep, @port)
      end

      def close
        @lock.synchronize do
          @pool.each_value { |s| s.close unless s.equal?(@fallback) || s.closed? }
          @spare&.close
          @pool.clear
        end
      end

      private

      def socket(port)
        @lock.synchronize do
          @pool[port] ||= begin
            if @pool.size >= POOL
              old = @pool.delete(@pool.keys.first)
              old.close unless old.equal?(@fallback) || old.equal?(@spare)
            end
            s = UDPSocket.new
            begin
              s.bind(@local, port)
              s
            rescue SystemCallError
              s.close
              @fallback || spare
            end
          end
        end
      end

      def spare
        @spare ||= UDPSocket.new.tap { |s| s.bind(@local, 0) }
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
