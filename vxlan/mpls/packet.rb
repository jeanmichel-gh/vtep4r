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
require 'vxlan/mpls/label'
require 'vxlan/mpls/control_word'

module VXLAN
  module Mpls
    # EVPN over MPLS, what follows an Ethernet header of EtherType 0x8847:
    # the label stack, the control word, then the customer's frame.
    #
    #   | label stack entry | ... | label stack entry, S set |
    #   | control word (RFC 4385 section 3) | the inner Ethernet frame |
    #
    # RFC 3032 section 2.1: "The network layer packet immediately follows
    # the label stack entry which has the S bit set." For EVPN that packet
    # is the control word and the frame (RFC 7432 section 18). Nothing on
    # the wire says whether a control word is there, so a parse is told:
    # it is expected unless control_word: false.
    #
    # Built four ways:
    #
    #   Packet.new([16002, 25001], ControlWord.new, frame)
    #       # field values: labels, a ControlWord or nil, a Datalink::Frame
    #       # or its octets. Labels given as Integers get the S bit on the
    #       # last; a Label or a hash is taken as it is.
    #   Packet.new(labels: [{ label: 25001, s: 1 }], control_word: {}, inner: 'ffff...')
    #       # a hash; no control_word key, no control word
    #   Packet.new(octets)                        # wire bytes, a control word expected
    #   Packet.new(octets, control_word: false)   # wire bytes, none
    #   Packet.new(other)                         # another instance
    #
    # **Keep what cannot be read.** A stack with no S bit is kept as the
    # entries read and the octets left, `tail`, fewer than an entry. So is
    # a control word cut short. encode always gives back what arrived.
    class Packet
      attr_reader :labels, :control_word, :inner, :tail

      def initialize(*args, **kw)
        # Packet.new(labels: [...], ...) arrives as keywords: the hash form.
        return from_hash(kw) if args.empty?

        unknown = kw.keys - [:control_word]
        raise ArgumentError, "unknown keyword #{unknown.join(', ')}" unless unknown.empty?

        @expects_control_word = kw.fetch(:control_word, true)
        if args.size == 3
          from_values(*args)
          return
        end
        raise ArgumentError, "invalid arguments, #{args.inspect}" unless args.size == 1

        arg = args[0]
        case arg
        when String then parse(arg)
        when Packet
          @expects_control_word = arg.expects_control_word?
          parse(arg.encode)
        when Hash then from_hash(arg)
        else raise ArgumentError, "invalid argument, #{arg.inspect}"
        end
      end

      # Whether a control word was asked for: on a parse, the caller's
      # word; on a build, whether one was given.
      def expects_control_word?
        @expects_control_word
      end

      # The S bit was found.
      def bottom?
        !@labels.empty? && @labels.last.bottom?
      end

      # The inner frame as a Datalink::Frame, or nil when it cannot be one.
      def frame
        return nil if @inner.nil? || @inner.empty?

        @frame ||= Datalink::Frame.parse(@inner)
      rescue Datalink::ParseError
        nil
      end

      def encode
        out = String.new
        @labels.each { |l| out << l.encode }
        out << @control_word.encode if @control_word
        out << @inner if @inner
        out << @tail if @tail
        out
      end

      def to_shex
        encode.unpack1('H*')
      end

      # { labels: [...], control_word: {...}, inner: hex }, with tail: for
      # what could not be read, and control_word: nil for one expected and
      # missing. Round trips through new.
      def to_hash
        h = { labels: @labels.map(&:to_hash) }
        h[:control_word] = @control_word&.to_hash if @expects_control_word
        h[:inner] = @inner.unpack1('H*') if @inner
        h[:tail] = @tail.unpack1('H*') if @tail
        h
      end

      # tcpdump's form for the stack, then the control word and the frame.
      def to_s
        parts = ["MPLS #{@labels.map(&:to_s).join(' ')}"]
        parts << @control_word.to_s if @control_word
        f = frame
        parts << (f ? f.to_s : "#{@inner.bytesize} octets") if @inner
        parts << "#{@tail.bytesize} octets left" if @tail
        parts.join(': ')
      end

      def ==(other)
        other.is_a?(Packet) && encode == other.encode
      end
      alias eql? ==

      def hash
        encode.hash
      end

      private

      def parse(octets)
        octets = octets.b
        @labels = []
        at = 0
        while octets.bytesize - at >= Label::SIZE
          l = Label.new(octets.byteslice(at, Label::SIZE))
          @labels << l
          at += Label::SIZE
          break if l.bottom?
        end
        rest = octets.byteslice(at..)
        unless bottom?
          @tail = rest unless rest.empty?
          return
        end
        if !@expects_control_word
          @inner = rest
        elsif rest.bytesize < ControlWord::SIZE
          @tail = rest unless rest.empty?
        else
          @control_word = ControlWord.new(rest)
          @inner = rest.byteslice(ControlWord::SIZE..)
        end
      end

      def from_values(labels, control_word, inner)
        labels = Array(labels)
        @labels = labels.each_with_index.map do |l, i|
          case l
          when Label then l
          when Integer then Label.new(label: l, s: i == labels.size - 1 ? 1 : 0)
          else Label.new(l)
          end
        end
        @control_word = control_word.nil? || control_word.is_a?(ControlWord) ? control_word : ControlWord.new(control_word)
        @expects_control_word = !@control_word.nil?
        @inner = octets_of(inner)
      end

      def from_hash(hash)
        unknown = hash.keys - %i[labels control_word inner tail]
        raise ArgumentError, "unknown packet key #{unknown.join(', ')}" unless unknown.empty?

        @labels = hash.fetch(:labels, []).map { |l| l.is_a?(Label) ? l : Label.new(l) }
        cw = hash[:control_word]
        @control_word = cw.nil? || cw.is_a?(ControlWord) ? cw : ControlWord.new(cw)
        @expects_control_word = hash.key?(:control_word)
        @inner = hex_or_octets(hash[:inner]) if hash.key?(:inner)
        @tail = hex_or_octets(hash[:tail]) if hash.key?(:tail)
      end

      def hex_or_octets(v)
        v.is_a?(String) ? [v].pack('H*') : octets_of(v)
      end

      # A Datalink::Frame, or octets.
      def octets_of(inner)
        return inner.encode.b if inner.respond_to?(:encode) && !inner.is_a?(String)
        raise ArgumentError, "invalid inner frame, #{inner.inspect}" unless inner.is_a?(String)

        inner.b
      end
    end
  end
end
