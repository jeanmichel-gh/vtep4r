# EVPN over MPLS: the codec

vtep4r carries Ethernet frames over MPLS for EVPN, as bgp4r's
`docs/design/evpn-mpls.md` asks (approved 2026-11-27). This guide is its
first part, the codec in `vxlan/mpls/`. The edge in vtep4rd, which reads
and sends these packets, is not built yet.

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
