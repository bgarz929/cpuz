#include <iostream>
#include <iomanip>
#include <sstream>
#include <cstring>          // untuk memcpy
#include <cuda_runtime.h>
#include <sqlite3.h>
#include <vector>
#include <openssl/sha.h>
#include <openssl/ripemd.h>
#include "types.h"
#include "base58.cpp"

extern "C" void run_gpu_kernel(
    unsigned long long start_hi, unsigned long long start_lo,
    unsigned long long end_hi, unsigned long long end_lo,
    Result* d_results, int batch_size,
    unsigned long long* d_counter, cudaStream_t stream);

// Konversi uint256 little-endian ke big-endian 32-byte
void uint256_to_be(const uint64_t* le, uint8_t* be) {
    for (int i = 0; i < 4; i++) {
        uint64_t val = le[3 - i]; // ambil dari MSB
        for (int j = 0; j < 8; j++) {
            be[i*8 + j] = (val >> (56 - 8*j)) & 0xff;
        }
    }
}

// Menghasilkan alamat Bitcoin dari public key (x,y) dalam little-endian
std::string public_key_to_address(const uint64_t* x_le, const uint64_t* y_le) {
    uint8_t x_be[32], y_be[32];
    uint256_to_be(x_le, x_be);
    uint256_to_be(y_le, y_be);

    // Compressed public key
    uint8_t pubkey[33];
    pubkey[0] = (y_le[0] & 1) ? 0x03 : 0x02; // bit terendah y (LSB) menentukan ganjil/genap
    memcpy(pubkey + 1, x_be, 32);

    // SHA-256
    uint8_t sha256_hash[SHA256_DIGEST_LENGTH];
    SHA256(pubkey, 33, sha256_hash);

    // RIPEMD-160 (deprecated di OpenSSL 3.0, tetapi masih berfungsi)
    uint8_t ripe_hash[20];
    RIPEMD160(sha256_hash, SHA256_DIGEST_LENGTH, ripe_hash);

    // Tambahkan versi byte (0x00 untuk mainnet)
    uint8_t address_with_checksum[25];
    address_with_checksum[0] = 0x00;
    memcpy(address_with_checksum + 1, ripe_hash, 20);

    // Double SHA-256 untuk checksum
    uint8_t hash1[SHA256_DIGEST_LENGTH];
    uint8_t hash2[SHA256_DIGEST_LENGTH];
    SHA256(address_with_checksum, 21, hash1);
    SHA256(hash1, SHA256_DIGEST_LENGTH, hash2);
    memcpy(address_with_checksum + 21, hash2, 4);

    // Base58 encoding
    return base58_encode(address_with_checksum, 25);
}

sqlite3* init_db(const char* dbname) {
    sqlite3* db;
    int rc = sqlite3_open(dbname, &db);
    if (rc) {
        std::cerr << "Can't open database: " << sqlite3_errmsg(db) << std::endl;
        return nullptr;
    }
    const char* sql = "CREATE TABLE IF NOT EXISTS addresses ("
                      "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                      "private_key_hex TEXT UNIQUE,"
                      "address TEXT);";
    char* errMsg = nullptr;
    rc = sqlite3_exec(db, sql, nullptr, nullptr, &errMsg);
    if (rc != SQLITE_OK) {
        std::cerr << "SQL error: " << errMsg << std::endl;
        sqlite3_free(errMsg);
    }
    return db;
}

void save_results(sqlite3* db, const std::vector<Result>& results) {
    sqlite3_exec(db, "BEGIN TRANSACTION;", nullptr, nullptr, nullptr);
    for (const auto& res : results) {
        std::stringstream ss;
        ss << std::hex << std::setfill('0')
           << std::setw(16) << res.priv_hi << std::setw(16) << res.priv_lo;
        std::string priv_hex = ss.str();
        std::string addr = public_key_to_address(res.x, res.y);
        std::string sql = "INSERT OR IGNORE INTO addresses (private_key_hex, address) VALUES ('" + priv_hex + "', '" + addr + "');";
        char* errMsg = nullptr;
        sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &errMsg);
        if (errMsg) sqlite3_free(errMsg);
    }
    sqlite3_exec(db, "COMMIT;", nullptr, nullptr, nullptr);
}

int main() {
    unsigned long long start_hi = 0x40;
    unsigned long long start_lo = 0x0;
    unsigned long long end_hi = 0x7F;
    unsigned long long end_lo = 0xFFFFFFFFFFFFFFFF;

    sqlite3* db = init_db("btc_addresses.db");
    if (!db) return 1;

    const int BATCH_SIZE = 100000;  // Sesuaikan dengan memori GPU
    Result* h_results = new Result[BATCH_SIZE];
    Result* d_results;
    cudaMalloc(&d_results, BATCH_SIZE * sizeof(Result));

    unsigned long long* d_counter;
    cudaMalloc(&d_counter, 2 * sizeof(unsigned long long));
    unsigned long long h_counter[2] = {start_hi, start_lo};
    cudaMemcpy(d_counter, h_counter, 2 * sizeof(unsigned long long), cudaMemcpyHostToDevice);

    cudaStream_t stream;
    cudaStreamCreate(&stream);

    unsigned long long total_generated = 0;
    bool first = true;
    while (true) {
        run_gpu_kernel(start_hi, start_lo, end_hi, end_lo, d_results, BATCH_SIZE, d_counter, stream);
        cudaStreamSynchronize(stream);
        cudaMemcpy(h_results, d_results, BATCH_SIZE * sizeof(Result), cudaMemcpyDeviceToHost);

        int valid_count = 0;
        for (int i = 0; i < BATCH_SIZE; i++) {
            if (h_results[i].priv_hi == 0 && h_results[i].priv_lo == 0) break;
            valid_count++;
        }
        if (valid_count == 0) break;

        // Debug untuk private key pertama
        if (first && valid_count > 0) {
            first = false;
            std::cout << "=== DEBUG: First private key ===" << std::endl;
            std::cout << "Private key (hi, lo): 0x" << std::hex << h_results[0].priv_hi << ", 0x" << h_results[0].priv_lo << std::dec << std::endl;
            std::cout << "Public key x (big-endian): ";
            for (int i = 0; i < 4; i++) printf("%016llx", h_results[0].x[3 - i]);
            std::cout << std::endl;
            std::cout << "Public key y (big-endian): ";
            for (int i = 0; i < 4; i++) printf("%016llx", h_results[0].y[3 - i]);
            std::cout << std::endl;
            std::cout << "================================" << std::endl;
        }

        std::vector<Result> batch(h_results, h_results + valid_count);
        save_results(db, batch);
        total_generated += valid_count;
        std::cout << "Generated " << total_generated << " addresses so far..." << std::endl;

        if (valid_count < BATCH_SIZE) break;  // Rentang selesai
    }

    cudaFree(d_results);
    cudaFree(d_counter);
    cudaStreamDestroy(stream);
    sqlite3_close(db);
    delete[] h_results;

    std::cout << "Done. Total addresses generated: " << total_generated << std::endl;
    return 0;
}
