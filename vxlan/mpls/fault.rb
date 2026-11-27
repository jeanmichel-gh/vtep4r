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

require 'vxlan/fault'
require 'vxlan/mpls/packet'
require 'vxlan/mpls/validation'

module VXLAN
  module Mpls
    # The catalog of crafted EVPN-over-MPLS packets, as VXLAN::Fault is
    # for VXLAN. Each is built for a receiver whose EVPN label is +label+.
    module Fault
      ARP = VXLAN::Fault::ARP

      # Each entry: [name, description, what the receiver should do
      # (:drop, :ignore for a field it passes over, :deliver for a packet
      # it takes whole), the RFC section, a block (label, inner) that
      # builds the packet], and :vtep after them for an entry only a VTEP
      # can judge, since it depends on the labels it gave out.
      CATALOG = [
        [:no_bottom,           'the EVPN label with its S bit clear',          :drop,    '3032 2.1',
         ->(label, inner) { Packet.new([Label.new(label: label)], ControlWord.new, inner) }],
        [:no_control_word,     'the bottom label and two octets after it',     :drop,    '7432 18, 4385 3',
         ->(label, _inner) { Packet.new(Label.new(label: label, s: 1).encode + "\x00\x00".b) }],
        [:control_word_nibble, 'a control word whose first four bits are 4, as IPv4', :drop, '4385 3',
         ->(label, inner) { Packet.new([label], ControlWord.new(nibble: 4), inner) }],
        [:control_word_set,    'a control word with its flags and sequence set', :ignore, '7432 18',
         ->(label, inner) { Packet.new([label], ControlWord.new(flags: 0xf, sequence: 1), inner) }],
        [:inner_too_short,     'an inner frame of 13 octets, one short of an Ethernet header', :drop, '7432 18',
         ->(label, inner) { Packet.new([label], ControlWord.new, inner.byteslice(0, 13)) }],
        [:unknown_label,       'a label the receiver did not give out',        :drop,    '3031 3.18',
         ->(label, inner) { Packet.new([(label + 1) & 0xfffff], ControlWord.new, inner) }, :vtep],
        [:ipv4_explicit_null,  'an IPv4 explicit null above the EVPN label',   :deliver, '4182 2',
         ->(label, inner) { Packet.new([Label::IPV4_EXPLICIT_NULL, label], ControlWord.new, inner) }, :vtep],
        [:ipv6_explicit_null,  'an IPv6 explicit null above the EVPN label',   :deliver, '4182 2',
         ->(label, inner) { Packet.new([Label::IPV6_EXPLICIT_NULL, label], ControlWord.new, inner) }, :vtep]
      ].freeze

      module_function

      def names
        CATALOG.map(&:first)
      end

      # The entries, as Hashes.
      def catalog
        CATALOG.map do |name, desc, expect, rfc, build, scope|
          { name: name, description: desc, expect: expect, rfc: "RFC #{rfc}", build: build, vtep: scope == :vtep }
        end
      end

      # The packet an entry names, for a receiver whose EVPN label is +label+.
      def build(name, label:, inner: ARP)
        entry = CATALOG.find { |e| e[0] == name }
        raise ArgumentError, "unknown fault #{name.inspect}, see Mpls::Fault::CATALOG" unless entry

        entry[4].call(label, inner.b)
      end

      # The same, as the octets after the Ethernet header.
      def wire(name, label:, inner: ARP)
        build(name, label: label, inner: inner).encode
      end
    end
  end
end
