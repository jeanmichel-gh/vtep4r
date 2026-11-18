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
require 'fileutils'
require 'rbconfig'

# The lab tier's network: three namespaces, the kernel's own VXLAN in one,
# vtep4rd and vtep4r-sim, the real programs, in another, and a host in
# the third. Shared by test/lab/kernel_test.rb and fault_matrix_test.rb.
# As bgp4r's fwd_lab_netns_test, a class using it omits itself without
# root or ip, and fails instead when VTEP4R_LAB_REQUIRED is set.
#
#   vt4A: the kernel's vxlan100, 10.9.0.1, MAC 02:00:00:00:01:01, 172.16.100.1
#   vt4B: vtep4rd and vtep4r-sim, 10.9.0.2; host port p0
#   vt4H: a host on p0's peer, MAC 02:00:00:00:01:02, 172.16.100.2
#
# A new namespace has lo down; it is brought up, since vtep4r-sim's API
# binds 127.0.0.1.
module LabNet
  ROOT = File.expand_path('../..', __dir__)
  RUBY = RbConfig.ruby
  SOCK = "/tmp/vt4lab-#{Process.pid}.sock".freeze
  API = 18_090
  NS = %w[vt4A vt4B vt4H].freeze

  def self.included(base)
    base.extend(ClassMethods)
  end

  def self.env
    ENV['DATALINK_LIB'] ? { 'DATALINK_LIB' => ENV['DATALINK_LIB'] } : {}
  end

  module ClassMethods
    def sh(*argv, out: File::NULL)
      system(*argv, out: out, err: File::NULL)
    end

    def usable?
      return @usable unless @usable.nil?

      @usable = Process.uid.zero? && sh('ip', 'netns', 'add', 'vt4probe') && sh('ip', 'netns', 'del', 'vt4probe')
    end

    def startup
      return unless usable?

      NS.each { |n| sh('ip', 'netns', 'del', n) }
      NS.each { |n| sh('ip', 'netns', 'add', n) }
      ip = ->(*a) { sh('ip', *a) or raise "ip #{a.join(' ')} failed" }
      ip.('link', 'add', 'u0', 'netns', 'vt4A', 'type', 'veth', 'peer', 'name', 'u1', 'netns', 'vt4B')
      ip.('link', 'add', 'p0', 'netns', 'vt4B', 'type', 'veth', 'peer', 'name', 'p1', 'netns', 'vt4H')
      ip.('-n', 'vt4A', 'addr', 'add', '10.9.0.1/24', 'dev', 'u0')
      ip.('-n', 'vt4B', 'addr', 'add', '10.9.0.2/24', 'dev', 'u1')
      { 'vt4A' => %w[u0 lo], 'vt4B' => %w[u1 p0 lo], 'vt4H' => %w[p1 lo] }.each do |n, links|
        links.each { |l| ip.('-n', n, 'link', 'set', l, 'up') }
      end
      ip.('-n', 'vt4H', 'link', 'set', 'p1', 'address', '02:00:00:00:01:02')
      ip.('-n', 'vt4H', 'addr', 'add', '172.16.100.2/24', 'dev', 'p1')
      ip.('-n', 'vt4A', 'link', 'add', 'vxlan100', 'type', 'vxlan', 'id', '100', 'local', '10.9.0.1',
          'remote', '10.9.0.2', 'dstport', '4789')
      ip.('-n', 'vt4A', 'link', 'set', 'vxlan100', 'address', '02:00:00:00:01:01')
      ip.('-n', 'vt4A', 'addr', 'add', '172.16.100.1/24', 'dev', 'vxlan100')
      ip.('-n', 'vt4A', 'link', 'set', 'vxlan100', 'up')

      @dir = File.join(ENV['TMPDIR'] || '/tmp', "vt4lab-#{Process.pid}")
      FileUtils.mkdir_p(@dir)
      File.write(File.join(@dir, 'vtep4rd.yml'),
                 "local: 10.9.0.2\nsocket: #{SOCK}\nvnis:\n  - vni: 100\n    ports: [p0]\n    flood: [10.9.0.1]\n")
      File.write(File.join(@dir, 'sim.yml'), "local: 10.9.0.2\napi: 127.0.0.1:#{API}\n")
      @pids = %w[vtep4rd vtep4r-sim].map do |prog|
        file = File.join(@dir, prog == 'vtep4rd' ? 'vtep4rd.yml' : 'sim.yml')
        log = File.join(@dir, "#{prog}.log")
        spawn(LabNet.env, 'ip', 'netns', 'exec', 'vt4B', RUBY, File.join(ROOT, 'exe', prog), '-f', file, out: log, err: log)
      end
      50.times { File.socket?(SOCK) ? break : sleep(0.1) }
      sleep 0.5
    end

    def shutdown
      return unless usable?

      Array(@pids).each { |p| Process.kill('TERM', p) rescue nil }
      Array(@pids).each { |p| Process.wait(p) rescue nil }
      NS.each { |n| sh('ip', 'netns', 'del', n) }
      FileUtils.rm_rf(@dir) if @dir
    end
  end

  def setup
    return if self.class.usable?

    flunk('VTEP4R_LAB_REQUIRED is set, and the lab tier needs root and ip netns') if ENV['VTEP4R_LAB_REQUIRED']
    omit('the lab tier needs root and ip netns')
  end

  def cli(*args)
    JSON.parse(IO.popen(LabNet.env, [RUBY, File.join(ROOT, 'exe/vtep4r-cli'), '-s', SOCK, *args], &:read))
  end

  def in_ns(ns, *argv)
    IO.popen(['ip', 'netns', 'exec', ns, *argv], err: %i[child out], &:read)
  end

  def sim_post(path, body)
    script = "r = Net::HTTP.post(URI(\"http://127.0.0.1:#{API}\#{ARGV[0]}\"), ARGV[1], \"X-VTEP4R\" => \"routescope\"); print r.body"
    JSON.parse(in_ns('vt4B', RUBY, '-rnet/http', '-e', script, path, JSON.generate(body)))
  end

  def kernel_fdb(prefix)
    in_ns('vt4A', 'bridge', 'fdb', 'show', 'dev', 'vxlan100').lines.grep(/\A#{prefix}/)
  end

  # vxlan100's receive counters: packets, bytes, errors, dropped, ...
  def kernel_rx
    JSON.parse(in_ns('vt4A', 'ip', '-j', '-s', 'link', 'show', 'vxlan100'))[0]['stats64']['rx']
  end

  def wait_for(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until (v = yield)
      flunk('not within the deadline') if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    v
  end
end
