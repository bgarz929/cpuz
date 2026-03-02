#include <iostream>
#include <iomanip>
#include <sstream>
#include <cuda_runtime.h>
#include <sqlite3.h>
#include <vector>
#include <chrono>
#include <thread>
#include "types.h"

// Deklarasi fungsi kernel
extern "C" void run_gpu_kernel(
    uint64_t start_hi, uint64_t start_lo,
    uint64_t end_hi, uint64_t end_lo,
    Result* d_results, int batch_size,
    uint64_t* d_counter, cudaStream_t stream);

// Inisialisasi database
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

// Simpan batch ke database
void save_results(sqlite3* db, const std::vector<Result>& results) {
    sqlite3_exec(db, "BEGIN TRANSACTION;", nullptr, nullptr, nullptr);
    for (const auto& res : results) {
        std::stringstream ss;
        ss << std::hex << std::setfill('0')
           << std::setw(16) << res.priv_hi << std::setw(16) << res.priv_lo;
        std::string priv_hex = ss.str();
        std::string addr(res.address);
        std::string sql = "INSERT OR IGNORE INTO addresses (private_key_hex, address) VALUES ('" + priv_hex + "', '" + addr + "');";
        char* errMsg = nullptr;
        sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &errMsg);
        if (errMsg) sqlite3_free(errMsg);
    }
    sqlite3_exec(db, "COMMIT;", nullptr, nullptr, nullptr);
}

int main() {
    // Rentang: 0x400000000000000000 - 0x7FFFFFFFFFFFFFFFFF
    uint64_t start_hi = 0x40;
    uint64_t start_lo = 0x0;
    uint64_t end_hi = 0x7F;
    uint64_t end_lo = 0xFFFFFFFFFFFFFFFF;

    // Inisialisasi database
    sqlite3* db = init_db("btc_addresses.db");
    if (!db) return 1;

    // Parameter batch
    const int BATCH_SIZE = 100000; // Sesuaikan dengan memori GPU
    Result* h_results = new Result[BATCH_SIZE];
    Result* d_results;
    cudaMalloc(&d_results, BATCH_SIZE * sizeof(Result));

    // Counter global di GPU (128-bit)
    uint64_t* d_counter;
    cudaMalloc(&d_counter, 2 * sizeof(uint64_t));
    uint64_t h_counter[2] = {start_hi, start_lo};
    cudaMemcpy(d_counter, h_counter, 2 * sizeof(uint64_t), cudaMemcpyHostToDevice);

    // Buat stream CUDA
    cudaStream_t stream;
    cudaStreamCreate(&stream);

    uint64_t total_generated = 0;
    while (true) {
        // Jalankan kernel
        run_gpu_kernel(start_hi, start_lo, end_hi, end_lo, d_results, BATCH_SIZE, d_counter, stream);

        // Tunggu selesai
        cudaStreamSynchronize(stream);

        // Salin hasil
        cudaMemcpy(h_results, d_results, BATCH_SIZE * sizeof(Result), cudaMemcpyDeviceToHost);

        // Hitung jumlah valid
        int valid_count = 0;
        for (int i = 0; i < BATCH_SIZE; i++) {
            if (h_results[i].priv_hi == 0 && h_results[i].priv_lo == 0) break;
            valid_count++;
        }
        if (valid_count == 0) break;

        // Simpan
        std::vector<Result> batch(h_results, h_results + valid_count);
        save_results(db, batch);
        total_generated += valid_count;
        std::cout << "Generated " << total_generated << " addresses so far..." << std::endl;

        if (valid_count < BATCH_SIZE) break; // Rentang habis
    }

    cudaFree(d_results);
    cudaFree(d_counter);
    cudaStreamDestroy(stream);
    sqlite3_close(db);
    delete[] h_results;

    std::cout << "Done. Total addresses generated: " << total_generated << std::endl;
    return 0;
}
