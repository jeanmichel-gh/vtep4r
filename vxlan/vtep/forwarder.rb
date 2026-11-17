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
require 'vxlan/packet'
require 'vxlan/validation'
require 'vxlan/vtep/actions'
require 'vxlan/vtep/bridge_domain'

module VXLAN
  module Vtep
    # The forwarding decision: a pure function. A frame from a host port,
    # or a packet from the tunnel, goes in; actions come out. It reads the
    # bridge domain and changes nothing: learning is a Learn action, which
    # Switch applies. No socket, no thread, no clock.
    module Forwarder
      ETHERNET_HEADER = 14
      # What a tunnelled frame adds inside the underlay's MTU: outer IPv4
      # (20), UDP (8) and VXLAN (8). The outer Ethernet header is not in
      # the MTU.
      OVERHEAD = 36
      # RFC 7348 section 5: the UDP source port "SHOULD" be a hash of the
      # inner packet's headers, and "it is RECOMMENDED that the value be
      # in the dynamic/private port range 49152-65535".
      PORT_BASE = 49_152
      PORT_SPAN = 16_384

      module_function

      # A frame that came in on host port +port+ of bridge domain +bd+.
      def from_port(bd, port, octets, mtu:)
        return [Drop.new(:not_a_frame)] if octets.bytesize < ETHERNET_HEADER

        dst = Datalink::MAC.from_bytes(octets.byteslice(0, 6))
        src = Datalink::MAC.from_bytes(octets.byteslice(6, 6))
        acts = [Learn.new(bd.vni, src, Location.port(port))]
        entry = (bd.macs.lookup(dst) unless dst.multicast?)
        if entry
          loc = entry.location
          return acts << Drop.new(:same_port) if loc.port? && loc.name == port

          return acts << (loc.port? ? Deliver.new(loc.name, octets) : tunnel(bd, loc.name, octets, mtu))
        end
        (bd.ports - [port]).each { |p| acts << Deliver.new(p, octets) }
        copies = bd.flood.map { |v| tunnel(bd, v, octets, mtu) }
        drops = copies.grep(Drop)
        acts.concat(copies - drops)
        acts << drops.first unless drops.empty?
        acts
      end

      # A UDP payload that came from VTEP +src+, for the bridge domains
      # +bridges+ (a Hash of VNI to BridgeDomain), under a receive policy
      # (Validation::POLICIES).
      def from_tunnel(bridges, src, octets, policy:)
        pk = Packet.new(octets)
        findings = Validation.check(pk)
        if Validation.decide(pk, policy: policy) == :drop
          return [Drop.new(findings.find { |f| f.action == :drop }.name)]
        end

        acts = findings.select { |f| f.action == :ignore }.map { |f| Note.new(f.name) }
        return acts << Drop.new(:not_a_frame) if pk.header.nil? || pk.inner.bytesize < ETHERNET_HEADER

        bd = bridges[pk.header.vni]
        return acts << Drop.new(:unknown_vni) unless bd

        inner = pk.inner
        dst = Datalink::MAC.from_bytes(inner.byteslice(0, 6))
        src_mac = Datalink::MAC.from_bytes(inner.byteslice(6, 6))
        acts << Learn.new(bd.vni, src_mac, Location.vtep(src)) if bd.learn_remote?
        entry = (bd.macs.lookup(dst) unless dst.multicast?)
        if entry
          # Never back into the tunnel: that keeps ingress replication
          # free of loops.
          return acts << Drop.new(:split_horizon) if entry.location.vtep?

          return acts << Deliver.new(entry.location.name, inner)
        end
        bd.ports.each { |p| acts << Deliver.new(p, inner) }
        acts
      end

      # A hash of the inner Ethernet header, so every packet of a flow has
      # the same port and ECMP keeps it on one path. FNV-1a, 32 bits.
      def source_port(octets)
        h = 0x811c9dc5
        octets.byteslice(0, ETHERNET_HEADER).each_byte { |b| h = ((h ^ b) * 0x01000193) & 0xffffffff }
        PORT_BASE + (h % PORT_SPAN)
      end

      # RFC 7348 section 4.3: "VTEPs MUST NOT fragment VXLAN packets", so
      # a frame too large for the underlay is dropped.
      def tunnel(bd, vtep, octets, mtu)
        return Drop.new(:too_big) if octets.bytesize + OVERHEAD > mtu

        Tunnel.new(vtep, Packet.new(Header.new(bd.vni), octets), source_port(octets))
      end
      private_class_method :tunnel
    end
  end
end
