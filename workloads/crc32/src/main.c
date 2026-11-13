#include "crc32.h"
#include "random.h"

extern volatile uint32_t tohost[2];
extern volatile uint32_t fromhost[2];

static void putchar_htif(unsigned char value)
{
    tohost[0] = value;
    tohost[1] = 0x01010000u;
    while (tohost[0] || tohost[1]) {}
    fromhost[0] = 0;
    fromhost[1] = 0;
}

int main(void)
{
    srand_precomputed(0);
    
    uint32_t crc;
    for(int i = 0; i < 10000; i++) {
      crc = crc32pseudo();
    }

    const char prefix[] = "CRC32=";
    const char digits[] = "0123456789abcdef";
    for (unsigned i = 0; i < sizeof(prefix) - 1; ++i) {
        putchar_htif(prefix[i]);
    }
    for (int shift = 28; shift >= 0; shift -= 4) {
        putchar_htif(digits[(crc >> shift) & 15u]);
    }
    putchar_htif('\n');
    return 0;
}

/* RV32I has no multiply instruction or compiler runtime library. */
unsigned __mulsi3(unsigned a, unsigned b)
{
    unsigned result = 0;
    while (a) {
        if (a & 1u) result += b;
        a >>= 1;
        b <<= 1;
    }
    return result;
}
