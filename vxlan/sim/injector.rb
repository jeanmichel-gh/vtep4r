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
require 'time'
require 'vxlan/version'
require 'vxlan/packet'
require 'vxlan/fault'
require 'vxlan/gen'
require 'vxlan/vtep/forwarder'
require 'vxlan/daemon/events'

module VXLAN
  module Sim
    # A request the caller can fix: HTTP 400.
    class Refused < ArgumentError; end
    # A state that refuses it for now, a generation already running: 409.
    class Busy < StandardError; end

    # What vtep4r-sim does: send crafted packets and generated traffic to
    # a VTEP, and say what it sent. It keeps no MAC table and forwards
    # nothing (CLAUDE.md, "Two programs, not one").
    #
    # +sender+ answers send(octets, vtep, source_port): a Vtep::UdpSender,
    # or a stand-in in tests. +clock+ answers seconds and +sleeper+ waits,
    # so a test paces without waiting.
    class Injector
      # action => the body keys it takes. Unknown keys are refused by name.
      ACTIONS = {
        'send' => %w[to vni flags reserved1 reserved2 inner source_port],
        'fault' => %w[to case vni inner source_port],
        'generate' => %w[to spec per_second source_port],
        'stop' => []
      }.freeze
      EVENT_KINDS = %i[send fault generate].freeze

      attr_reader :events

      def initialize(config, sender:, clock: nil, sleeper: nil, logger: nil)
        @config = config
        @sender = sender
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        # Without a test's sleeper, the pacing wait is on @wake, which stop
        # signals: a stop never waits out a slow rate's interval.
        @sleeper = sleeper || ->(s) { @lock.synchronize { @wake.wait(@lock, s) unless @stop } }
        @logger = logger
        @events = Daemon::Events.new(kinds: EVENT_KINDS)
        @lock = Mutex.new
        @wake = ConditionVariable.new
        @started = @clock.call
        @counts = { send: 0, fault: Hash.new(0), octets: 0 }
        @gen = nil
      end

      def act(action, body)
        keys = ACTIONS.fetch(action) { raise Refused, "unknown action #{action}; one of #{ACTIONS.keys.join(', ')}" }
        unknown = body.keys - keys
        raise Refused, "#{action} takes #{keys.join(', ')}; not #{unknown.join(', ')}" unless unknown.empty?

        __send__("do_#{action}", body)
      end

      # A dry run: what a spec would send, paged, and nothing sent.
      def plan(body)
        unknown = body.keys - %w[spec offset limit]
        raise Refused, "plan takes spec, offset, limit; not #{unknown.join(', ')}" unless unknown.empty?

        gen = gen(body['spec'])
        offset = Integer(body.fetch('offset', 0))
        limit = Integer(body.fetch('limit', 500)).clamp(1, 10_000)
        rows = gen.expected.drop(offset).first(limit)
        nxt = offset + rows.size < gen.count ? offset + rows.size : nil
        { rows: rows, total: gen.count, offset: offset, limit: limit, next_offset: nxt }
      end

      def status
        g = @lock.synchronize { @gen&.dup }
        { version: VXLAN::VERSION, local: @config.local, port: @config.port, generating: g&.fetch(:state) == 'running',
          packets: total_packets, uptime: (@clock.call - @started).round(1) }
      end

      def sent
        @lock.synchronize do
          { send: @counts[:send], fault: @counts[:fault].dup, octets: @counts[:octets],
            generate: @gen && @gen.reject { |k, _| k == :thread } }
        end
      end

      def topology
        { local: @config.local, port: @config.port, actions: ACTIONS,
          faults: Fault.catalog.map { |e| e.reject { |k, _| k == :build } },
          inners: Gen::INNERS, spec_keys: Gen::KEYS }
      end

      def events_since(params)
        n = Integer(params.fetch('since', 0))
        { seq: @events.seq, events: @events.since(n).map(&:to_h) }
      rescue ArgumentError
        raise Refused, "since: #{params['since'].inspect} is not a sequence number"
      end

      # Waits for a running generation to end; for tests and a clean stop.
      def join(timeout = nil)
        t = @lock.synchronize { @gen && @gen[:thread] }
        t&.join(timeout)
      end

      private

      def do_send(b)
        header = Header.new(b.slice('vni', 'flags', 'reserved1', 'reserved2').transform_keys(&:to_sym)
                             .tap { |h| raise Refused, 'send needs vni' unless h.key?(:vni) })
        pk = Packet.new(header, inner(b))
        out(:send, pk, b, "send #{header} to #{to(b)}")
        { sent: 1, to: to(b), octets: pk.encode.bytesize }
      rescue ArgumentError => e
        raise Refused, e.message
      end

      def do_fault(b)
        name = b['case'].to_s.to_sym
        raise Refused, "case #{b['case'].inspect}: one of #{Fault.names.join(', ')}" unless Fault.names.include?(name)
        raise Refused, 'fault needs vni, the receiver\'s VNI' unless b['vni'].is_a?(Integer)

        pk = Fault.build(name, vni: b['vni'], inner: inner(b))
        entry = Fault.catalog.find { |e| e[:name] == name }
        out(:fault, pk, b, "fault #{name} to #{to(b)}", name: name)
        { sent: 1, to: to(b), case: name, expect: entry[:expect], rfc: entry[:rfc] }
      end

      def do_generate(b)
        g = gen(b['spec'])
        rate = b['per_second']
        raise Refused, "per_second: #{rate.inspect} is not a positive number" unless rate.nil? || (rate.is_a?(Numeric) && rate.positive?)

        dest = to(b)
        @lock.synchronize do
          raise Busy, "a generation is running: #{@gen[:sent]} of #{@gen[:total]} sent; stop it first" if @gen&.fetch(:state) == 'running'

          @gen = { state: 'running', to: dest, total: g.count, sent: 0, per_second: rate, spec: b['spec'],
                   started_at: Time.now.utc.iso8601(3), finished_at: nil }
          @stop = false
          @gen[:thread] = Thread.new { run(g, dest, rate, b) }
        end
        @events.publish(:generate, "generate #{g.count} packets to #{dest}", peer: dest, data: { total: g.count })
        { started: true, to: dest, total: g.count, per_second: rate }
      end

      def do_stop(_b)
        t = nil
        @lock.synchronize do
          return { stopped: false, sent: @gen ? @gen[:sent] : 0 } unless @gen&.fetch(:state) == 'running'

          @stop = true
          @wake.broadcast
          t = @gen[:thread]
        end
        t.join(5)
        @lock.synchronize { { stopped: true, sent: @gen[:sent] } }
      end

      # Paced from the start, so a slow send is caught up, not added.
      def run(gen, dest, rate, body)
        t0 = @clock.call
        gen.each_with_index do |pk, i|
          break if @lock.synchronize { @stop }

          if rate
            wait = t0 + (i / rate.to_f) - @clock.call
            @sleeper.call(wait) if wait.positive?
            # A stop that woke the wait sends nothing more.
            break if @lock.synchronize { @stop }
          end
          send_packet(pk, dest, body)
          @lock.synchronize { @gen[:sent] += 1 }
        end
        state = @lock.synchronize do
          @gen[:state] = @stop ? 'stopped' : 'finished'
          @gen[:finished_at] = Time.now.utc.iso8601(3)
          @gen.dup
        end
        @events.publish(:generate, "generate #{state[:state]}: #{state[:sent]} of #{state[:total]} sent",
                        peer: dest, data: { state: state[:state], sent: state[:sent], total: state[:total] })
      rescue StandardError => e
        @lock.synchronize { @gen[:state] = 'failed' }
        @logger&.call(:error, "generate: #{e.class}: #{e.message}")
      end

      def out(kind, pk, body, message, name: nil)
        send_packet(pk, to(body), body)
        @lock.synchronize { kind == :fault ? @counts[:fault][name] += 1 : @counts[:send] += 1 }
        @events.publish(kind, message, peer: to(body), data: { octets: pk.encode.bytesize, case: name }.compact)
      end

      def send_packet(pk, dest, body)
        octets = pk.encode
        @sender.send(octets, dest, source_port(pk, body))
        @lock.synchronize { @counts[:octets] += octets.bytesize }
      end

      # The body's, or a hash of the inner Ethernet header, as vtep4rd's,
      # so a flow keeps its port (RFC 7348 section 5).
      def source_port(pk, body)
        sp = body['source_port']
        return sp if sp.is_a?(Integer) && sp.between?(1, 65_535)
        raise Refused, "source_port: #{sp.inspect} is not 1 to 65535" unless sp.nil?
        return Vtep::Forwarder::PORT_BASE if pk.inner.nil? || pk.inner.bytesize < Vtep::Forwarder::ETHERNET_HEADER

        Vtep::Forwarder.source_port(pk.inner)
      end

      def to(body)
        a = body['to'] or raise Refused, 'to: the VTEP to send to is required'
        IPAddr.new(a.to_s).ipv4? or raise Refused, "to: #{a} is not IPv4"
        a.to_s
      rescue IPAddr::Error
        raise Refused, "to: #{a.inspect} is not an address"
      end

      # The inner frame: hex in the body, or the kernel's ARP request.
      def inner(body)
        h = body['inner']
        return Fault::ARP if h.nil?
        raise Refused, "inner: #{h.inspect} is not an even number of hex digits" unless h.is_a?(String) && h.match?(/\A(\h\h)*\z/)

        [h].pack('H*')
      end

      def gen(spec)
        raise Refused, 'spec: a Gen spec is required (docs/design/vtep4r.md, VXLAN::Gen)' unless spec.is_a?(Hash)

        Gen.new(spec)
      rescue Gen::SpecError => e
        raise Refused, "spec: #{e.message}"
      end

      def total_packets
        @lock.synchronize { @counts[:send] + @counts[:fault].values.sum + (@gen ? @gen[:sent] : 0) }
      end
    end
  end
end
