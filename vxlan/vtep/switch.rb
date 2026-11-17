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

require 'vxlan/vtep/forwarder'

module VXLAN
  module Vtep
    # A VTEP's state and the one place it changes: its bridge domains,
    # their MAC tables, the events and the counters. from_port and
    # from_tunnel ask the Forwarder, apply the learning it asks for, count
    # drops and ignored findings, and answer what the edges must do:
    # Deliver, Tunnel and Drop actions.
    #
    # Not thread safe on its own: vtep4rd calls it from one thread.
    class Switch
      attr_reader :local, :mtu, :policy, :events, :drops, :findings

      def initialize(local:, vnis:, mtu: 1500, policy: :rfc)
        raise ArgumentError, "receive policy #{policy.inspect}" unless Validation::POLICIES.include?(policy)

        @local = local.to_s
        @mtu = mtu
        @policy = policy
        @bridges = {}
        @by_port = {}
        vnis.each { |v| add_bridge(BridgeDomain.new(**v)) }
        @events = []
        @drops = Hash.new(0)
        @findings = Hash.new(0)
      end

      def bridge(vni)
        @bridges[vni]
      end

      def bridges
        @bridges.values
      end

      def from_port(port, octets, now)
        bd = @by_port[port]
        return apply([Drop.new(:unknown_port)], now) unless bd

        apply(Forwarder.from_port(bd, port, octets, mtu: @mtu), now)
      end

      def from_tunnel(src, octets, now)
        apply(Forwarder.from_tunnel(@bridges, src, octets, policy: @policy), now)
      end

      # Age every MAC table at +now+.
      def age(now)
        @bridges.each_value do |bd|
          bd.macs.age(now).each { |mac| @events << Event.new(:aged, bd.vni, mac, nil) }
        end
        self
      end

      private

      def add_bridge(bd)
        raise ArgumentError, "vni #{bd.vni} twice" if @bridges.key?(bd.vni)

        bd.ports.each do |p|
          raise ArgumentError, "port #{p} in vni #{@by_port[p].vni} and #{bd.vni}" if @by_port.key?(p)

          @by_port[p] = bd
        end
        @bridges[bd.vni] = bd
      end

      def apply(actions, now)
        actions.each_with_object([]) do |a, out|
          case a
          when Learn
            type = @bridges[a.vni].macs.learn(a.mac, a.location, now)
            @events << Event.new(type, a.vni, a.mac, a.location) if type
          when Note then @findings[a.finding] += 1
          when Drop
            @drops[a.reason] += 1
            out << a
          else out << a
          end
        end
      end
    end
  end
end
