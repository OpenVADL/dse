# CRC32 workload

The Embench DSE kernel computes CRC32 over the lowest byte of 1,024 pseudorandom
words. Input generation runs before the kernel, with seed zero.

Build the variant's LCB and ISS, then run from the project root:

```sh
./scripts/run-crc32.sh --variant crc012
```

The Bash runner uses the Makefile to compile `src/` at `-O3` with the generated
toolchain. The bare-metal executable prints its checksum through HTIF on the ISS.
The runner checks the full result against the known checksum `65842ca9`
(`11433` modulo 32,768, as checked by Embench).

Outputs go in `gen/VARIANT/crc32/` and `results/VARIANT/`.
The runner prints the full-program instruction count from QEMU's `insn` plugin
and records it in `crc32-iss.csv` and `run.json`. The count includes startup,
input setup, and checksum output. It doesn't measure hardware cycles.
Totals can vary slightly during HTIF shutdown.
The current generated compiler selects `crc0` and `crc2` automatically, but doesn't
select `crc1`. Check `crc_32.s` and `run.json` for the selected instructions.

`crc_32.c`, `random.c`, and `random.h` originate from
`vadl/test/resources/embench/src/crc32-dse-vadl/` in OpenVADL checkout
`6b4131ad889f407340a6a226411dd6c3fb6c0d3c`.
The CRC source keeps its notices. The GPL version 3 license is in `COPYING`.
