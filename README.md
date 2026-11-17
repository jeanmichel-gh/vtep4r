# vtep4r

VXLAN in Ruby (RFC 7348): a library to build, parse and send VXLAN,
valid or not, for routing labs and protocol tests. A VTEP, `vtep4rd`,
is built on it; an injector, `vtep4r-sim`, is next.
`docs/design/vtep4r.md` is the plan.

## vtep4rd

```sh
vtep4rd -f vtep4rd.yml                       # needs CAP_NET_RAW for its ports
vtep4r-cli show.vnis                         # each VNI, its ports and flood list
vtep4r-cli show.macs vni=100                 # a VNI's MAC table
vtep4r-cli show.counters                     # frames per port and peer, drops
vtep4r-cli mac.add vni=100 mac=02:00:00:00:01:09 vtep=10.255.0.13
```

```yaml
local: 10.255.0.11
vnis:
  - vni: 100
    ports: [eth2]
    flood: [10.255.0.12]
```

## The library

The header and the packet:

```ruby
require 'vtep4r'

h = VXLAN::Header.new(100)
h.to_shex                       #=> "0800000000006400"
h.to_s                          #=> "VXLAN, flags [I] (0x08), vni 100"

# Any flags and reserved bits, for testing a receiver.
VXLAN::Header.new(vni: 100, flags: 0x0c, reserved2: 1).to_shex
#=> "0c00000000006401"

pk = VXLAN::Packet.new(octets)  # a UDP payload from port 4789
pk.header.vni                   #=> 100
pk.frame                        #=> a Datalink::Frame, or nil
pk.to_hash                      #=> { header: { vni: 100 }, inner: "ffff..." }
VXLAN::Packet.new(pk.to_hash).encode == octets   #=> true

# What a received packet got wrong, with the RFC section.
pk.errors                       #=> [] or [#<Finding name=:no_i_flag ...>]
VXLAN::Validation.decide(pk, policy: :rfc)       #=> :deliver or :drop

# Crafted packets, and what RFC 7348 expects of a receiver.
VXLAN::Fault.names              #=> [:no_i_flag, :r_bit_set, ...]
VXLAN::Fault.wire(:r_bit_set, vni: 100)          # octets to send
```

Tests: `ruby test/run_unit.rb` under Bundler, or with `DATALINK_LIB`
set to a datalink-socket checkout's `lib/`. CLAUDE.md has the details.

GPL 3 or later, for now. See LICENSE.txt.
