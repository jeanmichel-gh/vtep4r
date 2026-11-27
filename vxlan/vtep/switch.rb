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
        @by_label = {}
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

      # The octets after an Ethernet header of EtherType 0x8847.
      def from_core(octets, now)
        apply(Forwarder.from_core(@by_label, octets, policy: @policy), now)
      end

      # Our labels, label => [vni, :unicast or :bum], for show.labels.
      def labels
        @by_label.transform_values { |bd, kind| [bd.vni, kind] }
      end

      # An MPLS bridge domain's two labels, for vtep4rd's vni.labels. A
      # label another VNI has is refused. true when they changed.
      def set_labels(vni, unicast:, bum:)
        bd = @bridges[vni] or raise ArgumentError, "no vni #{vni}"
        taken = [unicast, bum].map { |l| Integer(l) }.select { |l| (o = @by_label[l]) && o[0] != bd }
        raise ArgumentError, "vni #{vni}: label #{taken.first} is vni #{@by_label[taken.first][0].vni}'s" unless taken.empty?

        changed = bd.set_labels(unicast: unicast, bum: bum)
        index_labels
        changed
      end

      # Age every MAC table at +now+.
      def age(now)
        @bridges.each_value do |bd|
          bd.macs.expire(now).each { |e| @events << Event.new(:aged, bd.vni, e.mac, e.location) }
        end
        self
      end

      # A bridge domain added at run time, for vtep4rd's vni.add. The same
      # checks as at start: a VNI once, a port in one VNI.
      def add_vni(**args)
        add_bridge(BridgeDomain.new(**args))
      end

      # The bridge domain removed, with its MAC table; nil if none.
      def del_vni(vni)
        bd = @bridges.delete(vni) or return nil
        bd.ports.each { |p| @by_port.delete(p) }
        index_labels
        bd
      end

      private

      def add_bridge(bd)
        raise ArgumentError, "vni #{bd.vni} twice" if @bridges.key?(bd.vni)

        (bd.labels || {}).each_value do |l|
          raise ArgumentError, "vni #{bd.vni}: label #{l} is vni #{@by_label[l][0].vni}'s" if @by_label.key?(l)
        end

        bd.ports.each do |p|
          raise ArgumentError, "port #{p} in vni #{@by_port[p].vni} and #{bd.vni}" if @by_port.key?(p)

          @by_port[p] = bd
        end
        @bridges[bd.vni] = bd
        index_labels
        bd
      end

      def index_labels
        @by_label = {}
        @bridges.each_value do |bd|
          next unless bd.labels

          @by_label[bd.labels[:unicast]] = [bd, :unicast]
          @by_label[bd.labels[:bum]] = [bd, :bum]
        end
      end

      def apply(actions, now)
        actions.each_with_object([]) do |a, out|
          case a
          when Learn
            macs = @bridges[a.vni].macs
            from = macs.lookup(a.mac)&.location
            type = macs.learn(a.mac, a.location, now)
            @events << Event.new(type, a.vni, a.mac, a.location, (from if type == :moved)) if type
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
