ifndef LCB_BIN
$(error Set LCB_BIN to the generated LLVM bin directory)
endif
ifndef TARGET
$(error Set TARGET to the generated LLVM target name)
endif
ifndef OUT
$(error Set OUT to the workload output directory)
endif

.PHONY: all
all:
	mkdir -p "$(OUT)"
	set -e; for source in crc_32 random main; do \
	  "$(LCB_BIN)/clang" --target="$(TARGET)" -O3 -ffreestanding -fno-builtin \
	    -fno-stack-protector -fno-pic -S "src/$$source.c" -o "$(OUT)/$$source.s"; \
	  "$(LCB_BIN)/llvm-mc" --arch="$(TARGET)" -filetype=obj \
	    "$(OUT)/$$source.s" -o "$(OUT)/$$source.o"; \
	done
	"$(LCB_BIN)/llvm-mc" --arch="$(TARGET)" -filetype=obj src/start.s -o "$(OUT)/start.o"
	"$(LCB_BIN)/ld.lld" -static -T src/link.ld "$(OUT)/start.o" "$(OUT)/crc_32.o" \
	  "$(OUT)/random.o" "$(OUT)/main.o" -o "$(OUT)/crc32.tmp.elf"
	mv "$(OUT)/crc32.tmp.elf" "$(OUT)/crc32.elf"
