ENTRY(_start)

MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 16M }

SECTIONS
{
    .text : { KEEP(*(.text.init)) *(.text .text.*) } > RAM
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
    .data : { *(.data .data.* .sdata .sdata.*) } > RAM
    .tohost : { KEEP(*(.tohost)) } > RAM
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM
    .stack (NOLOAD) : {
        . = ALIGN(16);
        . += 64K;
        __stack_top = .;
    } > RAM
}
