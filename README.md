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

```asm
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

Compare each variant's checksum with an independent C reference.

TODO: Describe the microarchitectures and hardware comparisons.

## Artifacts

| Artifact | Generation and build flow |
|---|---|
| Compiler, assembler, disassembler, and linker | OpenVADL LLVM backend generation, followed by an LLVM build |
| Functional instruction set simulator (ISS) | OpenVADL QEMU frontend generation, followed by a QEMU build |

We use the functional ISS to test instruction behavior and check the workload's
results.

TODO: List the RTL and hardware artifacts and their build flows.

## Project layout
TODO: Remove the layout, just used as implementation reference
```text
specs/                      # Upstream RISC-V snapshot and custom specifications
workloads/crc32/            # Application, fixed input, and bare-metal runtime
scripts/
  common.sh                # Shared checks, output, timing, and logging
  build-lcb.sh              # Generate and build the LLVM toolchain
  build-iss.sh              # Generate and build the QEMU ISS
  run-crc32.sh              # Build and test the workload
gen/                        # Generated sources and binaries
results/                    # Logs, measurements, and run metadata
```

TODO: Add the RTL and hardware scripts to the layout.

## Requirements

Install the dependencies before running the scripts.

These versions come from OpenVADL. Native builds haven't been verified yet.

| Scope | Requirements |
|---|---|
| Common | Bash 3.2+, Python 3.11+, Git, Make, a C/C++ toolchain with C++17 support, CMake 3.20+, Ninja, curl, tar, gzip, unzip, and CA certificates |
| OpenVADL | A working `openvadl` installation on `PATH` |
| QEMU ISS | pkg-config, GLib 2.66+, Pixman, libfdt, zlib, Meson 1.5.0, and pycotap 1.3.1 |
| Optional compiler cache | sccache or ccache |

TODO: List the RTL and hardware dependencies and versions.

### Linux

These commands are for Ubuntu 24.04:

```sh
sudo apt update
sudo apt install build-essential git curl ca-certificates cmake ninja-build \
  pkg-config python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev \
  libfdt-dev zlib1g-dev tar gzip zip unzip
```

Other Linux distributions need equivalent packages and development headers.

TODO: Add Linux installation commands for the RTL and hardware dependencies.

### macOS

Install the Xcode command line tools and common packages using the [homebrew](https://brew.sh) packet manager:

```sh
xcode-select --install
brew install python@3.12 cmake ninja pkgconf glib pixman dtc zlib \
  curl unzip
```

TODO: Add macOS installation commands for the RTL and hardware dependencies.

### Java management (optional)

[SDKMAN](https://sdkman.io/install/) manages JDK installations on Linux and macOS.
It needs `curl`, `zip`, and `unzip`. Install it and list available Java versions:

```sh
curl -s "https://get.sdkman.io" | bash
source "$HOME/.sdkman/bin/sdkman-init.sh"
sdk list java
```

Run `sdk install java VERSION` to install a JDK and `sdk use java VERSION` to
select it for the current shell. Replace `VERSION` with an identifier from the
list. See [SDKMAN usage](https://sdkman.io/usage/).

### QEMU Python dependencies

Install the Python dependencies into a virtual environment. Use that environment's
Python for the QEMU build:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install meson==1.5.0 pycotap==1.3.1
```

## Script usage

TODO: Implement the script interface shown below.

Run the scripts from the project root. All scripts accept `--variant NAME`:
`rv32i`, `crc0`, `crc1`, `crc2`, or `crc012`. The `crc012` variant includes all
three custom instructions.

### Build artifacts

Build the compiler toolchain and functional ISS for the selected variant:

```sh
./scripts/build-lcb.sh --variant rv32i --jobs 8 --link-jobs 1
./scripts/build-iss.sh --variant rv32i --jobs 8
```

- `build-lcb.sh` generates and builds the compiler, assembler, disassembler, and linker.
- `build-iss.sh` generates and builds the functional ISS.

These scripts produce artifact executables under `gen/VARIANT/lcb/` and
`gen/VARIANT/iss/`. CRC32 compilation and execution are separate steps.

| Option | Scripts | Purpose |
|---|---|---|
| `--jobs N` | Both build scripts | Limit parallel compilation |
| `--link-jobs N` | `build-lcb.sh` | Limit parallel LLVM linking |
| `--cache none`, `--cache sccache`, or `--cache ccache` | `build-lcb.sh` | Select the compiler cache, with `none` as the default |
| `--clean` | Both build scripts | Remove compiled build outputs before rebuilding |

The build scripts download the LLVM and QEMU sources on the first build. Later
builds reuse existing sources and build outputs. `--clean` leaves compiler caches
intact.

TODO: Add the RTL artifact build scripts and their options.

### Run CRC32

By default, `run-crc32.sh` performs these workload steps with the artifact
executables built for the selected variant:

1. Compile, assemble, and link the CRC32 workload with the generated toolchain.
2. Run the executable on the generated ISS and check its checksum against the C reference.
3. TODO: Define the RTL steps.

Compile and test the RV32I workload on the ISS:

```sh
./scripts/run-crc32.sh --variant rv32i --skip-rtl
```

| Option | Effect |
|---|---|
| `--skip-compile` | Reuse an existing executable for the selected variant |
| `--skip-iss` | Skip ISS execution and its checksum check |
| `--skip-rtl` | Skip the RTL steps |

E.g. only run the ISS without recompiling:

```sh
./scripts/run-crc32.sh --variant rv32i --skip-compile --skip-rtl
```

The script checks dependencies and input files only for enabled steps.

CRC32 assembly and executables go in `gen/VARIANT/crc32/`.

TODO: Define the RTL run options and required artifacts.

## Results

The scripts write logs and results to `results/VARIANT/`:

| File | Contents |
|---|---|
| `build-lcb.log` | LLVM generation and build output |
| `build-iss.log` | ISS generation and build output |
| `build-times.csv` | Generation and build times, build options, and compiler-cache settings |
| `crc32-compile.log` | Workload compiler, assembler, and linker output |
| `crc32-iss.log` | ISS simulation output |
| `crc32-iss.csv` | Expected checksum, actual checksum, and pass or fail result |
| `run.json` | Commands, tool versions, specification and input hashes, host information, and skipped steps |

Build timings report source generation and compilation separately. The ISS
results report functional correctness. Skipped steps are marked as skipped.

TODO: Describe RTL cycle measurements, chip area, and frequency estimates.
