#include "types.h"
#include "secp256k1.cu"
#include "sha256.cu"
#include "ripemd160.cu"
#include <cuda_runtime.h>

// Fungsi untuk menghasilkan hash160 dari public key (x,y) dalam bentuk affine
__device__ void public_key_to_hash160(const uint256 x, const uint256 y, uint8_t* hash160) {
    uint8_t pubkey[33];
    pubkey[0] = (y[0] & 1) ? 0x03 : 0x02;
    for (int i = 0; i < 32; i++) {
        int word = 3 - i/8;
        int shift = 56 - 8*(i%8);
        pubkey[1 + i] = (x[word] >> shift) & 0xff;
    }
    uint8_t sha256_hash[32];
    sha256(pubkey, 33, sha256_hash);
    ripemd160(sha256_hash, 32, hash160);
}

// Kernel utama
__global__ void generate_kernel(
    unsigned long long start_hi, unsigned long long start_lo,
    unsigned long long end_hi, unsigned long long end_lo,
    Result* results, int batch_size,
    unsigned long long* counter) {

    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= batch_size) return;

    unsigned long long priv_hi, priv_lo;
    unsigned long long old_hi, old_lo, new_hi, new_lo;
    do {
        old_hi = counter[0];
        old_lo = counter[1];
        new_hi = old_hi;
        new_lo = old_lo + 1;
        if (new_lo == 0) new_hi++;
    } while ( (old_hi != atomicCAS(&counter[0], old_hi, new_hi)) ||
              (old_lo != atomicCAS(&counter[1], old_lo, new_lo)) );
    priv_hi = old_hi;
    priv_lo = old_lo;

    if (priv_hi > end_hi || (priv_hi == end_hi && priv_lo > end_lo)) {
        results[idx].priv_hi = 0;
        results[idx].priv_lo = 0;
        return;
    }

    Jacobian Q;
    scalar_mult(priv_hi, priv_lo, Q);

    uint256 z_inv;
    mod_inv(Q.z, z_inv);
    uint256 x, y;
    uint256 z_inv2;
    mod_mul(z_inv, z_inv, z_inv2);
    mod_mul(Q.x, z_inv2, x);
    mod_mul(z_inv2, z_inv, z_inv2);
    mod_mul(Q.y, z_inv2, y);

    public_key_to_hash160(x, y, results[idx].hash160);
    results[idx].priv_hi = priv_hi;
    results[idx].priv_lo = priv_lo;
}

extern "C" void run_gpu_kernel(
    unsigned long long start_hi, unsigned long long start_lo,
    unsigned long long end_hi, unsigned long long end_lo,
    Result* d_results, int batch_size,
    unsigned long long* d_counter, cudaStream_t stream) {
    int threads = 256;
    int blocks = (batch_size + threads - 1) / threads;
    generate_kernel<<<blocks, threads, 0, stream>>>(
        start_hi, start_lo, end_hi, end_lo, d_results, batch_size, d_counter);
}
