# EVPN over MPLS: the codec

vtep4r carries Ethernet frames over MPLS for EVPN, as bgp4r's
`docs/design/evpn-mpls.md` asks (approved 2026-11-27). Built: the codec
in `vxlan/mpls/` (step 0a), and MPLS bridge domains with their
forwarding and API (step 0b). The edge in vtep4rd, which reads and
sends these packets on the core's devices, is not built yet (0c).

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

**Until step 0c**, vtep4rd has no MPLS edge: a `Push` is counted and
published as a drop, `no_mpls_edge`, and nothing reads the core.

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
