#ifndef TYPES_H
#define TYPES_H

#include <cstdint>

// Representasi 256-bit sebagai 4 uint64_t (little-endian)
typedef uint64_t uint256[4];

// Struktur untuk hasil dari GPU
struct Result {
    uint64_t priv_hi;      // 64-bit atas private key (hanya 7 bit efektif)
    uint64_t priv_lo;      // 64-bit bawah
    char address[35];      // Alamat Bitcoin compressed (string null-terminated)
};

// Konstanta kurva secp256k1
// p = 2^256 - 2^32 - 977
static const uint256 P = {
    0xFFFFFFFEFFFFFC2FULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL
};
// n = order of G
static const uint256 N = {
    0x14551231950B75FCULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL
};
// Gx, Gy (base point)
static const uint256 GX = {
    0x79BE667EF9DCBBACULL, 0x55A06295CE870B07ULL, 0x29BFCDB2DCE28D95ULL, 0x483ADA7726A3C465ULL
};
static const uint256 GY = {
    0x483ADA7726A3C465ULL, 0x29BFCDB2DCE28D95ULL, 0x55A06295CE870B07ULL, 0x79BE667EF9DCBBACULL
};
// a = 0, b = 7

#endif
