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
    # The clock is a callable answering seconds, so a test can move time.
    class Vtepd
      include VXLAN::Logging

      POLL = 0.2   # seconds a reader waits before checking it should stop

      attr_reader :config, :switch, :counters

      def initialize(config, ports:, tunnel:, clock: nil, logger: nil, age_every: 1.0)
        @config = config
        @switch = Vtep::Switch.new(**config.switch_args)
        @ports = ports
        @tunnel = tunnel
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        self.logger = logger if logger
        @age_every = age_every
        @queue = Queue.new
        @threads = []
        @counters = { ports: Hash.new { |h, k| h[k] = { rx: 0, tx: 0 } },
                      peers: Hash.new { |h, k| h[k] = { rx: 0, tx: 0 } } }
      end

      def start
        @running = true
        @threads << Thread.new { work }
        @ports.names.each { |n| @threads << Thread.new { read_port(n) } }
        @threads << Thread.new { read_tunnel }
        @threads << Thread.new { tick } if @age_every
        log(:info, "vtep4rd #{@config.local}: vnis #{@switch.bridges.map(&:vni).join(', ')}, " \
                   "ports #{@ports.names.join(', ')}")
        self
      end

      def stop
        @running = false
        @queue.push([:stop])
        @threads.each { |t| t.join(2) || t.kill }
        @threads.clear
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

      # Age the MAC tables now, on the worker thread.
      def age_now
        on_worker { |sw| sw.age(@clock.call) && nil }
      end

      private

      def read_port(name)
        while @running
          octets = @ports.recv(name, POLL)
          @queue.push([:port, name, octets]) if octets
        end
      rescue IOError, SystemCallError => e
        log(:error, "port #{name}: #{e.message}") if @running
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
            execute(@switch.from_port(job[1], job[2], @clock.call))
          when :tunnel
            @counters[:peers][job[1]][:rx] += 1
            execute(@switch.from_tunnel(job[1], job[2], @clock.call))
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

      def execute(actions)
        actions.each do |a|
          case a
          when Vtep::Deliver
            @ports.send(a.port, a.octets)
            @counters[:ports][a.port][:tx] += 1
          when Vtep::Tunnel
            @tunnel.send(a.packet.encode, a.vtep, a.source_port)
            @counters[:peers][a.vtep][:tx] += 1
          when Vtep::Drop then log(:debug, "drop #{a.reason}")
          end
        rescue IOError, SystemCallError => e
          log(:warn, "#{a.class.name.split('::').last.downcase}: #{e.message}")
        end
      end

      # Learned, moved and aged MACs, logged as they happen. The control
      # API in step 4c streams them as events.
      def report_events
        @switch.events.each do |e|
          where = e.location ? " at #{e.location}" : ''
          log(:info, "mac #{e.type} vni #{e.vni} #{e.mac}#{where}")
        end
        @switch.events.clear
      end
    end
  end
end
