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

module VXLAN
  module Vtep
    # How an MPLS packet reaches a remote PE (bgp4r
    # docs/design/evpn-mpls.md, decision 3): the labels the IGP put on the
    # kernel's route to the PE, its gateway and device, read as bgp4r's
    # L3VPN PE reads them, then the gateway's MAC and the device's own MAC
    # and MTU. Measured on Linux 7.0, iproute2 6.19:
    #
    #   ip -j route get 10.255.0.2
    #     [{"dst":"10.255.0.2","encap":{"encap_type":"mpls","dst":"16002"},
    #       "gateway":"10.0.1.2","dev":"ap",...}]
    #   two labels: "dst":"16003/24001", top first; a PE reached by PHP: no encap
    #   ip -j neigh show 10.0.1.2 dev ap   [{"dst":"10.0.1.2","lladdr":"d2:21:...",...}], or []
    #   ip -j link show dev ap             [{"ifname":"ap","mtu":1500,"address":"82:b6:...",...}]
    #
    # A PE on a connected subnet has no gateway: the PE is the neighbor.
    # A gateway with no neighbor entry is an error until ARP has run;
    # vtep4rd reads again every second.
    #
    # Every `ip` goes through +runner+, ->(argv) { [ok, output] }, so the
    # unit tests run with no kernel.
    class Transport
      # What reaches one PE. labels are the transport's, top first, pushed
      # above the EVPN label. error says why the PE cannot be reached, and
      # then the rest may be nil.
      Hop = Struct.new(:pe, :labels, :gateway, :dev, :mac, :src_mac, :mtu, :error) do
        def ok?
          error.nil?
        end

        def to_h
          { pe: pe, labels: labels, gateway: gateway, dev: dev, mac: mac, src_mac: src_mac, mtu: mtu, error: error }
        end
      end

      def initialize(bin: 'ip', runner: nil)
        @bin = bin
        @runner = runner || method(:popen)
      end

      def resolve(pe)
        pe = pe.to_s
        ok, out = @runner.call([@bin, '-j', 'route', 'get', pe])
        return Hop.new(pe, nil, nil, nil, nil, nil, nil, "no route to #{pe}: #{out.to_s.strip}") unless ok

        route = parse(out).first or return Hop.new(pe, nil, nil, nil, nil, nil, nil, "no route to #{pe}")
        encap = route['encap']
        if encap && encap['encap_type'] != 'mpls'
          return Hop.new(pe, nil, nil, route['dev'], nil, nil, nil, "the route to #{pe} is #{encap['encap_type']}, not mpls")
        end

        labels = encap ? encap['dst'].to_s.split('/').map { |l| Integer(l) } : []
        gateway = route['gateway'] || pe
        dev = route['dev']
        link(Hop.new(pe, labels, gateway, dev), gateway, dev)
      rescue JSON::ParserError, ArgumentError => e
        Hop.new(pe, nil, nil, nil, nil, nil, nil, "ip route get #{pe}: #{e.message}")
      end

      private

      def link(hop, gateway, dev)
        ok, out = @runner.call([@bin, '-j', 'link', 'show', 'dev', dev])
        l = ok && parse(out).first
        return fail(hop, "ip link show #{dev}: #{out.to_s.strip}") unless l

        hop.src_mac = l['address']
        hop.mtu = l['mtu']
        ok, out = @runner.call([@bin, '-j', 'neigh', 'show', gateway, 'dev', dev])
        n = ok && parse(out).find { |e| e['lladdr'] }
        return fail(hop, "no ARP entry for #{gateway} on #{dev}") unless n

        hop.mac = n['lladdr']
        hop
      end

      def fail(hop, why)
        hop.error = why
        hop
      end

      def parse(out)
        v = JSON.parse(out.to_s)
        v.is_a?(Array) ? v : []
      end

      def popen(argv)
        out = IO.popen(argv, err: %i[child out], &:read)
        [$?.success?, out]
      rescue SystemCallError => e
        [false, e.message]
      end
    end
  end
end
