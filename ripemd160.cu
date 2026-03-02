#include "types.h"
#include <cuda_runtime.h>

__constant__ uint32_t K_rmd[5] = { 0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E };
__constant__ uint32_t Kp_rmd[5] = { 0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000 };
__constant__ int RL_rmd[5][16] = {
    { 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 },
    { 7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8 },
    { 3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12 },
    { 1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2 },
    { 4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13 }
};
__constant__ int RR_rmd[5][16] = {
    { 5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12 },
    { 6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2 },
    { 15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13 },
    { 8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14 },
    { 12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11 }
};
__constant__ int RL2_rmd[5][16] = {
    { 11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8 },
    { 7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12 },
    { 11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5 },
    { 11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12 },
    { 9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6 }
};
__constant__ int RR2_rmd[5][16] = {
    { 8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6 },
    { 9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11 },
    { 9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5 },
    { 15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8 },
    { 8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11 }
};

__device__ uint32_t rol_rmd(uint32_t x, int n) {
    return (x << n) | (x >> (32 - n));
}

__device__ void ripemd160(const uint8_t* input, uint32_t len, uint8_t* output) {
    uint32_t h[5] = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 };
    uint8_t block[64];
    for (uint32_t i = 0; i < len; i++) block[i] = input[i];
    block[len] = 0x80;
    for (uint32_t i = len+1; i < 56; i++) block[i] = 0;
    uint64_t bits = len * 8;
    for (int i = 0; i < 8; i++) block[56 + i] = (bits >> (56 - i*8)) & 0xff;

    uint32_t x[16];
    for (int i = 0; i < 16; i++) {
        x[i] = (block[i*4] << 24) | (block[i*4+1] << 16) | (block[i*4+2] << 8) | block[i*4+3];
    }

    uint32_t A = h[0], B = h[1], C = h[2], D = h[3], E = h[4];
    uint32_t Ap = h[0], Bp = h[1], Cp = h[2], Dp = h[3], Ep = h[4];

    for (int j = 0; j < 80; j++) {
        int round = j / 16;
        int idx = j % 16;
        uint32_t f, fp;
        if (j < 16) {
            f = B ^ C ^ D;
            fp = Bp ^ Cp ^ Dp;
        } else if (j < 32) {
            f = (B & C) | (~B & D);
            fp = (Bp & Cp) | (~Bp & Dp);
        } else if (j < 48) {
            f = (B | ~C) ^ D;
            fp = (Bp | ~Cp) ^ Dp;
        } else if (j < 64) {
            f = (B & D) | (C & ~D);
            fp = (Bp & Dp) | (Cp & ~Dp);
        } else {
            f = B ^ (C | ~D);
            fp = Bp ^ (Cp | ~Dp);
        }
        uint32_t T = rol_rmd(A + f + x[RL_rmd[round][idx]] + K_rmd[round], RL2_rmd[round][idx]);
        uint32_t Tp = rol_rmd(Ap + fp + x[RR_rmd[round][idx]] + Kp_rmd[round], RR2_rmd[round][idx]);

        A = E; E = D; D = rol_rmd(C, 10); C = B; B = T;
        Ap = Ep; Ep = Dp; Dp = rol_rmd(Cp, 10); Cp = Bp; Bp = Tp;
    }

    uint32_t T2 = h[1] + C + Dp;
    h[1] = h[2] + D + Ep;
    h[2] = h[3] + E + Ap;
    h[3] = h[4] + A + Bp;
    h[4] = h[0] + B + Cp;
    h[0] = T2;

    for (int i = 0; i < 5; i++) {
        output[i*4] = (h[i] >> 24) & 0xff;
        output[i*4+1] = (h[i] >> 16) & 0xff;
        output[i*4+2] = (h[i] >> 8) & 0xff;
        output[i*4+3] = h[i] & 0xff;
    }
}
