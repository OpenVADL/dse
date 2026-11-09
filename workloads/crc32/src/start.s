.section .text.init,"ax",@progbits
.globl _start
.type _start,@function
_start:
    lui sp, %hi(__stack_top)
    addi sp, sp, %lo(__stack_top)
    lui t0, %hi(__bss_start)
    addi t0, t0, %lo(__bss_start)
    lui t1, %hi(__bss_end)
    addi t1, t1, %lo(__bss_end)
.Lzero:
    beq t0, t1, .Lmain
    sw zero, 0(t0)
    addi t0, t0, 4
    j .Lzero
.Lmain:
    call main
    slli a0, a0, 1
    ori a0, a0, 1
    lui t0, %hi(tohost)
    addi t0, t0, %lo(tohost)
    sw a0, 0(t0)
    sw zero, 4(t0)
.Lhalt:
    j .Lhalt
.size _start, .-_start

.section .tohost,"aw",@progbits
.balign 64
.globl tohost
.type tohost,@object
tohost:
    .word 0, 0
.size tohost, 8
.balign 64
.globl fromhost
.type fromhost,@object
fromhost:
    .word 0, 0
.size fromhost, 8
