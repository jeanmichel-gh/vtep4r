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
  module Daemon
    # One event, in bgp4r's shape (bgp4r bgp/events.rb), so routescope
    # reads vtep4rd's stream as it reads bgp4rd's:
    #
    #   {"seq":121,"time":"2026-11-17T21:20:00.123Z","level":"info",
    #    "kind":"mac","peer":"10.255.0.12","message":"...","data":{...}}
    #
    # peer is the remote VTEP when there is one. data holds the rest:
    # vni, mac, type and port for a mac event.
    Event = Struct.new(:seq, :time, :level, :kind, :peer, :message, :data) do
      def iso_time
        time.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      end

      def to_h
        { seq: seq, time: iso_time, level: level.to_s, kind: kind.to_s, peer: peer, message: message, data: data || {} }
      end
    end

    # The events vtep4rd keeps and streams: a backlog for since, and one
    # queue per subscriber. Thread safe: the worker publishes, the API's
    # threads read.
    #
    # A reader that asks since a sequence no longer kept, or that reads
    # too slowly, gets an overflow event saying how many it lost, as
    # bgp4rd's do: a quiet stream and a lossy one must not look alike.
    class Events
      # vtep4rd's kinds. vtep4r-sim passes its own; overflow is always
      # among them.
      KINDS = %i[mac drop config overflow].freeze
      BACKLOG = 2000
      MAX_QUEUE = 10_000

      attr_reader :backlog_limit, :kinds

      def initialize(backlog: BACKLOG, max_queue: MAX_QUEUE, clock: -> { Time.now }, kinds: KINDS)
        @kinds = (kinds.map(&:to_sym) | [:overflow]).freeze
        @backlog_limit = backlog
        @max_queue = max_queue
        @clock = clock
        @seq = 0
        @kept = []
        @subs = []
        @lock = Mutex.new
      end

      def seq
        @lock.synchronize { @seq }
      end

      def publish(kind, message, level: :info, peer: nil, data: {})
        raise ArgumentError, "unknown event kind #{kind.inspect}; kinds: #{@kinds.join(', ')}" unless @kinds.include?(kind)

        @lock.synchronize do
          ev = Event.new(@seq += 1, @clock.call, level, kind, peer, message, data)
          @kept << ev
          @kept.shift(@kept.size - @backlog_limit) if @kept.size > @backlog_limit
          @subs.each { |s| s.push(ev) }
          ev
        end
      end

      # The kept events after +n+, with an overflow first when some after
      # +n+ are no longer kept.
      def since(n)
        @lock.synchronize { _since(n) }
      end

      # A Subscription; +since+ replays what is kept after it.
      def subscribe(kinds: nil, since: nil)
        kinds = kinds&.map(&:to_sym)
        unknown = Array(kinds) - @kinds
        raise ArgumentError, "unknown event kind #{unknown.join(', ')}; kinds: #{@kinds.join(', ')}" unless unknown.empty?

        @lock.synchronize do
          sub = Subscription.new(kinds, @max_queue, @clock)
          _since(since).each { |e| sub.push(e) } unless since.nil?
          sub.replayed!
          @subs << sub
          sub
        end
      end

      def unsubscribe(sub)
        @lock.synchronize { @subs.delete(sub) }
        nil
      end

      def subscribers
        @lock.synchronize { @subs.size }
      end

      private

      def _since(n)
        n = Integer(n)
        out = @kept.select { |e| e.seq > n }
        first = @kept.first&.seq || (@seq + 1)
        lost = [first - n - 1, 0].max
        lost = [lost, @seq - n].min
        return out if lost.zero?

        [Event.new(nil, @clock.call, :warn, :overflow, nil, "#{lost} event(s) missed: they are no longer kept",
                   { reason: 'backlog', lost: lost })] + out
      end

      # One reader's queue. take answers the events waiting, waiting up to
      # +timeout+ for the first.
      class Subscription
        attr_reader :kinds, :replayed

        def initialize(kinds, limit, clock)
          @kinds = kinds
          @limit = limit
          @clock = clock
          @queue = []
          @missed = 0
          @lock = Mutex.new
          @ready = ConditionVariable.new
        end

        def push(ev)
          return if @kinds && !@kinds.include?(ev.kind) && ev.kind != :overflow

          @lock.synchronize do
            if @queue.size >= @limit
              @missed += 1
            else
              @queue << ev
            end
            @ready.signal
          end
        end

        def replayed!
          @lock.synchronize { @replayed = @queue.size }
        end

        def take(timeout)
          @lock.synchronize do
            @ready.wait(@lock, timeout) if @queue.empty? && @missed.zero?
            out = @queue.dup
            @queue.clear
            if @missed.positive?
              out.unshift(Event.new(nil, @clock.call, :warn, :overflow, nil,
                                    "#{@missed} event(s) dropped: reading too slowly",
                                    { reason: 'slow_reader', lost: @missed }))
              @missed = 0
            end
            out
          end
        end
      end
    end
  end
end
