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
require 'socket'
require 'io/wait'
require 'fileutils'
require 'vxlan/version'
require 'vxlan/vtep'

module VXLAN
  module Daemon
    # vtep4rd's control API: one JSON object per line over a Unix socket,
    # in each direction, exactly as bgp4rd's and ospfd's, so routescope
    # reads it with the same one-line client:
    #
    #   -> {"id":1,"method":"show.vnis","params":{}}
    #   <- {"id":1,"result":[...]}
    #   <- {"id":1,"error":"unknown method \"show.foo\"; this vtep4rd answers ..."}
    #
    # **A bad request must not take the daemon down** (bgp4r
    # docs/daemon.md): a line that is not JSON, JSON that is not an
    # object, a line longer than MAX_LINE, a method that raises and a
    # client that goes away are each answered or ignored, one connection
    # at a time. The socket is born mode 0660.
    #
    # Every method runs on the Vtepd's worker thread, through on_worker,
    # so it sees and changes the state between two frames, never during
    # one. A mutating method is a name of its own, never a flag on a read.
    # vni.add, vni.del and config.reload call Vtepd methods that go to the
    # worker themselves, so they are not wrapped again: a block on the
    # worker waiting for the worker would never return.
    #
    # events.subscribe turns the connection into a stream, in bgp4rd's
    # form (bgp4r docs/daemon.md, "The event stream"):
    #
    #   -> {"id":2,"method":"events.subscribe","params":{"kinds":["mac"],"since":120}}
    #   <- {"id":2,"result":{"seq":131,"replayed":11,"kinds":["mac"]}}
    #   <- {"event":{"seq":121,"time":"...","level":"info","kind":"mac",...}}
    #   <- {"keepalive":"2026-11-17T21:20:15.004Z","seq":131}
    #   -> {"id":3,"method":"events.unsubscribe"}
    #   <- {"id":3,"result":{"unsubscribed":true}}
    #
    # Any other request on a streaming connection is refused with a line
    # of its own and the stream goes on.
    class Api
      MAX_LINE = 1 << 20
      MAX_CLIENTS = 32
      IDLE = 900
      KEEPALIVE = 15 # seconds between keepalive lines on an event stream
      VERSION = 1    # of this API, raised when a method changes incompatibly

      # name => ->(api, params) { result }
      METHODS = {
        'api.info' => ->(a, _p) { a.info },
        'show.status' => ->(a, _p) { a.status },
        'show.vnis' => ->(a, _p) { a.on { |sw, _now| sw.bridges.map { |bd| a.vni_row(sw, bd) } } },
        'show.macs' => ->(a, p) { a.macs(p) },
        'show.counters' => ->(a, _p) { a.counters },
        'vni.add' => ->(a, p) { a.vni_add(p) },
        'vni.del' => ->(a, p) { a.vni_del(p) },
        'vni.labels' => ->(a, p) { a.vni_labels(p) },
        'show.labels' => ->(a, _p) { a.on { |sw, _now| a.label_rows(sw) } },
        'show.transport' => ->(a, _p) { a.transport },
        'vni.flood.add' => ->(a, p) { a.flood(p, :add) },
        'vni.flood.del' => ->(a, p) { a.flood(p, :del) },
        'mac.add' => ->(a, p) { a.mac_add(p) },
        'mac.del' => ->(a, p) { a.mac_del(p) },
        'mac.flush' => ->(a, p) { a.mac_flush(p) },
        'config.reload' => ->(a, _p) { a.reload }
      }.freeze

      # The two that turn a connection into a stream and back, which
      # handle cannot answer since a stream is many lines.
      STREAM_METHODS = %w[events.subscribe events.unsubscribe].freeze

      def self.names
        (METHODS.keys + STREAM_METHODS).sort
      end

      # The version, the methods, and where the event stream has got to.
      def info
        { version: VXLAN::VERSION, api: VERSION, methods: Api.names,
          event_kinds: Events::KINDS.map(&:to_s), event_seq: @vtepd.events.seq }
      end

      class InUse < StandardError; end
      class BadPath < StandardError; end

      # sockaddr_un's sun_path is 108 octets with its terminating NUL, so
      # a path holds 107 (Linux, unix(7)). UNIXServer raises a bare
      # ArgumentError past that; this says which path and why.
      MAX_PATH = 107

      def self.check_path(path)
        return path if path.bytesize <= MAX_PATH

        raise BadPath, "the socket path #{path} is #{path.bytesize} octets; a Unix socket path holds #{MAX_PATH}"
      end

      attr_reader :path

      # +config_path+ is the file config.reload reads again; +keepalive+
      # the seconds between keepalive lines on a stream, which a test
      # shortens.
      def initialize(vtepd, path:, logger: nil, clock: nil, config_path: nil, keepalive: KEEPALIVE)
        @vtepd = vtepd
        @path = path
        @logger = logger
        @config_path = config_path
        @keepalive = keepalive
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @started = @clock.call
        @clients = []
        @lock = Mutex.new
      end

      def start
        Api.check_path(@path)
        FileUtils.mkdir_p(File.dirname(@path))
        if File.socket?(@path)
          raise InUse, "another vtep4rd answers on #{@path}" if live?

          File.delete(@path) # left behind by a daemon that died
        end
        old = File.umask(0o117)
        begin
          @server = UNIXServer.new(@path)
        ensure
          File.umask(old)
        end
        @thread = Thread.new { accept_loop }
        self
      end

      def stop
        @server.close if @server && !@server.closed?
        @thread&.join(2)
        @lock.synchronize { @clients.dup }.each { |c| c.close unless c.closed? }
        File.delete(@path) if File.socket?(@path)
        self
      end

      # One request, as a Hash with string keys, to one reply Hash.
      def handle(req)
        id = req['id']
        name = req['method'].to_s
        fn = METHODS[name] || (STREAM_METHODS.include?(name) && :stream)
        return { id: id, error: "unknown method #{name.inspect}; this vtep4rd answers #{Api.names.join(', ')}" } unless fn

        params = req['params'].is_a?(Hash) ? req['params'] : {}
        return { id: id, error: 'events.subscribe is a stream: send it on the socket' } if name == 'events.subscribe'
        return { id: id, result: { unsubscribed: false } } if name == 'events.unsubscribe'

        { id: id, result: fn.call(self, params) }
      rescue ArgumentError, KeyError, Datalink::Error => e
        { id: id, error: e.message }
      rescue StandardError => e
        log(:error, "api #{name}: #{e.class}: #{e.message}")
        { id: id, error: "internal error: #{e.class}" }
      end

      # The methods' bodies. Public so METHODS can reach them; each runs on
      # the worker thread.

      def on(&block)
        @vtepd.on_worker { |sw| block.call(sw, @clock.call) }
      end

      def status
        on do |sw, now|
          { version: VXLAN::VERSION, local: sw.local, mtu: sw.mtu, receive_policy: sw.policy,
            vnis: sw.bridges.map(&:vni), ports: @vtepd.port_names, uptime: (now - @started).round(1) }
            .tap { |r| r[:core] = @vtepd.core_names unless @vtepd.core_names.empty? }
        end
      end

      # One row per VNI, in routescope's evpn_vnis columns where they
      # apply: the flood list is head-end replication, as FRR prints it.
      #
      # encap is vxlan or mpls. An MPLS VNI adds its labels, nil until
      # vni.labels sets them, and each remote PE's BUM label.
      def vni_row(sw, bd)
        row = { vni: bd.vni, type: 'L2', vtep_ip: sw.local, ports: bd.ports, mode: bd.mode,
                remote_vteps: bd.flood, flood: 'HER', macs: bd.macs.size, ageing: bd.macs.ageing, encap: bd.encap }
        return row unless bd.mpls?

        row.merge(labels: bd.labels, flood_labels: bd.flood.to_h { |v| [v, bd.flood_label(v)] })
      end

      # Each remote PE's transport: labels, gateway and its MAC, device and
      # MTU, or why it cannot be reached; since when it was so.
      def transport
        on { |_sw, _now| @vtepd.transport_rows }
      end

      # One row per label we gave out.
      def label_rows(sw)
        sw.labels.sort.map { |label, (vni, kind)| { label: label, vni: vni, kind: kind } }
      end

      # An MPLS VNI's two labels, from bgp4rd.
      def vni_labels(p)
        unicast = p.fetch('unicast')
        bum = p.fetch('bum')
        on do |sw, _now|
          bd = bridge(sw, p)
          { vni: bd.vni, changed: sw.set_labels(bd.vni, unicast: unicast, bum: bum), labels: bd.labels }
        end
      end

      def macs(p)
        on do |sw, now|
          bds = p.key?('vni') ? [bridge(sw, p)] : sw.bridges
          bds.flat_map { |bd| bd.macs.rows(now: now).map { |r| { vni: bd.vni }.merge(r) } }
        end
      end

      def counters
        c = @vtepd.counters
        on do |sw, _now|
          { ports: c[:ports].transform_values(&:dup), peers: c[:peers].transform_values(&:dup),
            drops: sw.drops.dup, findings: sw.findings.dup }
            .tap { |r| r[:core] = c[:core].transform_values(&:dup) unless c[:core].empty? }
        end
      end

      # Over MPLS, vni.flood.add takes the remote PE's BUM label.
      def flood(p, op)
        vtep = p.fetch('vtep').to_s
        label = p['label']
        on do |sw, _now|
          bd = bridge(sw, p)
          changed = op == :add ? bd.flood_add(vtep, label: label) : bd.flood_del(vtep)
          { vni: bd.vni, vtep: vtep, changed: changed, flood: bd.flood }
            .tap { |r| r[:label] = bd.flood_label(vtep) if bd.mpls? && op == :add }
        end
      end

      # Over MPLS, mac.add takes the remote PE's label for the MAC, Label1
      # of its type 2 route; over VXLAN there is none.
      def mac_add(p)
        mac = Datalink::MAC.new(p.fetch('mac'))
        vtep = p.fetch('vtep').to_s
        seq = Integer(p.fetch('seq', 0))
        on do |sw, _now|
          bd = bridge(sw, p)
          label = p['label']
          if bd.mpls?
            raise ArgumentError, "vni #{bd.vni}: a MAC over mpls needs the remote PE's label" if label.nil?

            label = Vtep::BridgeDomain.label(label)
          elsif label
            raise ArgumentError, "vni #{bd.vni}: a label is for encap mpls"
          end
          loc = Vtep::Location.vtep(vtep, label)
          bd.macs.add(mac, loc, seq: seq)
          { vni: bd.vni, mac: mac.to_s, vtep: loc.name, seq: seq }.tap { |r| r[:label] = label if label }
        end
      end

      def mac_del(p)
        mac = Datalink::MAC.new(p.fetch('mac'))
        on { |sw, _now| { vni: bridge(sw, p).vni, mac: mac.to_s, deleted: bridge(sw, p).macs.delete(mac) } }
      end

      def mac_flush(p)
        origin = p['origin']&.to_sym
        raise ArgumentError, "origin #{origin.inspect}: learned or api" if origin && !%i[learned api].include?(origin)

        on do |sw, _now|
          bd = bridge(sw, p)
          before = bd.macs.size
          bd.macs.flush(origin: origin)
          { vni: bd.vni, flushed: before - bd.macs.size }
        end
      end

      # A VNI added: the same keys as a vnis entry of the file.
      def vni_add(p)
        unknown = p.keys - Config::VNI
        raise ArgumentError, "unknown vni key #{unknown.join(', ')}" unless unknown.empty?

        v = Config.new('local' => '0.0.0.0', 'vnis' => [p]).vnis.first
        bd = @vtepd.add_vni(**v)
        { vni: bd.vni, ports: bd.ports, mode: bd.mode, flood: bd.flood }
          .tap { |r| r.merge!(encap: bd.encap, labels: bd.labels) if bd.mpls? }
      rescue Config::Error => e
        raise ArgumentError, e.message
      end

      def vni_del(p)
        bd = @vtepd.del_vni(Integer(p.fetch('vni')))
        { vni: bd.vni, macs: bd.macs.size }
      end

      # The file again, as SIGHUP.
      def reload
        raise ArgumentError, 'this vtep4rd was not started from a file' unless @config_path

        @vtepd.reload(Config.load(@config_path))
      rescue Config::Error => e
        raise ArgumentError, "#{@config_path}: #{e.message}"
      end

      private

      def bridge(sw, p)
        vni = Integer(p.fetch('vni'))
        sw.bridge(vni) or raise ArgumentError, "no vni #{vni}; this vtep4rd has #{sw.bridges.map(&:vni).join(', ')}"
      end

      def log(level, message)
        @logger&.call(level, message)
      end

      def live?
        UNIXSocket.new(@path).close
        true
      rescue SystemCallError
        false
      end

      def accept_loop
        loop do
          client = @server.accept
          busy = @lock.synchronize { @clients.size >= MAX_CLIENTS ? true : (@clients << client && false) }
          if busy
            write(client, error: "too many connections (#{MAX_CLIENTS})")
            client.close
            next
          end
          Thread.new(client) do |c|
            serve(c)
          ensure
            @lock.synchronize { @clients.delete(c) }
            c.close unless c.closed?
          end
        end
      rescue IOError, Errno::EBADF
        nil # the server socket was closed by stop
      end

      def serve(sock)
        while sock.wait_readable(IDLE)
          req = read_request(sock)
          next if req == :skip
          break if req.nil?

          if req['method'] == 'events.subscribe'
            stream(sock, req) or break
          else
            write(sock, handle(req))
          end
        end
      rescue IOError, SystemCallError
        nil
      end

      # One request off the socket: a Hash, :skip after a bad line it
      # answered, or nil when the connection is done.
      def read_request(sock)
        line = sock.gets(MAX_LINE) or return nil
        unless line.end_with?("\n") || line.bytesize < MAX_LINE
          write(sock, error: "request longer than #{MAX_LINE} octets")
          return nil
        end
        req = JSON.parse(line)
        return req if req.is_a?(Hash)

        write(sock, error: 'a request is a JSON object')
        :skip
      rescue JSON::ParserError => e
        write(sock, error: "bad JSON: #{e.message[0, 120]}")
        :skip
      end

      # The connection's own thread polls three things in turn, as
      # bgp4rd's does: a line arriving, events waiting, and the keepalive
      # deadline. true when events.unsubscribe ended the stream and the
      # connection takes requests again; false when it is done.
      def stream(sock, req)
        params = req['params'].is_a?(Hash) ? req['params'] : {}
        sub = begin
          @vtepd.events.subscribe(kinds: params['kinds'] && Array(params['kinds']), since: params['since'])
        rescue ArgumentError, TypeError => e
          write(sock, id: req['id'], error: e.message)
          return true
        end
        write(sock, id: req['id'], result: { seq: @vtepd.events.seq, replayed: sub.replayed, kinds: sub.kinds&.map(&:to_s) })
        quiet_since = @clock.call
        loop do
          if sock.wait_readable(0)
            r = read_request(sock)
            return false if r.nil?
            next if r == :skip

            if r['method'] == 'events.unsubscribe'
              @vtepd.events.unsubscribe(sub)
              sub = nil
              write(sock, id: r['id'], result: { unsubscribed: true })
              return true
            end
            write(sock, id: r['id'], error: "#{r['method']} refused: this connection is streaming events; " \
                                            'send events.unsubscribe, or use another connection')
          end
          events = sub.take(0.2)
          events.each { |e| write(sock, event: e.to_h) }
          quiet_since = @clock.call unless events.empty?
          next unless @clock.call - quiet_since >= @keepalive

          write(sock, keepalive: Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ'), seq: @vtepd.events.seq)
          quiet_since = @clock.call
        end
      ensure
        @vtepd.events.unsubscribe(sub) if sub
      end

      def write(sock, obj)
        sock.write("#{JSON.generate(obj)}\n")
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
