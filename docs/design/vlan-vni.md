# VLANs and QinQ over VXLAN

Status: draft, 2026-11-28, waiting for the owner's approval. No code.

This answers the open question in `docs/design/vtep4r.md`: "VLAN tags.
802.1Q on a port, mapping a VLAN to a VNI." The kernel's VLAN devices
do the tagging, and vtep4rd opens them as ports (the owner's
direction, 2026-11-28). datalink-socket injects frames, and later reads
tags where a VNI keeps them.

## What RFC 7348 asks

Read in `specs/rfc7348.txt`.

- Section 6, for a gateway between VXLAN and VLANs: "incoming frames
  for the non-VXLAN interfaces are mapped to a specific VXLAN overlay
  network based on the VLAN ID in the frame. Unless configured
  explicitly to be passed on in the encapsulated VXLAN frame, this VLAN
  ID is removed before the frame is encapsulated for VXLAN."
- Section 6.1, for every VTEP: "Decapsulated VXLAN frames with the inner
  VLAN tag SHOULD be discarded unless configured otherwise. On the
  encapsulation side, a VTEP SHOULD NOT include an inner VLAN tag on
  tunnel packets unless configured otherwise. When a VLAN-tagged packet
  is a candidate for VXLAN tunneling, the encapsulating VTEP SHOULD
  strip the VLAN tag unless configured otherwise."

RFC 8365 section 5.1 names the two modes in EVPN's terms. A stripped
tag, one VID to one VNI, "maps to VLAN-Based Service in [RFC7432]". An
inner tag kept "can map to VLAN Bundle Service". Section 5.1.3 says
that for the VLAN-Based Service the Ethernet Tag of the EVPN routes
"MUST be set to zero". bgp4rd already sends 0, so EVPN needs nothing
for the first mode.

RFC 7348 does not say what to do with a frame whose VID maps to no
VNI. There is no overlay for it, so it is dropped. That is ordinary
802.1Q behaviour, from memory: 802.1Q is not in `specs/`.

## What exists

Measured on ospflab, 2026-11-28, kernel 7.0.0-43, Ruby 3.3.8, in two
network namespaces joined by a veth. "Read" is datalink-socket's Linux
backend unless said otherwise.

**A socket on a parent sees every VLAN, untagged.** Frames from VLAN
10, from VLAN 20 and untagged ones read alike on the parent, with
EtherType 0x0806 at offset 12 and no tag. It was the same with
`rx-vlan-offload` on and off:

```
len=42 type=0x806 head=ffffffffffff7a22fbd41dff0806000108000604
len=42 type=0x806 head=ffffffffffff7a22fbd41dff0806000108000604
len=42 type=0x806 head=ffffffffffff7a22fbd41dff0806000108000604
```

So today a vtep4rd port on a trunk would bridge every VLAN into one
VNI, and the tags would be lost. This was measured at the socket, not
through vtep4rd.

**A socket on a VLAN device sees its VLAN only, untagged.** With
sockets on `a0.10` and on `a0` at once, and ARP sent on VLAN 10, VLAN
20 and untagged, `a0.10` read only VLAN 10's frames, and `a0` read all
three:

```
a0.10: len=42 type=0x806 arp_target=192.0.2.9
a0: len=42 type=0x806 arp_target=192.0.2.9
a0: len=42 type=0x806 arp_target=198.51.100.9
a0: len=42 type=0x806 arp_target=203.0.113.9
```

**A frame written on a VLAN device leaves tagged.** An untagged frame
written on `a0.10` reached the far end as
`ethertype 802.1Q (0x8100) ... vlan 10, p 0`.

**A frame on a VLAN with no device is dropped by the kernel.** Five
frames on VID 999 and two on VID 100 were sent to a port with only a
VLAN 100 device. The socket on `a0.100` read the two. The parent's
counters, before and after:

```
before: a0 packets=0 dropped=0; a0.100 packets=0 dropped=0
after:  a0 packets=7 dropped=5; a0.100 packets=2 dropped=0
```

So vtep4rd never sees them. The parent's `rx dropped` counts them.

**A socket on an 802.1ad device sees its S-VLAN only, with the C-tag
taken out too.** Behind `a0.s1000` (802.1ad, S-VID 1000), the host sent
ARP on S 1000 / C 10 and on S 2000 / C 10. The socket read only S
1000's, and with no tag at all. tcpdump on the same device shows the
C-tag, and `PACKET_AUXDATA` has it:

```
len=42 type=0x806 arp_sender=172.16.10.1
len=42 inline_type=0x080600010800 aux(lvl=263,type=8) tpid=0x8100 vid=10 pcp=0 dei=0
08:47:51.742741 5e:8e:d7:bb:d5:fb > ff:ff:ff:ff:ff:ff, ethertype 802.1Q (0x8100), length 46: vlan 10, p 0, ethertype ARP (0x0806), Request who-has 172.16.10.9 tell 172.16.10.1, length 28
```

Without the auxdata, then, the C-VLANs of one S-VLAN read alike. A
device per C-VLAN on top (`a0.s1000.10`) separates them, as on the
host side.

**A C-tagged frame written on an 802.1ad device leaves double
tagged:** `ethertype 802.1Q-QinQ (0x88a8) ... vlan 1000, p 0, ethertype
802.1Q (0x8100), vlan 10`. The host's `b0.s1000.10` read it with both
tags gone.

**A tagged frame written on a parent leaves as written,** PCP and DEI
included, and QinQ too:

```
ethertype 802.1Q (0x8100), length 64: vlan 10, p 3, DEI, ethertype Unknown (0x88b5)
ethertype 802.1Q-QinQ (0x88a8), length 64: vlan 20, p 0, ethertype 802.1Q (0x8100), vlan 10, p 0, ethertype Unknown (0x88b5)
```

So injecting frames on any VLAN needs no change to datalink-socket.

**datalink-socket writes a tag as given, and reads it with the outer
tag taken out.** The owner asked (2026-11-28) for this to be checked
with datalink-socket at both ends. On a veth pair with no VLAN device,
datalink-socket wrote an 802.1Q frame (VID 100) and a QinQ frame (S
1000, C 10) on `gA0`, and read on both ends. Bytes 12 to 21 of each:

```
gB0 read 60 bytes, otherhost, bytes 12..21: 88b5 7171 7171 7171 7171
gB0 read 60 bytes, otherhost, bytes 12..21: 8100 000a 88b5 7171 7171
gA0 read 64 bytes, outgoing, bytes 12..21: 8100 0064 88b5 7171 7171
gA0 read 64 bytes, outgoing, bytes 12..21: 88a8 03e8 8100 000a 88b5
```

The frames left as written: the sender's own socket reads both tags,
and tcpdump on `gB0` shows `vlan 100` and `vlan 1000 ... vlan 10`. The
receiver's socket read them 4 bytes shorter, the outer tag gone and the
inner one kept. With `rx-vlan-offload` off on `gB0` the reads were the
same, byte for byte. So it is the kernel's receive path that moves the
outer tag into the packet's metadata, not the veth's offload, and
tcpdump shows it only because libpcap puts it back from the auxdata.

datalink-socket's ARP tools agree. `arp-scan -i gA0.100` found
`172.16.10.2` behind `gB0.100`: its requests left with `vlan 100`,
added by the VLAN device, and the replies were read untagged. Neither
tool builds or reads a tag itself, so they work on a VLAN device as
they are.

**The tag comes back in `PACKET_AUXDATA`, and Ruby cannot read it.**
With that socket option set, each read has a `tpacket_auxdata` with the
TCI and the TPID:

```
len=42 inline_type=0x806 aux(lvl=263,type=8) tpid=0x8100 vid=10 pcp=0 dei=0
len=42 inline_type=0x806 aux(lvl=263,type=8) tpid=0x8100 vid=20 pcp=0 dei=0
len=42 inline_type=0x806 aux(lvl=263,type=8) untagged
len=46 inline_type=0x8100 aux(lvl=263,type=8) tpid=0x88a8 vid=30 pcp=0 dei=0
```

On a parent, QinQ's outer tag is in the auxdata and the inner one
stays in the frame. Ruby's `Socket#recvmsg` fails on an `AF_PACKET`
socket with `Errno::EINVAL`. libc's `recvmsg` through Fiddle fails the
same way with `MSG_CMSG_CLOEXEC` and works with flags 0, so Ruby most
likely adds that flag. Fiddle is a default gem in Ruby 3.3.8 and
3.4.13. 4.0 was not measured.

**A VLAN device names its parent in sysfs.** `/sys/class/net/d0.100/`
has `lower_d0`, and `/sys/class/net/d0/` has `upper_d0.100`.

**Containers can make VLAN devices.** In two containers on a Docker
network, with `NET_ADMIN`, `eth0.100` pinged across, 2 of 2. Without
`NET_ADMIN`, `ip link add` answers `Operation not permitted`.
containerlab's nodes run privileged.

**datalink-socket's `Frame` loses the DEI bit.** `Frame.parse` reads
the PCP (`tci >> 13`) and the VID (`tci & 0x0fff`), and `encode` writes
only those two. Bit 12 is dropped both ways. It does not parse a 0x88a8
tag. This was read from `lib/datalink/frame.rb`, not run.

## The design

### A VLAN is a port

The kernel maps VLANs. vtep4rd's file names VLAN devices as ports, as
it names `eth2` today:

```yaml
local: 10.255.0.11
vnis:
  - vni: 100
    ports: [eth2.100]
    flood: [10.255.0.12]
  - vni: 200
    ports: [eth2.200]
    flood: [10.255.0.13]
```

The kernel strips the tag on the way in and puts it back on the way
out, as RFC 7348 section 6.1 asks. A frame on a VLAN with no device is
dropped by the kernel. The device's name carries the VLAN into
`show.vnis`, `show.macs` and routescope, so the API is unchanged.

The device is made in the leaf's namespace before vtep4rd starts. In a
lab, vtep4rd's container does it in its `cmd`, since it shares the
leaf's namespace:

```sh
until ip link show eth2 >/dev/null 2>&1; do sleep 0.2; done
ip link add link eth2 name eth2.100 type vlan id 100; ip link set eth2.100 up
exec vtep4rd -f /etc/vtep4r/vtep4rd.yml
```

QinQ is the same, with an 802.1ad device and a device per C-VLAN on
it: `eth2.1000` (`type vlan proto 802.1ad id 1000`), then `eth2.1000.10`
(`type vlan id 10`). vtep4rd opens `eth2.1000.10`.

### What vtep4rd adds

Four things.

1. **A parent and its VLAN devices are not both ports.** The owner's
   rule (2026-11-28): a VLAN is `eth2.VID`, untagged traffic is plain
   `eth2`, and one interface is never both. A lab that needs both runs
   two links between the same two nodes. The parent's socket reads
   every VLAN's frames, untagged (measured above), so with both each
   frame would be bridged twice. At start, and on `vni.add` and
   `config.reload`, vtep4rd reads `/sys/class/net/NAME/lower_*` for
   every port, and refuses a set where one port is below another. The
   answer names both. This covers QinQ too: `eth2.1000` is below
   `eth2.1000.10`.
2. **A tagged inner frame from the tunnel is dropped**, `inner_vlan`:
   a frame with 0x8100 or 0x88a8 at offset 12 (RFC 7348 section 6.1,
   "SHOULD be discarded unless configured otherwise"). Today vtep4rd
   delivers it. It is counted in `show.counters` and is a `drop` event.
   This is for VXLAN bridge domains. Whether `from_core` does the same
   over MPLS is open, since RFC 7432's text on it is not read yet.
3. **A VNI may keep inner tags**, `inner_vlan: keep`, as RFC 7348's
   "unless configured otherwise". Tagged inner frames are then taken
   from the tunnel and delivered as they are. This is RFC 8365's VLAN
   Bundle Service, and QinQ where an S-VLAN is one VNI. It needs the
   tags on the port side, which only `PACKET_AUXDATA` gives: see the
   next section. It is the last step of the work.

4. **A frame its port refuses is a drop**, `port_send`. Today
   `execute` logs `EMSGSIZE` from `@ports.send` as a warning and counts
   nothing, so a jumbo frame out of a 1500 byte port is lost without a
   trace. It becomes a `drop` with the errno in its data, counted in
   `show.counters`. The background generator's accounting needs it. It
   is a fix, with a test that fails first.

`too_big` is unchanged. A VLAN device's frames are already untagged. A
kept inner tag counts in the inner frame's length, as it should.

### datalink-socket, only for kept tags

Nothing in datalink-socket is needed for steps 1 to 4 below. For
`inner_vlan: keep`, a port must read the tag the kernel took out:

- **`restore_vlan: true` on the Linux backend.** The socket sets
  `PACKET_AUXDATA`. Each read uses libc's `recvmsg` with flags 0. When
  the auxdata has `TP_STATUS_VLAN_VALID`, the four octets go back after
  the source MAC: the TPID (`tp_vlan_tpid` when
  `TP_STATUS_VLAN_TPID_VALID` is set, 0x8100 otherwise), then the TCI.
  The frame then reads as it was on the wire. Off by default, so
  isis4r sees what it sees today.
- **`Frame` keeps the DEI bit**, as `vlan_dei`, and parses a 0x88a8
  outer tag, as `vlan_tpid`. This is a fix, with a test that fails
  first. It can go in on its own, before the rest.

vtep4rd opens a port with `restore_vlan` only when its VNI keeps tags.

### Injecting from a host

The owner's idea (2026-11-28): datalink-socket sends frames on VLANs
the leaf does not serve, and they must be dropped. The frames are made
and sent by datalink-socket, in a tool of its own, `datalink-gen` (a
class and a command), which the background generator below shares. The
owner decided (2026-11-28) that the one-off injector lives there too,
beside `arp-scan` and `arp-spoof`. vtep4r-sim injects into the tunnel
today; for the host side it is only the HTTP face over `datalink-gen`,
so a scenario can drive it:

| Path | Body keys | Does |
| --- | --- | --- |
| `POST /api/frame` | `dev`, `vlan`, `count`, `per_second`, `src`, `dst`, `ethertype`, `size`, `inner` (hex) | `count` frames out of `dev` through `datalink-gen`. `vlan` is a list, outer first, of `{ vid, pcp, dei, tpid }` (0x8100 by default), or none for untagged. Any VID, 0 to 4095, on purpose |

The same from a shell, with no sim:
`datalink-gen send --dev eth1 --vlan 400 --count 100`. It writes and
never reads, so the sim still keeps no MAC table and forwards nothing. It runs in the host's namespace, as `inj` runs in
`l1`'s. Writing a tagged frame on a parent works today (measured above).
routescope's `vxlan:` step gains `frame`.

What each case expects at the leaf:

| Case | Expected |
| --- | --- |
| VID with no device | dropped by the kernel, counted in the parent's `rx dropped`; in no VTEP's MAC table |
| VID 4095 | the same. 4095 is reserved in 802.1Q, from memory |
| VID 0, priority tagged | to be measured: 802.1Q treats it as untagged, from memory, and the kernel's answer is not known |
| an S-tag on a port with only 802.1Q devices | dropped, as a VID with no device |
| two tags on an 802.1Q device | the outer tag maps the VLAN; the inner tag reaches vtep4rd in the frame, and vtep4rd tunnels it. To be measured, and then decided |

### Background traffic on the trunk

The owner's idea (2026-11-28): a generator of tagged frames over a range
of VLANs, as background on the trunk while a scenario runs. It is built
on `datalink-gen`, above: `send` is a count of frames, `run` goes on
until stopped. vtep4r-sim wraps it so a scenario can start and stop it.

| Path | Body keys | Does |
| --- | --- | --- |
| `POST /api/background` | `dev`, `vids` (`"1-4094"`, or a list), `map`, `per_second`, `size`, `macs` (per VID), `dst`, `tpid` | starts the generator, round robin over `vids`. One at a time; a second start replaces the first. Answers its `run` id |
| `DELETE /api/background` | | stops it, and answers what it sent, per VID |
| `GET /api/background` | | the running one, its rate and its counts |
| `POST /api/count` | `dev`, `vni`, `run` | starts a receiver on `dev`, the far end, for one run: `datalink-gen count` |
| `DELETE /api/count` | | stops it, and answers what it read, per VID |
| `GET /api/count` | | the same, while it runs |

- Each VID sends from `macs` source MACs of its own, made from the VID
  and an index, so on a served VLAN the far VTEP learns a known number
  of MACs. That makes it a MAC table test too: the count, then the
  ageing after a stop.
- `dst` is a MAC nobody owns by default. On a served VLAN that is
  unknown unicast, flooded to every VTEP in the VNI's flood list. That
  is the load, and the scenario says so. `ff:ff:ff:ff:ff:ff` floods to
  every host as well; a host's own MAC crosses one tunnel only.
- `per_second` is required, with no "as fast as it can". Measured on
  ospflab (6 cores, Ruby 3.3.8, a veth pair in network namespaces), one
  Ruby process with datalink-socket sent 1,104,685 frames a second on
  one VID, 1,124,951 round robin over VIDs 1 to 4094 at 64 bytes, and
  1,022,443 at 1500 bytes. The other end counted every frame:

  ```
  ruby 3.3.8 vids 1-4094 size 64: 5624769 frames in 5.00s, 1124951/s
    gB0 rx: 5624769  rx_dropped: 5623395  gB0.100 rx: 5524803
  ```

  Of those 5,624,769, 1,374 were on VID 100, the only VID with a device,
  which is 5,624,769 / 4,094. The rest were counted in `rx_dropped`. So
  a generator unbounded takes a core of a VM other sessions share, and
  floods a served VNI faster than vtep4rd can forward, which is not
  measured yet. The sim caps `per_second` at 10,000 until vtep4rd's
  forwarding rate is measured, and the cap is then set from it.

What it shows, in lab 1's `background` scenario below: the VLANs a leaf
serves keep working under load on the ones it does not, the drop counter
rises by the unserved share of the rate, only the served VIDs' MACs
reach a VTEP, and every frame sent is accounted for.

#### What each frame carries

The owner's idea (2026-11-28): the payload says what the frame is, so a
receiver can tell where it came from and count it. After the Ethernet
header and its tags, the ethertype is 0x88b5, IEEE 802's local
experimental ethertype (from memory, to be read in IEEE Std 802 before
it is relied on). Then, big endian:

| Bytes | Field | |
| --- | --- | --- |
| 4 | magic | `DLG1` |
| 4 | run | random per run, so a frame of an older run is never counted |
| 2 | vid | the outer VID it was sent on, 0 for untagged |
| 2 | inner vid | the C-VID under an S-tag, else 0 |
| 4 | vni | the VNI it must arrive in, from `map`; 0 when it must be dropped |
| 8 | seq | per VID, from 1 |
| 8 | sent | `CLOCK_MONOTONIC` in ns. Containers without a time namespace share it, so a receiver on the same VM gets the latency |
| 2 | size | the frame's length as sent |
| 4 | crc | CRC-32 of the frame up to this field |

That is 38 bytes. With the addresses, the ethertype and two tags, the
header is 22 bytes, so even a QinQ frame fits in 60, the smallest
Ethernet frame without its FCS. The rest is a filler to `size`.

#### A VID mapped to a VNI

`map` is `{ vid: vni }`, the leaf's own mapping, given by the scenario
(lab 1: `{100: 100, 200: 200, 300: 300}`). A VID out of `map` carries
VNI 0: the frame must be dropped at the leaf. A QinQ key is
`"1000.10"`. The generator never reads the leaf's file: the scenario
states what it expects, and the receivers check it.

A receiver is told its device's VNI (`vni`, h3's `eth1.200` is 200) and
the `run`. It reads every frame with the magic and the run, and counts
per VID:

| Count | Means |
| --- | --- |
| `received` | arrived in the right VNI |
| `lost` | gaps in `seq` at the end of the run |
| `duplicate`, `reordered` | a `seq` seen before, or lower than the last |
| `wrong_vni` | the frame's VNI is not this device's: a leak between VNIs |
| `leaked` | the frame's VNI is 0: it should have been dropped at the leaf |
| `bad_crc` | the frame was changed on the way |
| `latency` | min, mean and max, in µs |

A receiver reads frames that are not for its MAC. Measured on a veth
pair, with no promiscuous mode: a frame to `02:bb:bb:bb:bb:01` was read
on the parent and on its VLAN device, as `otherhost`:

```
gB0 read: {[1514, :otherhost]=>2}
gB0.100 read: {[1514, :otherhost]=>1}
```

So the default `dst`, a MAC nobody owns, is counted as well.

The receiver never relies on a tag it reads. The kernel takes the outer
one out (measured above), so the payload's `vid` says which VLAN the
frame was sent on, and the device it arrived on says which VNI it came
out of. That holds on a VLAN device and on a plain port alike, with no
auxdata.

#### Every frame accounted for

After a stop and a drain of 1 s, the scenario checks, per VID, that
what was sent is what arrived plus what was dropped with a reason:

- **A served VID**: `sent` = `received` at each receiver of the VNI +
  vtep4rd's drops for that VNI (`too_big`, `port_send`). `lost`,
  `duplicate`, `wrong_vni`, `leaked` and `bad_crc` are 0. A flooded
  frame is counted at each receiver, once.
- **An unserved VID**: no receiver counts it, `leaked` is 0 everywhere,
  and the leaf parent's `rx_dropped` rose by at least its `sent`. "At
  least", because the parent drops other frames too; the scenario reads
  the counter before the run.

routescope reads both answers with a scenario condition of its own,
`frames`, in routescope's spec for these steps.

#### Frame sizes and jumbo frames

`size` is one length, a range `[64, 1518]` taken at random, or a list
of `[length, weight]` pairs for a mix. Lengths are without the FCS. A
length is checked at start against the device's MTU in
`/sys/class/net/DEV/mtu`, never left to fail frame by frame. `max` is
the largest the device takes. Measured on a veth pair, with
datalink-socket's `send`:

```
--- mtu 1500
tags 0 size 1514: sent
tags 0 size 1515: Errno::EMSGSIZE: Message too long - send(2)
tags 1 size 1518: sent
tags 1 size 1519: Errno::EMSGSIZE: Message too long - send(2)
tags 2 size 1522: Errno::EMSGSIZE: Message too long - send(2)
--- mtu 9000 on both ends and the VLAN device
tags 0 size 9014: sent
tags 1 size 9018: sent
tags 1 size 9019: Errno::EMSGSIZE: Message too long - send(2)
tags 2 size 9022: Errno::EMSGSIZE: Message too long - send(2)
--- sender 9000, receiver 1500
tags 0 size 1514: sent
tags 0 size 1600: Errno::ENOBUFS: No buffer space available - send(2)
```

So the kernel takes MTU + 14, and 4 more for one tag, but not 8 for two:
a QinQ frame is at most MTU + 18, its payload 4 less than a single
tagged frame's. The generator's `max` follows that. A veth whose peer
has the smaller MTU refuses with `ENOBUFS`. The generator counts a
refused frame as `refused`, never as `sent`.

Jumbo frames work when every hop takes them. containerlab's links are
9500 (measured in `evpn-vxlan-frr`: `eth1=9500 eth2=9500`, `eth0=1500`).
A VLAN device starts at its parent's MTU. Across the tunnel, vtep4rd's
`mtu` (1500 by default) is the underlay's: a frame over `mtu` - 36
(`OVERHEAD`, IPv4, UDP and VXLAN) is dropped as `too_big`. So a 9014
byte frame needs `mtu: 9050` or more on both leaves.

### The fault catalog

`inner_vlan_tag` joins `VXLAN::Fault`: a valid packet whose inner frame
has an 802.1Q tag. It is marked `vtep`, since what is right depends on
`inner_vlan`. It expects `drop` (RFC 7348 section 6.1). The matrix
records the kernel's answer. It is not assumed.

## The labs

Ruby first: every lab runs isis4rd under the fabric and vtep4rd on
every leaf, as `vxlan-ruby` does. The kernel's own VXLAN is the interop
check, in vtep4r's lab tier. Each lab is a folder under routescope's
`routescope/labs/`, beside `vxlan-ruby`, with flood and learn (static
flood lists), so nothing but VLANs is new.

Interface names are at most 15 characters in Linux. `eth2.1000.10` is
12.

### Lab 1, `vxlan-vlan-ruby`: three VLANs on one trunk

```
                         s1  isisd, 10.255.0.1
                     /    |    \
          10.0.1.0/30  10.0.2.0/30  10.0.3.0/30      IS-IS level 1, area 49.0001
                   /      |      \
                 l1       l2       l3                isisd, 10.255.0.11, .12, .13
          l1-vtep, inj  l2-vtep  l3-vtep             vtep4rd in each leaf's namespace
      eth2.100 .200 .300  eth2   eth2.200 .300
                 |        |        |
                h1       h2       h3
   eth1.100 .200 .300   eth1    eth1.200 .300
        h1-inj
```

| VNI | l1 | far end | Addresses |
| --- | --- | --- | --- |
| 100 | `eth2.100` | l2 `eth2`, untagged | 172.16.10.1 (h1), .2 (h2) |
| 200 | `eth2.200` | l3 `eth2.200` | 172.16.20.1 (h1), .3 (h3) |
| 300 | `eth2.300` | l3 `eth2.300` | 172.16.30.1 (h1), .3 (h3) |

- VLAN 100 goes to l2 and VLANs 200 and 300 to l3, as the owner asked.
- h2 is untagged. So VNI 100 is VLAN 100 at one end and no VLAN at the
  other: a VID matters only on its own port.
- l1's flood lists: VNI 100 to `10.255.0.12`, VNIs 200 and 300 to
  `10.255.0.13`. l2's and l3's: `10.255.0.11`.
- h1 sets `eth1`'s MAC to `02:00:00:00:01:01`. Its three VLAN devices
  take that MAC, as a VLAN device takes its parent's (the measures
  above: every frame from `b0`'s devices had `b0`'s source MAC). So one
  MAC is in three VNIs at l1, each in its own table.
- `h1-inj` runs vtep4r-sim in h1's namespace, for `frame` and the
  generator. `h2-inj` and `h3-inj` do the same in h2's and h3's, for
  the receivers.
- `inj` runs vtep4r-sim in l1's namespace, as in `vxlan-ruby`.

Its scenarios:

- `baseline`: IS-IS up; h1 pings h2 on VLAN 100, and h3 on 200 and 300.
  At l1, h1's MAC is local in VNIs 100, 200 and 300, on `eth2.100`,
  `eth2.200` and `eth2.300`. h2 is behind `10.255.0.12` in VNI 100,
  h3 behind `10.255.0.13` in 200 and 300. l2 has no VNI 200 or 300,
  and l3 no VNI 100.
- `vlan-down`: h3's `eth1.300` goes down, then up. VLAN 300's ping
  stops and comes back, and VLAN 200's never stops. This needs a
  scenario step for a device that is not a containerlab link. The
  `interface:` step names a link end, so this is routescope's to add.
- `unknown-vlans`: `h1-inj` sends 100 frames on VID 400, 100 on 4095
  and 100 with an S-tag, each from a source MAC of its own. No VTEP
  learns those MACs (`evpn_mac` with `present: false`). VLANs 100, 200
  and 300 still ping. l1's `eth2` counts the drops; reading that needs
  a routescope condition on an interface's counters, which does not
  exist yet.
- `background`: `h1-inj` starts the generator on `eth1`, VIDs 1 to
  4094, 1,000 frames a second, 5 MACs a VID. For 60 s, the three VLANs
  still ping, and l1's tables hold h1's MAC and 5 more in each of VNIs
  100, 200 and 300, and nothing else. l2 learns VNI 100's 5, and l3
  those of 200 and 300, behind `10.255.0.11`. After the stop and l1's `ageing` of 30 s, the 15 MACs
  are gone. l1's `eth2` drops rise by about 999 a second (4,091 of
  every 4,094), read with the same counter condition as
  `unknown-vlans`. `h2-inj` and `h3-inj` count on `eth1`, `eth1.200` and
  `eth1.300`: every frame of VIDs 100, 200 and 300 is received once, in
  its VNI, and none of another VID.
- `jumbo`: h1, h3, and l1's and l3's `eth2` and VLAN devices are at
  MTU 9000, every leaf's vtep4rd at `mtu: 9500`. h2 and l2's `eth2`
  stay at 1500, on purpose. The generator sends VIDs 100 and 200,
  sizes `[64, max]`. VNI 200 receives every frame at h3. VNI 100
  receives at h2 every frame of 1514 bytes or less; the rest are l2's
  `port_send` drops, and the sum is `sent`.
- `inner-tag`: `inj` sends `inner_vlan_tag` in VNI 200 to l3. l3-vtep
  drops it (`vxlan_drops` with `reason: inner_vlan`) and h3 does not
  learn its source.

### Lab 2, `vxlan-qinq-ruby`: an S-VLAN and C-VLAN pair is one VNI

QinQ terminated at the leaf. Two customers share h1's trunk, each on
an S-VLAN of its own, and both use C-VLAN 10.

```
                         s1
                     /    |    \
                 l1       l2       l3
      eth2.1000.10        eth2.10   eth2
      eth2.1000.20        eth2.20
      eth2.2000.10
                 |        |        |
                h1       h2       h3
   eth1.1000.10 .1000.20 .2000.10   eth1.10 .20   eth1
```

| VNI | Customer | l1 (S, C) | far end | Addresses |
| --- | --- | --- | --- | --- |
| 1010 | A | `eth2.1000.10` (1000, 10) | l2 `eth2.10`, C-tag only | 172.16.10.1, .2 |
| 1020 | A | `eth2.1000.20` (1000, 20) | l2 `eth2.20`, C-tag only | 172.16.20.1, .2 |
| 2010 | B | `eth2.2000.10` (2000, 10) | l3 `eth2`, untagged | 172.16.110.1, .3 |

- At l2, customer A's site has C-VLANs and no S-tag: the S-tag is
  popped across the tunnel. At l3, customer B's site is untagged.
- C-VLAN 10 is in both customers, in VNIs 1010 and 2010. The
  `isolation` scenario shows each VNI learns only its own customer's
  MACs.
- h1 cannot hold one subnet on two devices, so the customers' subnets
  differ. Isolation is shown by the MAC tables, not by a clash of
  addresses.
- `unknown-vlans` here: S 1000 with C 30 (no device), S 3000 (no
  device), and C 10 with no S-tag. All are dropped at l1, and VLAN 10
  of both customers still pings.

This lab needs no code beyond steps 1 and 2 below.

### Lab 3, `vxlan-qinq-keep-ruby`: an S-VLAN is one VNI, C-tags kept

QinQ carried as a whole. Customer A's S-VLAN 1000 is VNI 1000 with
`inner_vlan: keep`. Its C-VLANs, whatever they are, ride inside the
tunnel. It needs the last step, kept tags.

```
                 l1                         l2
          eth2.1000 (S 1000)              eth2 (plain)
                 |                          |
                h1                         h2
   eth1.1000 then .1000.10, .1000.20     eth1.10, eth1.20
```

- l1 opens `eth2.1000` with `restore_vlan`: the C-tag comes back from
  the auxdata (measured above: `tpid=0x8100 vid=10`). l2 opens `eth2`
  with `restore_vlan` too, since the kernel strips h2's C-tag there.
- On the way back, l1 writes the C-tagged frame on `eth2.1000`, and the
  kernel adds the S-tag (measured above).
- `baseline`: h1 pings h2 on C-VLANs 10 and 20. One VNI's MAC table at
  l1 holds both.
- `new-cvlan`: C-VLAN 30 is added at both hosts and pings, with no
  change at either leaf. That is what keeping tags is for.
- A third leaf with an S-VID of 2000 for the same VNI, S-VID
  translation, can be added later.

## Tests

- **Unit**, no root: the Forwarder's `inner_vlan` drop and `keep`; the
  port check on a fake `/sys`, refusing a parent with its child and a
  QinQ device with its C-VLAN device; `inner_vlan_tag` in the catalog.
  In datalink-socket: the auxdata unpacked from given bytes, and DEI;
  `datalink-gen`'s frames (VIDs in order, the source MACs per VID, the
  payload's fields and CRC), its pacing on a manual clock, sizes against
  a given MTU and tag count, and the receiver's counts on given frames:
  a gap, a duplicate, a reorder, a wrong VNI, a leak, a bad CRC, an older
  run. In vtep4r: `port_send` on a port that raises `EMSGSIZE`.
- **Functional**, no root: two vtep4rd on loopback wires. A tagged
  inner frame dropped, and kept with `inner_vlan: keep`.
- **Lab**, root: `test/lab/kernel_test.rb` gains a run with VLAN
  devices on one trunk in network namespaces, against the kernel's
  VXLAN. A trunk to vtep4rd in one VNI per VLAN, pings per VLAN. The
  kernel side is either a VXLAN device per VNI in its own bridge, or
  one vlan-aware bridge with a single VXLAN device mapping VIDs to
  VNIs, which FRR uses. Which runs on kernel 7.0 is measured first.
- **The fault matrix** gains `inner_vlan_tag`, regenerated.

## Work

1. vtep4r: the port check, the `inner_vlan` drop, `inner_vlan_tag` in
   the catalog and the matrix, and the lab tier run with VLAN devices.
2. routescope: lab 1 and lab 2, with their scenarios but `vlan-down`
   and `unknown-vlans`.
3. datalink-socket: `datalink-gen send`. vtep4r-sim: `POST /api/frame`
   over it. routescope: the `frame` step, a step for a device that is
   not a link, and a condition on an interface's counters, in a spec of
   its own. Then `vlan-down` and `unknown-vlans`.
4. datalink-socket: `datalink-gen run` and `count`, the payload, and
   sizes. vtep4r: `port_send`, a fix. vtep4rd's forwarding rate is
   measured, to set the cap. vtep4r-sim: `/api/background` with its cap,
   and `/api/count`. routescope: the `frames` condition. Then lab 1's
   `background` and `jumbo`.
5. datalink-socket: the DEI bit and 0x88a8 in `Frame`. A fix, on its
   own.
6. datalink-socket: `restore_vlan`. vtep4r: `inner_vlan: keep`. Then
   lab 3.

## Later

- **VLAN-Aware Bundle.** Several VNIs in one MAC-VRF, each identified
  by its Ethernet Tag (RFC 8365 section 5.1.2, option 2). That is
  bgp4rd's work: section 5.1.3 says that for locally assigned VNIs the
  Ethernet Tag "MUST be set to a VID". vtep4rd needs nothing more.
- **EVPN versions of these labs**, on bgp4rd, once the flood and learn
  ones pass.
- **PCP.** The kernel's VLAN devices map priorities with their own
  `egress-qos-map`. RFC 7348 is not read on mapping PCP to the outer
  header, so nothing is claimed.

## Open questions

1. **A parent with its VLAN devices.** Decided by the owner
   (2026-11-28): never both on one interface; two links when a lab
   needs both.
2. **The host injector's home.** Decided by the owner (2026-11-28):
   both the one-off frames and the background generator are
   datalink-socket's `datalink-gen`; vtep4r-sim is only their HTTP
   face.
3. **How datalink-socket calls `recvmsg`.** The outer tag is in the
   auxdata only, offload on or off (measured above), so kept tags need
   it. Fiddle, a default gem in 3.3 and 3.4, or a small C extension. Only step 6 needs it. Fiddle on
   Ruby 4.0 is not measured yet.
4. **`inner_vlan` over MPLS.** Should `from_core` drop a tagged inner
   frame too? RFC 7432 is to be read on it first.
5. **Two tags on an 802.1Q device.** The inner tag reaches vtep4rd in
   the frame, to be measured. Should vtep4rd drop a frame that still
   has a tag after the kernel took one?
