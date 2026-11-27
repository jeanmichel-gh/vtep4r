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

module VXLAN
  module Mpls
    # The control word after the bottom label, RFC 4385 section 3, in its
    # preferred format (Figure 2):
    #
    #   |0 0 0 0| Flags |FRG|  Length   | Sequence Number               |
    #
    # The first four bits are zero in every control word: they "differ
    # from the first four bits of an IP packet". RFC 7432 section 18 sends
    # EVPN's "with the value 0 (e.g., a 4-octet field with a value of
    # zero)", so the default is four zero octets.
    #
    # Built four ways:
    #
    #   ControlWord.new(0)                     # field value: the sequence number
    #   ControlWord.new(flags: 1, length: 30)  # a hash
    #   ControlWord.new(octets)                # wire bytes, the first four
    #   ControlWord.new(other)                 # another instance
    #
    # **Building is never validated.** The first nibble is a field like the
    # others, so a control word that looks like IP can be sent.
    class ControlWord
      SIZE = 4

      FIELDS = { nibble: [0, 0xf], flags: [0, 0xf], frg: [0, 3], length: [0, 0x3f], sequence: [0, 0xffff] }.freeze

      attr_reader :nibble, :flags, :frg, :length, :sequence

      def initialize(arg = {})
        case arg
        when String then parse(arg)
        when ControlWord then parse(arg.encode)
        when Integer then set(sequence: arg)
        when Hash then set(**arg)
        else raise ArgumentError, "invalid argument, #{arg.inspect}"
        end
      end

      def encode
        [(@nibble << 28) | (@flags << 24) | (@frg << 22) | (@length << 16) | @sequence].pack('N')
      end

      def to_shex
        encode.unpack1('H*')
      end

      # Each field that is not zero: {} for EVPN's control word. Round
      # trips through new.
      def to_hash
        FIELDS.each_key.with_object({}) do |name, h|
          value = instance_variable_get("@#{name}")
          h[name] = value unless value.zero?
        end
      end

      def to_s
        format('control word 0x%08x', encode.unpack1('N'))
      end

      def ==(other)
        other.is_a?(ControlWord) && encode == other.encode
      end
      alias eql? ==

      def hash
        encode.hash
      end

      private

      def parse(octets)
        raise ArgumentError, "a control word is #{SIZE} octets, got #{octets.bytesize}" if octets.bytesize < SIZE

        word = octets.byteslice(0, SIZE).unpack1('N')
        @nibble = word >> 28
        @flags = (word >> 24) & 0xf
        @frg = (word >> 22) & 3
        @length = (word >> 16) & 0x3f
        @sequence = word & 0xffff
      end

      def set(**fields)
        unknown = fields.keys - FIELDS.keys
        raise ArgumentError, "unknown control word field #{unknown.join(', ')}" unless unknown.empty?

        FIELDS.each do |name, (default, max)|
          value = fields.fetch(name, default)
          unless value.is_a?(Integer) && value.between?(0, max)
            raise ArgumentError, "#{name} #{value.inspect} does not fit (0 to 0x#{max.to_s(16)})"
          end

          instance_variable_set("@#{name}", value)
        end
      end
    end
  end
end
