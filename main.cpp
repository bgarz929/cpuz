#include <iostream>
#include <iomanip>
#include <sstream>
#include <cuda_runtime.h>
#include <sqlite3.h>
#include <vector>
#include "types.h"
#include "base58.cpp"  // pastikan base58.cpp sudah berisi fungsi hash160_to_address

extern "C" void run_gpu_kernel(
    unsigned long long start_hi, unsigned long long start_lo,
    unsigned long long end_hi, unsigned long long end_lo,
    Result* d_results, int batch_size,
    unsigned long long* d_counter, cudaStream_t stream);

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
        std::string addr = hash160_to_address(res.hash160);
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
