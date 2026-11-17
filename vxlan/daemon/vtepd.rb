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

require 'vxlan/logging'
require 'vxlan/vtep'
require 'vxlan/vtep/ports'
require 'vxlan/vtep/tunnel'
require 'vxlan/daemon/config'
require 'vxlan/daemon/events'

module VXLAN
  module Daemon
    # vtep4rd's running part: the edges wired to a Vtep::Switch.
    #
    # **One worker thread owns the Switch.** Each port has a reader thread,
    # the tunnel has one, and the ager ticks; all of them only push work
    # on a queue, so a reader never blocks on forwarding (CLAUDE.md, "the
    # thread that reads a port must not block") and the Switch needs no
    # lock. Anything else that reads or changes the state, such as the
    # control API, runs its block on that thread through #on_worker.
    #
    # What happens is published on #events: MACs learned, moved and aged,
    # drops, and configuration changes.
    #
    # The clock is a callable answering seconds, so a test can move time.
    class Vtepd
      include VXLAN::Logging

      POLL = 0.2   # seconds a reader waits before checking it should stop

      # Keys of the file a reload cannot apply to a running vtep4rd.
      RESTART_KEYS = %i[local mtu receive_policy socket].freeze

      attr_reader :config, :switch, :counters, :events

      def initialize(config, ports:, tunnel:, clock: nil, logger: nil, age_every: 1.0, events: nil)
        @config = config
        @switch = Vtep::Switch.new(**config.switch_args)
        @ports = ports
        @tunnel = tunnel
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        self.logger = logger if logger
        @age_every = age_every
        @events = events || Events.new
        @queue = Queue.new
        @threads = []
        @readers = {}
        @counters = { ports: Hash.new { |h, k| h[k] = { rx: 0, tx: 0 } },
                      peers: Hash.new { |h, k| h[k] = { rx: 0, tx: 0 } } }
      end

      def start
        @running = true
        @threads << Thread.new { work }
        @ports.names.each { |n| start_reader(n) }
        @threads << Thread.new { read_tunnel }
        @threads << Thread.new { tick } if @age_every
        log(:info, "vtep4rd #{@config.local}: vnis #{@switch.bridges.map(&:vni).join(', ')}, " \
                   "ports #{@ports.names.join(', ')}")
        self
      end

      def stop
        @running = false
        @queue.push([:stop])
        (@threads + @readers.values).each { |t| t.join(2) || t.kill }
        @threads.clear
        @readers.clear
        @ports.close
        @tunnel.close
        self
      end

      # Runs the block on the worker thread with the Switch, and answers
      # its value. Raises what the block raised.
      def on_worker(&block)
        reply = Queue.new
        @queue.push([:call, block, reply])
        ok, value = reply.pop
        ok ? value : raise(value)
      end

      # A reload's report in words: "changed 100; needs_restart local", or
      # "nothing changed". Plain text, not a Hash's inspect, whose form
      # differs between Ruby versions.
      def self.describe(report)
        parts = report.reject { |_, l| l.empty? }.map { |k, l| "#{k} #{l.join(', ')}" }
        parts.empty? ? 'nothing changed' : parts.join('; ')
      end

      # The host ports open now, sorted.
      def port_names
        @ports.names.sort
      end

      # Age the MAC tables now, on the worker thread.
      def age_now
        on_worker { |sw| sw.age(@clock.call) && nil }
      end

      # A VNI added at run time: its bridge domain, and its ports opened.
      # +args+ as a vnis entry of the file.
      def add_vni(**args)
        on_worker do |sw|
          bd = sw.add_vni(**args)
          bd.ports.each { |p| start_reader(p) if @ports.open(p) }
          config_event("vni #{bd.vni} added, ports #{bd.ports.join(', ')}", vni: bd.vni)
          bd
        end
      end

      # A VNI removed: its bridge domain, its MAC table, its ports closed.
      def del_vni(vni)
        on_worker do |sw|
          bd = sw.del_vni(vni) or raise ArgumentError, "no vni #{vni}"
          bd.ports.each { |p| @ports.close_port(p) }
          config_event("vni #{vni} removed", vni: vni)
          bd
        end
      end

      # The file again, as SIGHUP and config.reload: VNIs added, removed
      # or replaced (when their ports or mode changed, which loses their
      # MACs), and a learn-mode VNI's flood list and any VNI's ageing set
      # in place. A key in RESTART_KEYS that changed is reported, not
      # applied.
      def reload(new_config)
        restart = RESTART_KEYS.reject { |k| new_config.public_send(k) == @config.public_send(k) }
        report = { added: [], removed: [], replaced: [], changed: [], needs_restart: restart }
        old = @config.vnis.to_h { |v| [v[:vni], v] }
        new = new_config.vnis.to_h { |v| [v[:vni], v] }
        (old.keys - new.keys).each { |vni| del_vni(vni) && report[:removed] << vni }
        new.each do |vni, v|
          was = old[vni]
          if was.nil?
            add_vni(**v) && report[:added] << vni
          elsif was[:ports] != v[:ports] || was[:mode] != v[:mode]
            del_vni(vni)
            add_vni(**v)
            report[:replaced] << vni
          elsif in_place(vni, v)
            report[:changed] << vni
          end
        end
        @config = new_config
        on_worker { config_event("reloaded: #{Vtepd.describe(report)}", report: report) }
        report
      end

      private

      def in_place(vni, v)
        on_worker do |sw|
          bd = sw.bridge(vni)
          ageing = bd.macs.ageing != v[:ageing] && (bd.macs.ageing = v[:ageing])
          flood = bd.learn_remote? && bd.flood_replace(v[:flood])
          ageing || flood
        end
      end

      def start_reader(name)
        @readers[name] = Thread.new { read_port(name) }
      end

      # A port closed under its reader (vni.del) ends the loop: Linux
      # raises IOError, the loopback backend Datalink::Error. Only an error
      # on a port that should still be open is logged.
      def read_port(name)
        while @running && @ports.open?(name)
          octets = @ports.recv(name, POLL)
          @queue.push([:port, name, octets]) if octets
        end
      rescue IOError, SystemCallError, Datalink::Error => e
        log(:error, "port #{name}: #{e.message}") if @running && @ports.open?(name)
      end

      def read_tunnel
        while @running
          from, octets = @tunnel.recv(POLL)
          @queue.push([:tunnel, from, octets]) if from
        end
      rescue IOError, SystemCallError => e
        log(:error, "tunnel: #{e.message}") if @running
      end

      def tick
        while @running
          sleep @age_every
          @queue.push([:age])
        end
      end

      def work
        loop do
          job = @queue.pop
          case job[0]
          when :stop then break
          when :port
            @counters[:ports][job[1]][:rx] += 1
            execute(@switch.from_port(job[1], job[2], @clock.call), port: job[1])
          when :tunnel
            @counters[:peers][job[1]][:rx] += 1
            execute(@switch.from_tunnel(job[1], job[2], @clock.call), peer: job[1])
          when :age then @switch.age(@clock.call)
          when :call then call(job[1], job[2])
          end
          report_events
        end
      end

      def call(block, reply)
        reply.push([true, block.call(@switch)])
      rescue StandardError => e
        reply.push([false, e])
      end

      def execute(actions, port: nil, peer: nil)
        actions.each do |a|
          case a
          when Vtep::Deliver
            @ports.send(a.port, a.octets)
            @counters[:ports][a.port][:tx] += 1
          when Vtep::Tunnel
            @tunnel.send(a.packet.encode, a.vtep, a.source_port)
            @counters[:peers][a.vtep][:tx] += 1
          when Vtep::Drop
            log(:debug, "drop #{a.reason}")
            @events.publish(:drop, "drop #{a.reason}#{peer ? " from #{peer}" : ''}#{port ? " on #{port}" : ''}",
                            peer: peer, data: { reason: a.reason.to_s, port: port }.compact)
          end
        rescue IOError, SystemCallError => e
          log(:warn, "#{a.class.name.split('::').last.downcase}: #{e.message}")
        end
      end

      # Learned, moved and aged MACs, logged and published as they happen.
      def report_events
        @switch.events.each do |e|
          where = e.location ? " at #{e.location}" : ''
          log(:info, "mac #{e.type} vni #{e.vni} #{e.mac}#{where}")
          loc = e.location
          @events.publish(:mac, "mac #{e.type} vni #{e.vni} #{e.mac}#{where}",
                          peer: (loc.name if loc&.vtep?),
                          data: { type: e.type.to_s, vni: e.vni, mac: e.mac.to_s, port: (loc.name if loc&.port?) }.compact)
        end
        @switch.events.clear
      end

      def config_event(message, data)
        log(:info, message)
        @events.publish(:config, message, data: data)
      end
    end
  end
end
