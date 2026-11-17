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
    class Api
      MAX_LINE = 1 << 20
      MAX_CLIENTS = 32
      IDLE = 900
      VERSION = 1   # of this API, raised when a method changes incompatibly

      # name => ->(api, params) { result }
      METHODS = {
        'api.info' => ->(_a, _p) { Api.info },
        'show.status' => ->(a, _p) { a.status },
        'show.vnis' => ->(a, _p) { a.on { |sw, _now| sw.bridges.map { |bd| a.vni_row(sw, bd) } } },
        'show.macs' => ->(a, p) { a.macs(p) },
        'show.counters' => ->(a, _p) { a.counters },
        'vni.flood.add' => ->(a, p) { a.flood(p, :add) },
        'vni.flood.del' => ->(a, p) { a.flood(p, :del) },
        'mac.add' => ->(a, p) { a.mac_add(p) },
        'mac.del' => ->(a, p) { a.mac_del(p) },
        'mac.flush' => ->(a, p) { a.mac_flush(p) }
      }.freeze

      def self.names
        METHODS.keys.sort
      end

      def self.info
        { version: VXLAN::VERSION, api: VERSION, methods: names }
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

      def initialize(vtepd, path:, logger: nil, clock: nil)
        @vtepd = vtepd
        @path = path
        @logger = logger
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
        fn = METHODS[name]
        return { id: id, error: "unknown method #{name.inspect}; this vtep4rd answers #{Api.names.join(', ')}" } unless fn

        params = req['params'].is_a?(Hash) ? req['params'] : {}
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
            vnis: sw.bridges.map(&:vni), uptime: (now - @started).round(1) }
        end
      end

      # One row per VNI, in routescope's evpn_vnis columns where they
      # apply: the flood list is head-end replication, as FRR prints it.
      def vni_row(sw, bd)
        { vni: bd.vni, type: 'L2', vtep_ip: sw.local, ports: bd.ports, mode: bd.mode,
          remote_vteps: bd.flood, flood: 'HER', macs: bd.macs.size, ageing: bd.macs.ageing }
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
        end
      end

      def flood(p, op)
        vtep = p.fetch('vtep').to_s
        on do |sw, _now|
          bd = bridge(sw, p)
          { vni: bd.vni, vtep: vtep, changed: op == :add ? bd.flood_add(vtep) : bd.flood_del(vtep), flood: bd.flood }
        end
      end

      def mac_add(p)
        mac = Datalink::MAC.new(p.fetch('mac'))
        loc = Vtep::Location.vtep(p.fetch('vtep').to_s)
        seq = Integer(p.fetch('seq', 0))
        on do |sw, _now|
          bd = bridge(sw, p)
          bd.macs.add(mac, loc, seq: seq)
          { vni: bd.vni, mac: mac.to_s, vtep: loc.name, seq: seq }
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
        while sock.wait_readable(IDLE) && (line = sock.gets(MAX_LINE))
          unless line.end_with?("\n") || line.bytesize < MAX_LINE
            write(sock, error: "request longer than #{MAX_LINE} octets")
            return
          end
          req = begin
            JSON.parse(line)
          rescue JSON::ParserError => e
            write(sock, error: "bad JSON: #{e.message[0, 120]}")
            next
          end
          unless req.is_a?(Hash)
            write(sock, error: 'a request is a JSON object')
            next
          end
          write(sock, handle(req))
        end
      rescue IOError, SystemCallError
        nil
      end

      def write(sock, obj)
        sock.write("#{JSON.generate(obj)}\n")
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
