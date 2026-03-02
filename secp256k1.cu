#include "types.h"
#include <cuda_runtime.h>

// Konstanta kurva secp256k1 dalam memori konstan GPU
__constant__ uint256 P = {
    0xFFFFFFFEFFFFFC2FULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL
};
__constant__ uint256 N = {
    0x14551231950B75FCULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL
};
// Base point G dalam little-endian (indeks 0 = LSB)
__constant__ uint256 GX = {
    0x59F2815B16F81798ULL,  // LSB
    0x029BFCDB2DCE28D9ULL,
    0x55A06295CE870B07ULL,
    0x79BE667EF9DCBBACULL   // MSB
};
__constant__ uint256 GY = {
    0x9C47D08FFB10D4B8ULL,  // LSB
    0xFD17B448A6855419ULL,
    0x5DA4FBFC0E1108A8ULL,
    0x483ADA7726A3C465ULL   // MSB
};

// Fungsi pembantu aritmetika 256-bit
__device__ int cmp256(const uint256 a, const uint256 b) {
    for (int i = 3; i >= 0; i--) {
        if (a[i] > b[i]) return 1;
        if (a[i] < b[i]) return -1;
    }
    return 0;
}

__device__ void add256(const uint256 a, const uint256 b, uint256 r) {
    uint64_t carry = 0;
    for (int i = 0; i < 4; i++) {
        uint64_t sum = a[i] + b[i] + carry;
        r[i] = sum;
        carry = (sum < a[i]) ? 1 : 0;
    }
}

__device__ void sub256(const uint256 a, const uint256 b, uint256 r) {
    uint64_t borrow = 0;
    for (int i = 0; i < 4; i++) {
        uint64_t sub = a[i] - b[i] - borrow;
        borrow = (a[i] < b[i] + borrow) ? 1 : 0;
        r[i] = sub;
    }
}

__device__ void shr256(uint256 a) {
    uint64_t carry = 0;
    for (int i = 3; i >= 0; i--) {
        uint64_t new_carry = (a[i] & 1) ? 0x8000000000000000ULL : 0;
        a[i] = (a[i] >> 1) | carry;
        carry = new_carry;
    }
}

__device__ void shl256(uint256 a) {
    uint64_t carry = 0;
    for (int i = 0; i < 4; i++) {
        uint64_t new_carry = (a[i] >> 63) & 1;
        a[i] = (a[i] << 1) | carry;
        carry = new_carry;
    }
}

// Penjumlahan modular: r = (a + b) % p
__device__ void mod_add(const uint256 a, const uint256 b, uint256 r) {
    uint64_t carry = 0;
    for (int i = 0; i < 4; i++) {
        uint64_t sum = a[i] + b[i] + carry;
        r[i] = sum;
        carry = (sum < a[i]) || (carry && sum == a[i]) ? 1 : 0;
    }
    // Jika carry atau r >= p, kurangi p
    if (carry) {
        uint64_t borrow = 0;
        for (int i = 0; i < 4; i++) {
            uint64_t sub = r[i] - P[i] - borrow;
            borrow = (r[i] < P[i] + borrow) ? 1 : 0;
            r[i] = sub;
        }
    } else {
        // Kurangi jika r >= p
        if (cmp256(r, P) >= 0) {
            uint64_t borrow = 0;
            for (int i = 0; i < 4; i++) {
                uint64_t sub = r[i] - P[i] - borrow;
                borrow = (r[i] < P[i] + borrow) ? 1 : 0;
                r[i] = sub;
            }
        }
    }
}

// Pengurangan modular: r = (a - b) % p
__device__ void mod_sub(const uint256 a, const uint256 b, uint256 r) {
    uint64_t borrow = 0;
    for (int i = 0; i < 4; i++) {
        uint64_t sub = a[i] - b[i] - borrow;
        borrow = (a[i] < b[i] + borrow) ? 1 : 0;
        r[i] = sub;
    }
    if (borrow) {
        uint64_t carry = 0;
        for (int i = 0; i < 4; i++) {
            uint64_t sum = r[i] + P[i] + carry;
            r[i] = sum;
            carry = (sum < r[i]) ? 1 : 0;
        }
    }
}

// Perkalian 256-bit (hasil 512-bit) kemudian reduksi mod p
__device__ void mod_mul(const uint256 a, const uint256 b, uint256 r) {
    uint64_t t[8] = {0};
    for (int i = 0; i < 4; i++) {
        uint64_t carry = 0;
        for (int j = 0; j < 4; j++) {
            uint64_t prod_lo = a[i] * b[j]; // low 64-bit
            uint64_t prod_hi = __umul64hi(a[i], b[j]); // high 64-bit
            uint64_t sum = prod_lo + t[i+j] + carry;
            carry = (sum < prod_lo) ? 1 : 0;
            t[i+j] = sum;
            sum = prod_hi + t[i+j+1] + carry;
            carry = (sum < prod_hi) ? 1 : 0;
            t[i+j+1] = sum;
        }
    }
    // Reduksi mod p (sederhana: ambil 4 kata terendah, lalu kurangi jika perlu)
    for (int i = 0; i < 4; i++) r[i] = t[i];
    if (cmp256(r, P) >= 0) {
        uint64_t borrow = 0;
        for (int i = 0; i < 4; i++) {
            uint64_t sub = r[i] - P[i] - borrow;
            borrow = (r[i] < P[i] + borrow) ? 1 : 0;
            r[i] = sub;
        }
    }
}

// Binary GCD untuk invers modular
__device__ void mod_inv(const uint256 a, uint256 r) {
    uint256 u, v, x1, x2;
    for (int i = 0; i < 4; i++) {
        u[i] = a[i];
        v[i] = P[i];
        x1[i] = (i == 0) ? 1 : 0;
        x2[i] = 0;
    }
    while (true) {
        while ((u[0] & 1) == 0) {
            shr256(u);
            if ((x1[0] & 1) == 0) {
                shr256(x1);
            } else {
                add256(x1, P, x1);
                shr256(x1);
            }
        }
        while ((v[0] & 1) == 0) {
            shr256(v);
            if ((x2[0] & 1) == 0) {
                shr256(x2);
            } else {
                add256(x2, P, x2);
                shr256(x2);
            }
        }
        if (cmp256(u, v) >= 0) {
            sub256(u, v, u);
            sub256(x1, x2, x1);
            if (cmp256(x1, (uint256){0}) < 0) add256(x1, P, x1);
        } else {
            sub256(v, u, v);
            sub256(x2, x1, x2);
            if (cmp256(x2, (uint256){0}) < 0) add256(x2, P, x2);
        }
        if (u[0] == 1 && u[1] == 0 && u[2] == 0 && u[3] == 0) {
            for (int i = 0; i < 4; i++) r[i] = x1[i];
            return;
        }
        if (v[0] == 1 && v[1] == 0 && v[2] == 0 && v[3] == 0) {
            for (int i = 0; i < 4; i++) r[i] = x2[i];
            return;
        }
    }
}

// Representasi titik dalam koordinat Jacobian (X, Y, Z) dengan Z=1 mewakili affine
struct Jacobian {
    uint256 x, y, z;
};

// Double titik Jacobian
__device__ void point_double(const Jacobian& p, Jacobian& r) {
    if (p.z[0] == 0 && p.z[1] == 0 && p.z[2] == 0 && p.z[3] == 0) {
        for (int i = 0; i < 4; i++) r.x[i] = r.y[i] = r.z[i] = 0;
        return;
    }
    uint256 t1, t2, t3, t4, t5;
    mod_mul(p.x, p.x, t1);
    mod_add(t1, t1, t2);
    mod_add(t1, t2, t1); // t1 = 3*x^2
    mod_mul(p.y, p.y, t2);
    mod_mul(t2, p.x, t3);
    mod_add(t3, t3, t2);
    mod_add(t2, t2, t2); // t2 = 4*x*y^2
    mod_mul(t1, t1, t3);
    mod_sub(t3, t2, r.x);
    mod_sub(r.x, t2, r.x); // r.x = t1^2 - 2*t2
    mod_sub(t2, r.x, t3);
    mod_mul(t1, t3, t4);
    mod_mul(p.y, p.y, t5);
    mod_mul(t5, t5, t5); // t5 = y^4
    mod_add(t5, t5, t5);
    mod_add(t5, t5, t5);
    mod_add(t5, t5, t5); // t5 = 8*y^4
    mod_sub(t4, t5, r.y);
    mod_mul(p.y, p.z, t1);
    mod_add(t1, t1, r.z);
}

// Penjumlahan titik Jacobian (dengan asumsi q adalah affine, z=1)
__device__ void point_add_affine(const Jacobian& p, const Jacobian& q, Jacobian& r) {
    if (p.z[0] == 0 && p.z[1] == 0 && p.z[2] == 0 && p.z[3] == 0) { r = q; return; }
    uint256 t1, t2, t3, t4, t5, t6;
    mod_mul(p.z, p.z, t1); // z1^2
    mod_mul(q.x, t1, t2);  // x2 * z1^2
    mod_sub(t2, p.x, t3);  // t3 = x2*z1^2 - x1
    mod_mul(p.z, t1, t1);  // z1^3
    mod_mul(q.y, t1, t4);  // y2 * z1^3
    mod_sub(t4, p.y, t5);  // t5 = y2*z1^3 - y1
    if (t3[0]==0 && t3[1]==0 && t3[2]==0 && t3[3]==0) {
        if (t5[0]==0 && t5[1]==0 && t5[2]==0 && t5[3]==0) {
            point_double(p, r);
        } else {
            for (int i=0;i<4;i++) r.x[i]=r.y[i]=r.z[i]=0;
        }
        return;
    }
    mod_mul(t3, t3, t6);   // t3^2
    mod_mul(t6, t3, t1);   // t3^3
    mod_mul(p.x, t6, t2);  // x1 * t3^2
    mod_mul(t5, t5, r.x);  // t5^2
    mod_sub(r.x, t1, r.x); // t5^2 - t3^3
    mod_sub(r.x, t2, r.x); // (t5^2 - t3^3) - 2*x1*t3^2? sebenarnya rumus: x3 = t5^2 - t3^3 - 2*x1*t3^2
    // di atas kita sudah kurangi t1 (t3^3) dan t2 (x1*t3^2), tapi perlu dua kali x1*t3^2
    mod_sub(r.x, t2, r.x);
    mod_sub(t2, r.x, t6);  // t2 = x1*t3^2 - x3
    mod_mul(t2, t5, t6);   // t5 * (x1*t3^2 - x3)
    mod_mul(p.y, t1, t1);  // y1 * t3^3
    mod_sub(t6, t1, r.y);
    mod_mul(p.z, t3, r.z); // z3 = z1 * t3
}

// Perkalian skalar: Q = k * G dengan k 128-bit (priv_hi, priv_lo)
__device__ void scalar_mult(unsigned long long k_hi, unsigned long long k_lo, Jacobian& Q) {
    Q.x[0]=Q.x[1]=Q.x[2]=Q.x[3]=0;
    Q.y[0]=Q.y[1]=Q.y[2]=Q.y[3]=0;
    Q.z[0]=Q.z[1]=Q.z[2]=Q.z[3]=0;
    Jacobian G;
    for (int i=0;i<4;i++) {
        G.x[i] = GX[i];
        G.y[i] = GY[i];
        G.z[i] = (i==0)?1:0;
    }
    for (int bit = 127; bit >= 0; bit--) {
        point_double(Q, Q);
        unsigned long long w = (bit >= 64) ? k_hi : k_lo;
        int b = (w >> (bit & 63)) & 1;
        if (b) {
            point_add_affine(Q, G, Q);
        }
    }
}
