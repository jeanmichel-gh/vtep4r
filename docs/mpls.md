# EVPN over MPLS: the codec

vtep4r carries Ethernet frames over MPLS for EVPN, as bgp4r's
`docs/design/evpn-mpls.md` asks (approved 2026-11-27). Built: the codec
in `vxlan/mpls/` (step 0a), MPLS bridge domains with their forwarding
and API (step 0b), and the edge in vtep4rd that reads and sends these
packets on the core's devices (step 0c).

## What is on the wire

After an Ethernet header of EtherType 0x8847:

```
| label | ... | label, S set | control word | the customer's frame |
```

- **A label stack entry** is four octets: a 20-bit label, 3 bits
  "reserved for experimental use", the S bit and a TTL (RFC 3032
  section 2.1). tcpdump prints the 3 bits as `tc`.
- **The bottom entry** has the S bit set. "The network layer packet
  immediately follows" it (the same section).
- **The control word** is four octets whose first four bits are zero
  (RFC 4385 section 3). EVPN sends it "with the value 0" (RFC 7432
  section 18). Nothing on the wire says it is there; both ends agree.
- **An explicit null**, label 0 (IPv4) or 2 (IPv6), may sit above the
  EVPN label when the core does not pop the last transport label. RFC
  4182 section 2 made it legal anywhere in the stack: it is popped, and
  the label beneath it rises.

## The classes

| Class | What it is |
| --- | --- |
| `VXLAN::Mpls::Label` | one label stack entry |
| `VXLAN::Mpls::ControlWord` | the control word, in RFC 4385's preferred format |
| `VXLAN::Mpls::Packet` | the stack, the control word and the frame |
| `VXLAN::Mpls::Validation` | the receive-side rules |
| `VXLAN::Mpls::Fault` | the crafted packets |

Each is built four ways, as `Header` and `Packet` are: from field
values, a hash, wire bytes, or another instance. `encode`, `to_hash`
and `to_s` work as theirs do. Building is never validated.

`Packet.new(octets)` expects a control word after the bottom label;
`Packet.new(octets, control_word: false)` does not. What cannot be read
is kept: a stack with no S bit keeps the octets left as `tail`, and so
does a control word cut short.

## What a receiver checks

| Finding | Action | Why |
| --- | --- | --- |
| `no_bottom` | drop | no entry has the S bit set (RFC 3032 section 2.1) |
| `no_control_word` | drop | fewer than four octets after the bottom label (RFC 7432 section 18) |
| `control_word_nibble` | drop | its first four bits are not zero (RFC 4385 section 3) |
| `control_word_set` | ignore | other bits set; RFC 7432 section 18 sends zero and says nothing of a receiver, so the frame is passed on |
| `short` | drop | an inner frame shorter than an Ethernet header |

A label the receiver did not give out "MUST be discarded" (RFC 3031
section 3.18). Which labels are its own is the VTEP's to know, so that
check belongs to the edge, as an unknown VNI does for VXLAN.

**A stack with no S bit reads into the payload.** A receiver keeps
taking four octets as a label until one has the S bit. The fault
`no_bottom`, sent, is read as three labels, the third taken from the
ARP frame, and then fails as a control word. It is still dropped.

## The faults

`VXLAN::Mpls::Fault::CATALOG` builds each for a receiver whose EVPN
label is given: `Fault.wire(:no_bottom, label: 25001)`. Three entries
are the VTEP's to judge: `unknown_label` (drop), and
`ipv4_explicit_null` and `ipv6_explicit_null` (delivered, the null
popped).

## MPLS bridge domains (step 0b)

A bridge domain has `encap: vxlan`, the default, or `encap: mpls`:

```yaml
vnis:
  - vni: 200               # the local bridge domain's number; no VNI is on the wire
    ports: [eth3]
    mode: evpn
    encap: mpls
    labels: { unicast: 25000, bum: 25001 }   # or set later by vni.labels
```

- **Always `evpn` mode.** A packet over MPLS does not say which PE sent
  it, so a remote MAC cannot be learned from traffic. `encap: mpls` with
  `mode: learn` is refused.
- **Two labels of its own**, unicast and BUM, which bgp4rd gives out
  and advertises. Each is 16 to 2^20 - 1 (RFC 3032 section 2.1 reserves
  0 to 15), the two differ, and no other VNI has either.
- **The remote PE's labels.** `mac.add` takes `label`, Label1 of the
  remote PE's type 2 route; `vni.flood.add` takes `label`, the PMSI
  label of its type 3 route. A VXLAN VNI refuses both.

### What the Forwarder does

| From | What | Action |
| --- | --- | --- |
| a port | a frame to a remote MAC | `Push`: the PE, its label, and the packet (that label, a zero control word, the frame) |
| a port | a broadcast, multicast or unknown frame | the other ports, and a `Push` to each PE in the flood list under its BUM label |
| the core | our unicast label, a known local MAC | that port |
| the core | our BUM label, or a MAC not known here | every port (RFC 7432 section 12.1 for BUM) |
| the core | a remote MAC under our label | dropped, `split_horizon` |
| the core | a label not ours on top (a transport label not popped) | dropped, `unknown_label` (RFC 3031 section 3.18) |
| the core | our label not at the bottom | dropped, `not_bottom` |

An explicit null on top is popped first (RFC 4182 section 2). Nothing
is learned from the core. The MTU is the edge's to check, since only
it knows how many transport labels go on top.

A vtep4rd with no `core:` has no MPLS edge: a `Push` is counted and
published as a drop, `no_mpls_edge`.

### The API

| Method | What |
| --- | --- |
| `vni.add` | takes `encap` and `labels`, as the file |
| `vni.labels` | `vni`, `unicast`, `bum`: sets them; `changed` says if they moved |
| `show.labels` | each label given out: `label`, `vni`, `kind` |
| `show.vnis` | adds `encap`; an MPLS VNI also `labels` and `flood_labels` |
| `show.macs` | a remote MAC over MPLS adds its `label` |

A reload sets the file's labels in place. A file with no labels leaves
what `vni.labels` set. A change of `encap` replaces the VNI, as a change
of mode does.

## The edge (step 0c)

```yaml
local: 10.255.0.1
core: [eth1]               # the devices toward the core
vnis:
  - vni: 100
    ports: [eth2]
    mode: evpn
    encap: mpls
    labels: { unicast: 25000, bum: 25001 }
```

- **Receive.** A packet socket per `core:` device asks the kernel for
  EtherType 0x8847 (RFC 3032 section 5) and skips the host's own
  frames. The PE's kernel needs no MPLS input: it drops what it has no
  label route for, and vtep4rd still gets its copy (measured below).
- **The transport.** Each remote PE is resolved as bgp4r's L3VPN PE
  resolves one: `ip -j route get PE` for the labels, gateway and device,
  then `ip -j link show dev DEV` for the device's MAC and MTU and
  `ip -j neigh show GW dev DEV` for the gateway's MAC. It runs on a
  thread of its own every second, and at once for a PE a frame needs
  first; that frame is dropped, `no_transport`. A PE with no route or no
  ARP entry yet is an error, read again each second.
- **Send.** The gateway's MAC, the device's MAC, 0x8847, the transport's
  labels, then the EVPN label, the control word and the frame, out of
  the hop's device. A frame whose MPLS payload is larger than that
  device's MTU is dropped, `too_big`. A device not in `core:` is opened
  and read when a hop first uses it.
- `core:` needs a restart to change, as `local:` does.

| Method | What |
| --- | --- |
| `show.transport` | each remote PE: `pe`, `labels` (top first), `gateway`, `dev`, `mac`, `src_mac`, `mtu`, `error`, and `since`, when it last changed |
| `show.status` | adds `core`, the devices read |
| `show.counters` | adds `core`, frames per core device |

### Measured, Linux 7.0, 2026-11-27

`test/lab/mpls_test.rb`: five namespaces, two hosts, pe1 and pe2 running
vtep4rd, and P switching labels in the kernel, popping each PE's node
SID (PHP). It passed 5 of 5 on ospflab.

- Pings cross both ways.
- On P's link from pe1: pe2's node SID 16002, pe2's label with the S
  bit, four zero octets of control word, and h1's frame.
- A frame to `46:00:00:00:01:02` crosses intact, as RFC 7432 section 18
  fears it might not on a core that looks into it.
- P swapping the node SID for an IPv4 explicit null instead of popping
  it: pe2 still takes the frame (RFC 4182 section 2).
- A new label on pe1's route to pe2 is in `show.transport` 0.17 to 0.42
  s after `ip route change`, in 5 runs, within the one-second period.
- pe2's kernel takes no MPLS input (`net.mpls.conf.b0.input` is 0), and
  pe2's vtep4rd counts the frames on `b0`.

## FRR 10.7.1 is no data plane peer here

The spec says FRR is no EVPN-over-MPLS peer and asks that it be
checked, not assumed. Checked on 2026-11-27: FRR 10.7.1 in a privileged
container with zebra and a VXLAN device for VNI 100, `advertise-all-vni`,
and a bgp4r peer sending a type 3 route (ingress replication, PMSI label
26001) and a type 2 route (Label1 26000), RT 65000:100, as an MPLS PE
would.

- **With no Encapsulation community**, FRR imports both into its VXLAN
  VNI. `show bgp l2vpn evpn route` reads Label1 as "VNI 416001" and the
  PMSI label as 416016: the 24-bit field, label and S bit together. Its
  kernel gets `02:00:00:00:02:02 dst 10.77.0.3` and a flood entry
  `00:00:00:00:00:00 dst 10.77.0.3` on the VXLAN device, and no MPLS
  route. RFC 8365 section 5.1.3 allows this: with no Encapsulation
  community, "either MPLS encapsulation or a statically configured
  encapsulation is assumed", and FRR assumes its VXLAN.
- **With the Encapsulation community, tunnel type 10 (MPLS)**, the same:
  FRR imports the routes into the VXLAN VNI and programs the same VXLAN
  entries.

So FRR would send VXLAN to an MPLS PE. An FRR VXLAN leaf must not share
a route target with an MPLS MAC-VRF; no community keeps it out.

The check's files, run from one directory:

`daemons`:

```
bgpd=yes
zebra=yes
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
```

`frr.conf`:

```
frr defaults traditional
hostname frrchk
router bgp 65000
 bgp router-id 10.77.0.2
 no bgp default ipv4-unicast
 no bgp ebgp-requires-policy
 neighbor 10.77.0.3 remote-as 65000
 address-family l2vpn evpn
  neighbor 10.77.0.3 activate
  advertise-all-vni
 exit-address-family
```

`peer.rb`, run in `bgp4r-lab:latest`:

```ruby
# An EVPN-over-MPLS PE as bgp4rd will be: type 3 with an ingress
# replication PMSI and MPLS label 26001, type 2 for 02:00:00:00:02:02 with
# MPLS Label1 26000; RT 65000:100; no Encapsulation community (RFC 8365
# section 5.1.3: MPLS is the default).
$stdout.sync = true
require 'bgp4r'
require 'bgp/gen/evpn_routes'
require 'bgp/gen/sender'
n = BGP::Neighbor.new(:my_as => 65000, :id => '10.77.0.3', :remote_addr => '10.77.0.2', :local_addr => '10.77.0.3', :holdtime => 90)
n.capability :as4_byte
n.capability :mbgp_l2vpn_evpn
n.start(:timeout => 20)
sleep 0.1 until n.is_established?
puts "established"
sender = BGP::Gen::Sender.read('as' => 65000, 'next_hop' => '10.77.0.3')
base = { 'attributes' => {}, 'family' => 'evpn', 'rd' => '10.77.0.3:100', 'route_target' => '65000:100', 'count' => 1 }
ups = BGP::Gen::Evpn_routes.new(base.merge('route_type' => 3, 'start' => '10.77.0.3', 'pmsi_label' => 26001), sender).updates +
      BGP::Gen::Evpn_routes.new(base.merge('route_type' => 2, 'start' => '02:00:00:00:02:02', 'label' => 26000), sender).updates
ups.each { |u| puts u.to_s.lines.grep(/Label|label|PMSI|Pmsi|Extended|Encap|MAC|Mac/i).first(8).join; n.send_message(u) }
sleep 25
puts "done"
```

The commands:

```sh
docker network create --subnet 10.77.0.0/24 frrchk
docker run -d --name frrchk-frr --privileged --network frrchk --ip 10.77.0.2 \
  -v $PWD/daemons:/etc/frr/daemons:ro -v $PWD/frr.conf:/etc/frr/frr.conf:ro quay.io/frrouting/frr:10.7.1
docker exec frrchk-frr sh -c 'ip link add br100 type bridge && ip link add vxlan100 type vxlan id 100 local 10.77.0.2 dstport 4789 nolearning && ip link set vxlan100 master br100 && ip link set br100 up && ip link set vxlan100 up'
docker run --rm --name frrchk-peer --network frrchk --ip 10.77.0.3 -v $PWD/peer.rb:/peer.rb:ro --entrypoint ruby bgp4r-lab:latest -I/app /peer.rb
docker exec frrchk-frr vtysh -c 'show bgp l2vpn evpn route detail' -c 'show evpn mac vni 100'
docker exec frrchk-frr bridge fdb show dev vxlan100
docker rm -f frrchk-frr; docker network rm frrchk
```

For tunnel type 10, `peer.rb`'s `'attributes' => {}` becomes
`'attributes' => { 'extended_communities' => ['encapsulation:10'] }`.
