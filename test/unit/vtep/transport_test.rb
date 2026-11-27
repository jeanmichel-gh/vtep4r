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

require 'test/unit'
require 'vxlan/vtep/transport'

# The resolver on what ip answered on Linux 7.0, iproute2 6.19, measured
# 2026-11-27 in two network namespaces: a route with one label, with two,
# with none (PHP), and none at all; a neighbor and none; a link.
class Transport_Test < Test::Unit::TestCase
  include VXLAN::Vtep

  ROUTE1 = '[{"dst":"10.255.0.2","encap":{"encap_type":"mpls","dst":"16002"},"gateway":"10.0.1.2","dev":"ap",' \
           '"prefsrc":"10.0.1.1","flags":[],"uid":0,"cache":[]}]'
  ROUTE2 = '[{"dst":"10.255.0.3","encap":{"encap_type":"mpls","dst":"16003/24001"},"gateway":"10.0.1.2","dev":"ap",' \
           '"prefsrc":"10.0.1.1","flags":[],"uid":0,"cache":[]}]'
  ROUTE0 = '[{"dst":"10.255.0.4","gateway":"10.0.1.2","dev":"ap","prefsrc":"10.0.1.1","flags":[],"uid":0,"cache":[]}]'
  NEIGH = '[{"dst":"10.0.1.2","lladdr":"d2:21:81:85:cf:49","state":["REACHABLE"]}]'
  LINK = '[{"ifindex":2,"link_index":2,"ifname":"ap","flags":["BROADCAST","MULTICAST","UP","LOWER_UP"],"mtu":1500,' \
         '"qdisc":"noqueue","operstate":"UP","linkmode":"DEFAULT","group":"default","txqlen":1000,"link_type":"ether",' \
         '"address":"82:b6:be:3d:c2:76","broadcast":"ff:ff:ff:ff:ff:ff","link_netnsid":0}]'

  # +answers+: the argv's words after "-j" joined => [ok, output].
  def transport(answers)
    @asked = []
    Transport.new(runner: lambda { |argv|
      @asked << argv
      answers.fetch(argv.drop(2).join(' '), [true, '[]'])
    })
  end

  def test_one_label
    hop = transport('route get 10.255.0.2' => [true, ROUTE1], 'link show dev ap' => [true, LINK],
                    'neigh show 10.0.1.2 dev ap' => [true, NEIGH]).resolve('10.255.0.2')
    assert hop.ok?
    assert_equal ['10.255.0.2', [16_002], '10.0.1.2', 'ap', 'd2:21:81:85:cf:49', '82:b6:be:3d:c2:76', 1500],
                 hop.to_h.values_at(:pe, :labels, :gateway, :dev, :mac, :src_mac, :mtu)
    assert_equal [%w[ip -j route get 10.255.0.2], %w[ip -j link show dev ap], %w[ip -j neigh show 10.0.1.2 dev ap]], @asked
  end

  def test_two_labels_top_first
    hop = transport('route get 10.255.0.3' => [true, ROUTE2], 'link show dev ap' => [true, LINK],
                    'neigh show 10.0.1.2 dev ap' => [true, NEIGH]).resolve('10.255.0.3')
    assert_equal [16_003, 24_001], hop.labels
  end

  def test_a_pe_reached_by_php_has_no_label
    hop = transport('route get 10.255.0.4' => [true, ROUTE0], 'link show dev ap' => [true, LINK],
                    'neigh show 10.0.1.2 dev ap' => [true, NEIGH]).resolve('10.255.0.4')
    assert hop.ok?
    assert_equal [], hop.labels
  end

  def test_a_pe_on_a_connected_subnet_is_its_own_gateway
    route = '[{"dst":"10.0.1.2","dev":"ap","prefsrc":"10.0.1.1","flags":[],"uid":0,"cache":[]}]'
    hop = transport('route get 10.0.1.2' => [true, route], 'link show dev ap' => [true, LINK],
                    'neigh show 10.0.1.2 dev ap' => [true, NEIGH]).resolve('10.0.1.2')
    assert_equal ['10.0.1.2', 'd2:21:81:85:cf:49'], [hop.gateway, hop.mac]
  end

  def test_no_route
    hop = transport('route get 10.255.9.9' => [false, "RTNETLINK answers: Network is unreachable\n"]).resolve('10.255.9.9')
    refute hop.ok?
    assert_equal 'no route to 10.255.9.9: RTNETLINK answers: Network is unreachable', hop.error
  end

  def test_no_arp_entry_yet
    hop = transport('route get 10.255.0.2' => [true, ROUTE1], 'link show dev ap' => [true, LINK]).resolve('10.255.0.2')
    refute hop.ok?
    assert_equal 'no ARP entry for 10.0.1.2 on ap', hop.error
    assert_equal [16_002], hop.labels, 'what was found is kept, for show.transport'
  end

  def test_a_route_of_another_encapsulation
    route = '[{"dst":"10.255.0.2","encap":{"encap_type":"ip6"},"dev":"ap"}]'
    assert_match(/is ip6, not mpls/, transport('route get 10.255.0.2' => [true, route]).resolve('10.255.0.2').error)
  end

  def test_output_that_is_not_json
    assert_match(/ip route get 10.255.0.2/, transport('route get 10.255.0.2' => [true, 'oops']).resolve('10.255.0.2').error)
  end
end
