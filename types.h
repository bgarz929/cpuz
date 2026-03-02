#ifndef TYPES_H
#define TYPES_H

#include <cstdint>

// Representasi 256-bit sebagai 4 uint64_t (little-endian)
typedef uint64_t uint256[4];

// Struktur untuk hasil dari GPU
struct Result {
    unsigned long long priv_hi;   // 64-bit atas private key
    unsigned long long priv_lo;   // 64-bit bawah
    uint8_t hash160[20];          // RIPEMD-160 hash dari public key
};

#endif
