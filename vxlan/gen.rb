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

require 'ipaddr'
require 'datalink'
require 'vxlan/packet'
require 'vxlan/gen/vary'

module VXLAN
  # Generated VXLAN traffic, after bgp4r's BGP::Gen: a spec in plain JSON
  # types in, Packets out, with no socket, thread or clock. The same spec
  # is a Hash in a test, an HTTP body to vtep4r-sim and a routescope
  # scenario step. Pacing is the sim's, not this module's.
  #
  #   VXLAN::Gen.new('vni' => 100, 'macs' => 1000).each { |pk| ... }
  #
  # The spec:
  #
  #   vni                    the VNI, or an integer pattern (Gen::Vary); required
  #   flags, reserved1,      the header's other fields, plain or patterns, as
  #   reserved2              VXLAN::Header takes them; any bits, on purpose
  #   inner                  broadcast (the default), unicast (needs dst) or arp
  #   src                    the first source MAC (02:00:00:00:00:01)
  #   macs                   how many distinct sources, counting up from src (1)
  #   count                  how many packets (macs); past macs the sources cycle
  #   dst                    the destination MAC, for unicast
  #   ethertype              for broadcast and unicast (0x88b5, local experimental)
  #   size                   the inner frame's octets (60; 42 for arp, as the
  #                          kernel sends it); at least 14, or 42 for arp
  #   sender_ip, target_ip   for arp: the sender steps with the source
  #   seed                   required when a pattern is random
  #
  # **Nothing validates** (CLAUDE.md, Conventions). A spec is refused only
  # when it cannot be read: an unknown key, a wrong type, a value too wide
  # for its field.
  class Gen
    include Enumerable

    KEYS = %w[vni flags reserved1 reserved2 inner src macs count dst ethertype size sender_ip target_ip seed].freeze
    INNERS = %w[broadcast unicast arp].freeze
    BROADCAST = 'ff:ff:ff:ff:ff:ff'

    attr_reader :count

    def initialize(spec)
      raise SpecError, "a spec is a mapping, got #{spec.class}" unless spec.is_a?(Hash)

      s = spec.transform_keys(&:to_s)
      unknown = s.keys - KEYS
      raise SpecError, "unknown key #{unknown.join(', ')}; a spec takes #{KEYS.join(', ')}" unless unknown.empty?
      raise SpecError, 'vni is required' unless s.key?('vni')

      seed = s['seed']
      raise SpecError, "seed: #{seed.inspect} is not an integer" unless seed.nil? || seed.is_a?(Integer)

      @fields = { vni: Vary.compile(s['vni'], 'vni', max: 0xffffff, seed: seed) }
      { 'flags' => [0xff, Header::I_FLAG], 'reserved1' => [0xffffff, 0], 'reserved2' => [0xff, 0] }.each do |k, (max, d)|
        @fields[k.to_sym] = Vary.compile(s.fetch(k, d), k, max: max, seed: seed)
      end
      @inner = s.fetch('inner', 'broadcast').to_s
      raise SpecError, "inner: #{@inner}, one of #{INNERS.join(', ')}" unless INNERS.include?(@inner)

      @src = mac_number(s.fetch('src', '02:00:00:00:00:01'), 'src')
      @macs = Vary.positive(s.fetch('macs', 1), 'macs')
      @count = s.fetch('count', @macs)
      raise SpecError, "count: #{@count.inspect} is not a count" unless @count.is_a?(Integer) && !@count.negative?

      @dst = s['dst'] ? Datalink::MAC.new(s['dst']).to_s : nil
      raise SpecError, 'unicast needs dst' if @inner == 'unicast' && @dst.nil?

      @ethertype = Vary.int(s.fetch('ethertype', 0x88b5), 'ethertype', 0xffff)
      floor = @inner == 'arp' ? 42 : 14
      @size = Vary.int(s.fetch('size', @inner == 'arp' ? 42 : 60), 'size', 65_535)
      raise SpecError, "size: #{@size} is below #{floor}, the #{@inner} frame's header" if @size < floor

      @sender = ip(s.fetch('sender_ip', '172.16.0.1'), 'sender_ip') if @inner == 'arp'
      @target = ip(s.fetch('target_ip', '172.16.0.254'), 'target_ip') if @inner == 'arp'
    rescue Datalink::Error => e
      raise SpecError, e.message
    end

    # The packets, one at a time, without building an array.
    def each
      return enum_for(:each) { @count } unless block_given?

      @count.times { |i| yield packet(i) }
    end

    def packets
      to_a
    end

    # What the spec meant to send, as data: one row per packet.
    def expected
      Array.new(@count) { |i| { vni: @fields[:vni].at(i), src: src(i).to_s, dst: dst.to_s } }
    end

    private

    def packet(i)
      header = Header.new(vni: @fields[:vni].at(i), flags: @fields[:flags].at(i),
                          reserved1: @fields[:reserved1].at(i), reserved2: @fields[:reserved2].at(i))
      Packet.new(header, frame(i))
    end

    def src(i)
      n = (@src + (i % @macs)) & 0xffffffffffff
      Datalink::MAC.from_bytes([n >> 16, n & 0xffff].pack('Nn'))
    end

    def dst
      @inner == 'unicast' ? @dst : (@dst || BROADCAST)
    end

    def frame(i)
      s = src(i)
      if @inner == 'arp'
        k = i % @macs
        body = [1, 0x0800, 6, 4, 1].pack('nnCCn') + s.encode + [(@sender + k) & 0xffffffff].pack('N') +
               ("\x00".b * 6) + [@target].pack('N')
        octets = Datalink::MAC.new(dst).encode + s.encode + [0x0806].pack('n') + body
      else
        octets = Datalink::MAC.new(dst).encode + s.encode + [@ethertype].pack('n')
      end
      octets.ljust(@size, "\x00".b)
    end

    def mac_number(v, name)
      m = Datalink::MAC.new(v.to_s)
      hi, lo = m.encode.unpack('Nn')
      (hi << 16) | lo
    rescue Datalink::Error => e
      raise SpecError, "#{name}: #{e.message}"
    end

    def ip(v, name)
      IPAddr.new(v.to_s).tap { |a| raise SpecError, "#{name}: #{v} is not IPv4" unless a.ipv4? }.to_i
    rescue IPAddr::Error => e
      raise SpecError, "#{name}: #{e.message}"
    end
  end
end
