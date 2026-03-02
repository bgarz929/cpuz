#ifndef TYPES_H
#define TYPES_H

#include <cstdint>

// Representasi 256-bit sebagai 4 uint64_t (little-endian)
typedef uint64_t uint256[4];

// Struktur untuk hasil dari GPU (mengembalikan private key dan public key affine)
struct Result {
    unsigned long long priv_hi;
    unsigned long long priv_lo;
    uint64_t x[4];  // koordinat x public key (little-endian)
    uint64_t y[4];  // koordinat y public key (little-endian)
};

#endif
