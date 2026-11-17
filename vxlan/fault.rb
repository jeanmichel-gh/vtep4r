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

require 'vxlan/packet'
require 'vxlan/validation'

module VXLAN
  # The catalog of crafted packets, as bgp4r's BGP::Fault. A test or the
  # injector sends each one and checks what the receiver did against
  # what RFC 7348 expects.
  module Fault
    # The kernel's own ARP request, from test/fixtures/kernel-vxlan.pcap:
    # the inner frame an entry carries unless given another.
    ARP = ['ffffffffffff02000000010108060001080006040001020000000101ac106401000000000000ac106402'].pack('H*').freeze

    # Each entry: [name, description, what RFC 7348 expects of the
    # receiver (:drop, or :ignore for bits it must ignore), the RFC
    # section, a block (vni, inner) that builds the packet], and :vtep
    # after them for an entry only a VTEP can judge, since it depends on
    # the VNIs it serves.
    CATALOG = [
      [:no_i_flag,       'I flag clear',                    :drop,   '7348 5, 4.1',
       ->(vni, inner) { Packet.new({ vni: vni, flags: 0 }, inner) }],
      [:r_bit_set,       'one R bit set beside the I flag', :ignore, '7348 5',
       ->(vni, inner) { Packet.new({ vni: vni, flags: 0x0c }, inner) }],
      [:r_bits_all,      'every R bit set',                 :ignore, '7348 5',
       ->(vni, inner) { Packet.new({ vni: vni, flags: 0xff }, inner) }],
      [:reserved1_set,   'the 24 reserved bits set',        :ignore, '7348 5',
       ->(vni, inner) { Packet.new({ vni: vni, reserved1: 0xffffff }, inner) }],
      [:reserved2_set,   'the last 8 reserved bits set',    :ignore, '7348 5',
       ->(vni, inner) { Packet.new({ vni: vni, reserved2: 0xff }, inner) }],
      [:unknown_vni,     'a VNI the receiver does not serve', :drop, '7348 4.1',
       ->(vni, inner) { Packet.new((vni + 1) & 0xffffff, inner) }, :vtep],
      [:short_header,    'four octets, half a header (the RFC says nothing of a cut packet)', :drop, '7348 5',
       ->(vni, _inner) { Packet.new(Header.new(vni).encode.byteslice(0, 4)) }],
      [:no_inner_frame,  'a header and nothing after it (the RFC says nothing of a cut packet)', :drop, '7348 5',
       ->(vni, _inner) { Packet.new(Header.new(vni), String.new) }],
      [:inner_too_short, 'an inner frame of 13 octets, one short of an Ethernet header', :drop, '7348 5',
       ->(vni, inner) { Packet.new(Header.new(vni), inner.byteslice(0, 13)) }]
    ].freeze

    module_function

    # The catalog names: what a control plane lists and build takes.
    def names
      CATALOG.map(&:first)
    end

    # The entries, as Hashes.
    def catalog
      CATALOG.map do |name, desc, expect, rfc, build, scope|
        { name: name, description: desc, expect: expect, rfc: "RFC #{rfc}", build: build, vtep: scope == :vtep }
      end
    end

    # The packet an entry names, for a receiver serving +vni+.
    def build(name, vni:, inner: ARP)
      entry = CATALOG.find { |e| e[0] == name }
      raise ArgumentError, "unknown fault #{name.inspect}, see Fault::CATALOG" unless entry

      entry[4].call(vni, inner.b)
    end

    # The same, as the UDP payload's octets.
    def wire(name, vni:, inner: ARP)
      build(name, vni: vni, inner: inner).encode
    end
  end
end
