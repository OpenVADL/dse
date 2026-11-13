# OpenVADL Design Space Exploration

This project demonstrates design space exploration (DSE) with
[OpenVADL](https://github.com/OpenVADL/openvadl). It provides the experiments for
the TECS paper and uses a RISC-V specification with custom instructions for CRC32
computation.

It provides scripts to generate, build, and run artifacts produced by OpenVADL
from VADL specifications. The scripts are written for Linux and macOS.

## Experiment

The application is the modified [Embench](https://github.com/embench/embench-iot)
CRC32 workload from OpenVADL. It computes a checksum over an array of pseudorandom
numbers.

The baseline is RV32I, the 32-bit RISC-V base integer instruction set. The CRC32
loop in C and RV32I assembly is shown below. `data` and `table` contain 32-bit
unsigned values.

```c
uint32_t crc = 0xffffffffu;
for (unsigned i = 0; i < 1024; ++i) {
    crc = table[(crc ^ data[i]) & 0xff] ^ (crc >> 8);
}
```

```riscv
# a0: input pointer, a1: crc, a2: table pointer, a3: input end
.loop:
    lw      a4, 0(a0)
    xor     a4, a4, a1     # crc0
    andi    a4, a4, 255    # crc0
    slli    a4, a4, 2      # crc1
    add     a4, a4, a2     # crc1
    lw      a4, 0(a4)      # crc1
    srli    a1, a1, 8      # crc2
    xor     a1, a1, a4     # crc2
    addi    a0, a0, 4
    bne     a0, a3, .loop
```

The groups marked `crc0`, `crc1`, and `crc2` contain seven of the loop's ten
instructions. We replace each group with one custom instruction, reducing the
loop to six instructions.

Each custom instruction reads two source registers and writes one destination
register:

| Instruction | Operation |
|---|---|
| `crc0` | XOR two registers and zero-extend the lowest byte |
| `crc1` | Load a 32-bit word at `rs1 + (rs2 << 2)` |
| `crc2` | Compute `rs1 ^ (rs2 >> 8)` |

The experiment compares five ISA variants: RV32I, RV32I+crc0, RV32I+crc1,
RV32I+crc2, and RV32I+crc0/1/2.

Compare each variant's checksum with the known result `65842ca9`.

TODO: Describe the microarchitectures and hardware comparisons.

## Artifacts

| Artifact | Generation and build flow |
|---|---|
| Compiler, assembler, disassembler, and linker | OpenVADL LLVM backend generation, followed by an LLVM build |
| Functional instruction set simulator (ISS) | OpenVADL QEMU frontend generation, followed by a QEMU build |
| RTL | OpenVADL RTL generation, sbt SystemVerilog emission, Yosys synthesis, and OpenROAD placement and timing analysis |

We use the functional ISS to test instruction behavior and check the workload's
results.

## Project layout
TODO: Remove the layout, just used as implementation reference
```text
specs/                      # Upstream RISC-V snapshot and custom specifications
workloads/crc32/            # Workload Makefile, documentation, and license
  src/                     # CRC32 kernel, input generator, and bare-metal runtime
scripts/
  check-deps.sh             # Common and backend-specific dependency checks
  lib/                      # Shared Bash probes, shell helpers, and ISS results
  build-lcb.sh              # Generate and build the LLVM toolchain
  build-iss.sh              # Generate and build the QEMU ISS
  build-rtl.sh              # Generate RTL and run the Sky130 hardware flow
  run-crc32.sh              # Build and test the workload
hardware/                   # Yosys/OpenROAD templates and Sky130 PDK inputs
gen/                        # Generated sources and binaries
results/                    # Logs, measurements, and run metadata
```

## Requirements

Install the dependencies before running the scripts.
The prebuilt OpenVADL distribution needs no separate Java installation.
The HDL flow requires a JDK for sbt.

| Scope | Requirements |
|---|---|
| Common | Bash 3.2+, Python 3.11+, jq 1.6+, Git, Make, a C/C++ toolchain with C++17 support, CMake 3.20+, Ninja, curl, tar, gzip, unzip, and CA certificates |
| QEMU ISS | pkg-config, GLib 2.66+, Pixman 0.21.8+, libfdt 1.5.1+, and zlib |
| HDL/ASIC | JDK 17 or newer (17 or 21 LTS recommended), sbt, Yosys with ABC, OpenROAD, and Sky130 Liberty/LEF files (included in `hardware/pdk/sky130/`) |
| Optional compiler cache | ccache (preferred) or sccache |

### Linux

These commands are for Ubuntu 24.04:

```sh
sudo apt update
sudo apt install build-essential git curl ca-certificates cmake ninja-build jq \
  pkg-config python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev \
  libfdt-dev zlib1g-dev tar gzip zip unzip
```

Other Linux distributions need equivalent packages and development headers.

For the HDL/ASIC flow, install a JDK and Yosys (including ABC):

```sh
sudo apt install openjdk-17-jdk yosys
```

Install sbt through its
[official apt repository](https://www.scala-sbt.org/1.x/docs/Installing-sbt-on-Linux.html#Ubuntu+and+other+Debian-based+distributions).
For a newer Yosys, prebuilt binaries are available through the
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build#installation).
OpenROAD provides downloadable Ubuntu `.deb` packages installable with
`sudo apt install ./PACKAGE.deb`. See the
[OpenROAD installation instructions](https://openroad.readthedocs.io/en/latest/user/Build.html)
for downloads or source builds.

### macOS

Install the Xcode command line tools and common packages using the [homebrew](https://brew.sh) packet manager:

```sh
xcode-select --install
brew install python@3.12 cmake ninja jq pkgconf glib pixman dtc zlib \
  curl unzip
```

Install sbt and Yosys (including ABC) with Homebrew:

```sh
brew install sbt yosys
```

OpenROAD can be built from source following the
[OpenROAD build instructions](https://openroad.readthedocs.io/en/latest/user/Build.html).
Add the directory containing the built `openroad` binary to `PATH`.

## Script usage

Run the entry scripts from any directory. The build scripts and dependency
checker use the `dse` project root as their working directory. Relative paths,
including `--output-dir`, the RTL specification, `PYTHON`, and `OPENVADL`, resolve
from that root.
Absolute paths work as given. The Python environment setup script finds the
project root automatically when its optional `ROOT` argument is omitted.

All artifact build scripts require `--variant NAME`:
`rv32i`, `crc0`, `crc1`, `crc2`, or `crc012`. The `crc012` variant includes all
three custom instructions.

Set `OPENVADL` to select an OpenVADL executable by name or path for all build
scripts and `check-deps.sh`. The default is `openvadl` from `PATH`.

```sh
OPENVADL=nativevadl ./scripts/build-iss.sh --variant rv32i
```

### Build artifacts

Build the compiler toolchain and functional ISS for the selected variant:

```sh
./scripts/build-lcb.sh --variant rv32i --jobs 8 --link-jobs 1
./scripts/build-iss.sh --variant rv32i --jobs 8
```

- `build-lcb.sh` generates and builds the compiler, assembler, disassembler, and linker.
- `build-iss.sh` generates and builds the functional ISS.

The ISS build enables QEMU plugins and builds the `insn` instruction counter
in `gen/VARIANT/iss/build/tests/tcg/plugins/`.

These scripts produce artifact executables under `gen/VARIANT/lcb/` and
`gen/VARIANT/iss/`. CRC32 compilation and execution are separate steps.

| Option | Scripts | Purpose |
|---|---|---|
| `--jobs N` | ISS and LCB | Limit parallel compilation |
| `--link-jobs N` | `build-lcb.sh` | Limit parallel LLVM linking |
| `--cache auto`, `--cache ccache`, `--cache sccache`, or `--cache none` | All build scripts | Select the compiler cache, with `auto` as the default |
| `--clean` | ISS and LCB | Remove compiled build outputs before rebuilding |

The build scripts download the LLVM and QEMU sources on the first build. Later
builds reuse existing sources and build outputs. `--clean` leaves compiler caches
intact.

All build scripts use `ccache` when it is available, otherwise `sccache` when it
is available, and no compiler cache otherwise. Use `--cache` to override this
selection. `--cache none` disables compiler caching.

### Build RTL

```sh
./scripts/build-rtl.sh --variant crc012
./scripts/build-rtl.sh --variant crc012 --microarchitecture 3stage
```

The script selects the specification and top module for the bundled
[OpenVADL pipelines](https://github.com/OpenVADL/openvadl/tree/59211d05e6752e4ff07a3ede960b7d298f2082f4/sys/risc-v/mia).
Defaults: `5stage` and a 5 ns clock period.
Use `--clock-period NS` to change the period and `--help` for specification and module overrides.

Sources and outputs go in `gen/VARIANT/rtl/MICROARCHITECTURE/`, with SystemVerilog and netlists in its `build/` subdirectory.
Check dependencies with `./scripts/check-deps.sh rtl`.

### Run CRC32

`run-crc32.sh` uses the artifact executables built for the selected variant:

1. Compile, assemble, and link the CRC32 workload with the generated toolchain.
2. Run the executable on the generated ISS and compare the full 32-bit checksum with the known result.
3. Print and record the executed instruction count from QEMU's `insn` plugin.

The standalone [workload](workloads/crc32/README.md) uses a small Makefile and
bare-metal runtime. It fills an array of 1,024 words before the CRC loop.
The expected result is `65842ca9` for all five variants.
RTL workload execution is unavailable and is always recorded as skipped.

Compile and test the RV32I workload on the ISS:

```sh
./scripts/run-crc32.sh --variant rv32i
```

| Option | Effect |
|---|---|
| `--skip-compile` | Reuse an existing executable for the selected variant |
| `--skip-iss` | Skip ISS execution and its checksum check |
| `--skip-rtl` | Accepted for compatibility. RTL execution is always skipped |
| `--timeout SECONDS` | Limit ISS execution time. Default: 30 seconds, positive integer |
| `--output-dir DIR` | Set the artifact root. Default: `gen/VARIANT` |
| `--lcb-bin DIR` | Select a directory with generated LLVM executables |
| `--target NAME` | Override the generated LLVM target name |
| `--iss FILE` | Select a generated QEMU executable |
| `--insn-plugin FILE` | Override the instruction-count plugin path |

Reuse the ELF and run the ISS:

```sh
./scripts/run-crc32.sh --variant rv32i --skip-compile
```

The script checks dependencies and input files only for enabled steps.
The runner needs Bash and jq. Compilation also needs Make and the generated
`clang`, `llvm-mc`, `ld.lld`, and `llvm-objdump`.
It uses the successful LCB build record to find custom compiler paths
and target names when available.
ISS runs need `libinsn.so` on Linux or `libinsn.dylib` on macOS in the ISS build's
`tests/tcg/plugins/` directory. Rebuild the ISS if the plugin is missing.

Instruction counts cover the full program, including startup, input generation,
CRC computation, and checksum output. They don't measure hardware cycles.
Totals can vary slightly during HTIF shutdown.

CRC32 assembly and executables go in `gen/VARIANT/crc32/`.
Compilation also writes `crc32.dump`, the linked executable's disassembly with
instruction addresses and bytes. The runner prints its path.

The runner records the custom instructions selected in the kernel assembly.
The [workload notes](workloads/crc32/README.md) give additional information about the workload.

## Results

The scripts write logs and results to `results/VARIANT/`:

| File | Contents |
|---|---|
| `build-lcb.log` | LLVM generation and build output |
| `build-iss.log` | ISS generation and build output |
| `rtl/MICROARCHITECTURE/build-rtl.log` | RTL generation, SystemVerilog emission, synthesis, placement, and timing output |
| `build-times.csv` | Generation and build times, build options, and compiler-cache settings |
| `crc32-compile.log` | Workload compiler, assembler, and linker output |
| `crc32-iss.log` | ISS simulation output |
| `crc32-insn.log` | QEMU instruction counts per CPU and in total |
| `crc32-iss.csv` | Expected checksum, actual checksum, pass or fail result, and full-program instruction count |
| `run.json` | Commands, tool versions, specification and input hashes, host information, and skipped steps |

Build timings report source generation and compilation separately. The ISS
results report functional correctness. Skipped steps are marked as skipped.

RTL logs, `run.json`, and `build-times.csv` go in `results/VARIANT/rtl/MICROARCHITECTURE/`.
Hardware timing reports remain in the logs. RTL workload cycle measurements remain unimplemented.
