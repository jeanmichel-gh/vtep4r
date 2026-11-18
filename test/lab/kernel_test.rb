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

root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)
$LOAD_PATH.unshift(ENV['DATALINK_LIB']) if ENV['DATALINK_LIB']

require 'test/unit'
require 'json'
require 'fileutils'
require 'rbconfig'

# The lab tier: vtep4rd and vtep4r-sim, the real programs, against the
# kernel's own VXLAN, in three network namespaces. As bgp4r's
# fwd_lab_netns_test, it omits itself without root or ip.
#
#   vt4A: the kernel's vxlan100, 10.9.0.1, MAC 02:00:00:00:01:01, 172.16.100.1
#   vt4B: vtep4rd and vtep4r-sim, 10.9.0.2; host port p0
#   vt4H: a host on p0's peer, MAC 02:00:00:00:01:02, 172.16.100.2
#
#   sudo DATALINK_LIB=~/datalink-socket/lib ruby -I. test/lab/kernel_test.rb
class Kernel_Test < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)
  RUBY = RbConfig.ruby
  SOCK = "/tmp/vt4lab-#{Process.pid}.sock".freeze
  API = 18_090
  NS = %w[vt4A vt4B vt4H].freeze

  class << self
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
      env = ENV['DATALINK_LIB'] ? { 'DATALINK_LIB' => ENV['DATALINK_LIB'] } : {}
      @pids = [
        spawn(env, 'ip', 'netns', 'exec', 'vt4B', RUBY, File.join(ROOT, 'exe/vtep4rd'), '-f', File.join(@dir, 'vtep4rd.yml'),
              out: File.join(@dir, 'vtep4rd.log'), err: File.join(@dir, 'vtep4rd.log')),
        spawn(env, 'ip', 'netns', 'exec', 'vt4B', RUBY, File.join(ROOT, 'exe/vtep4r-sim'), '-f', File.join(@dir, 'sim.yml'),
              out: File.join(@dir, 'sim.log'), err: File.join(@dir, 'sim.log'))
      ]
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

    attr_reader :dir
  end

  # Omitted without root, except where VTEP4R_LAB_REQUIRED is set, as CI
  # sets it: there a lab tier that cannot run fails rather than passing
  # with nothing tested.
  def setup
    return if self.class.usable?

    flunk('VTEP4R_LAB_REQUIRED is set, and the lab tier needs root and ip netns') if ENV['VTEP4R_LAB_REQUIRED']
    omit('the lab tier needs root and ip netns')
  end

  def cli(*args)
    env = ENV['DATALINK_LIB'] ? { 'DATALINK_LIB' => ENV['DATALINK_LIB'] } : {}
    JSON.parse(IO.popen(env, [RUBY, File.join(ROOT, 'exe/vtep4r-cli'), '-s', SOCK, *args], &:read))
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

  def wait_for(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until (v = yield)
      flunk('not within the deadline') if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    v
  end

  # Both directions: the kernel pings the host behind vtep4rd, and the
  # host pings the kernel's address.
  def test_pings_cross_both_ways
    assert_match(/3 received/, in_ns('vt4A', 'ping', '-c', '3', '-W', '2', '172.16.100.2'))
    assert_match(/2 received/, in_ns('vt4H', 'ping', '-c', '2', '-W', '2', '172.16.100.1'))
  end

  # The host must broadcast an ARP request, which only vtep4rd's flood to
  # its flood list carries. Without the flush the kernel's own ARP request
  # has already taught the host, and the flood is never needed: a test that
  # missed a broken flood that way.
  def test_a_broadcast_from_the_host_is_flooded_into_the_tunnel
    in_ns('vt4H', 'ip', 'neigh', 'flush', 'all')
    in_ns('vt4A', 'ip', 'neigh', 'flush', 'all')
    assert_match(/2 received/, in_ns('vt4H', 'ping', '-c', '2', '-W', '2', '172.16.100.1'))
  end

  # Each side learns the other's MAC behind the other's address.
  def test_each_side_learns_the_other
    in_ns('vt4A', 'ping', '-c', '1', '-W', '2', '172.16.100.2')
    macs = cli('show.macs', 'vni=100').to_h { |m| [m['mac'], [m['type'], m['port'] || m['vtep']]] }
    assert_equal ['remote', '10.9.0.1'], macs['02:00:00:00:01:01']
    assert_equal ['local', 'p0'], macs['02:00:00:00:01:02']
    assert_match(/dst 10.9.0.2/, kernel_fdb('02:00:00:00:01:02').join)
    assert_equal({}, cli('show.counters')['drops'])
  end

  # vtep4r-sim, beside vtep4rd in its namespace, into the kernel: the
  # generated MACs are learned behind the sim's address.
  def test_the_sim_fills_the_kernels_table
    r = sim_post('/api/generate', 'to' => '10.9.0.1', 'per_second' => 500,
                                  'spec' => { 'vni' => 100, 'macs' => 50, 'src' => '02:00:00:aa:00:00' })
    assert_equal 50, r['total']
    wait_for { kernel_fdb('02:00:00:aa:00').size == 50 }
    assert kernel_fdb('02:00:00:aa:00').all? { |l| l.include?('dst 10.9.0.2') }
  end

  # The sim's own address on the same namespace as vtep4rd's port 4789:
  # it never binds it, so both run.
  def test_the_sim_runs_beside_vtep4rd
    status = JSON.parse(in_ns('vt4B', RUBY, '-rnet/http', '-e', "print Net::HTTP.get(URI('http://127.0.0.1:#{API}/api/status'))"))
    assert_equal '10.9.0.2', status['local']
    assert_equal '10.9.0.2', cli('show.status')['local']
  end
end
