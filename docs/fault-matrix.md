# The fault matrix

What each receiver does with each crafted packet of `VXLAN::Fault::CATALOG`,
against what RFC 7348 expects. After bgp4r's `docs/protocol-testing.md`,
"What three implementations do".

**Generated** by `test/lab/fault_matrix_test.rb` on 2026-11-18, Linux 7.0.0-43-generic,
vtep4r 0.1.0. Do not edit it by hand; run again, as root:

```sh
sudo VTEP4R_MATRIX_DOC=docs/fault-matrix.md DATALINK_LIB=~/datalink-socket/lib ruby -I. test/lab/fault_matrix_test.rb
```

Each packet is sent once by vtep4r-sim, with an inert broadcast (EtherType 0x88b5) as
its inner frame, from a source MAC of its own, to two receivers serving VNI 100 in
the namespaces of `test/lab/lab_net.rb`:

- **vtep4rd**: delivered when it learned the case's source MAC, which it does
  only from a packet it accepted; else the drop reason that rose.
- **The Linux kernel's `vxlan` device**: delivered when its fdb learned the MAC,
  else how its receive counters saw the drop. FRR has no VXLAN data plane of
  its own: zebra programs this device. So this column is FRR's too.

| Case | What | RFC 7348 expects | vtep4rd | Linux kernel, and FRR | Kernel as the RFC |
| --- | --- | --- | --- | --- | --- |
| `valid` | a valid packet, the baseline | deliver (5) | delivered | delivered | yes |
| `no_i_flag` | I flag clear | drop (5, 4.1) | dropped: no_i_flag | dropped before the device, not counted | yes |
| `r_bit_set` | one R bit set beside the I flag | ignore (5) | delivered | dropped, counted as an rx error | **no** |
| `r_bits_all` | every R bit set | ignore (5) | delivered | dropped, counted as an rx error | **no** |
| `reserved1_set` | the 24 reserved bits set | ignore (5) | delivered | dropped, counted as an rx error | **no** |
| `reserved2_set` | the last 8 reserved bits set | ignore (5) | delivered | dropped, counted as an rx error | **no** |
| `unknown_vni` | a VNI the receiver does not serve | drop (4.1) | dropped: unknown_vni | dropped before the device, not counted | yes |
| `short_header` | four octets, half a header (the RFC says nothing of a cut packet) | drop (5) | dropped: short | dropped before the device, not counted | yes |
| `no_inner_frame` | a header and nothing after it (the RFC says nothing of a cut packet) | drop (5) | dropped: short | dropped before the device, not counted | yes |
| `inner_too_short` | an inner frame of 13 octets, one short of an Ethernet header | drop (5) | dropped: short | dropped before the device, not counted | yes |

"ignore" means the receiver ignores the bits and delivers the frame: RFC
7348 section 5 says the R bits and reserved fields are "set to zero on
transmission and ignored on receipt". For the three cut packets the RFC
says nothing; a drop is our reading (`VXLAN::Fault`).

The kernel differs from the RFC on `r_bit_set`, `r_bits_all`, `reserved1_set`, `reserved2_set`: it drops packets whose reserved bits are set, where the RFC says to ignore them. Why is not known here.
