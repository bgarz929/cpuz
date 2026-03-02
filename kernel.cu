#include "types.h"
#include "secp256k1.cu"
#include <cuda_runtime.h>

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

    // Simpan private key dan public key
    results[idx].priv_hi = priv_hi;
    results[idx].priv_lo = priv_lo;
    for (int i = 0; i < 4; i++) {
        results[idx].x[i] = x[i];
        results[idx].y[i] = y[i];
    }
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
