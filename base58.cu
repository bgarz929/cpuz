#include "types.h"
#include <string>
#include <vector>

static const char* b58digits = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

// Encode 25-byte (version + hash160 + checksum) ke Base58Check
std::string base58_encode(const uint8_t* data, size_t len) {
    // Hitung angka nol di awal
    int zeros = 0;
    while (zeros < len && data[zeros] == 0) zeros++;
    // Konversi ke basis 58
    std::vector<uint8_t> b58((len - zeros) * 138 / 100 + 1, 0);
    for (int i = zeros; i < len; i++) {
        int carry = data[i];
        for (int j = b58.size() - 1; j >= 0; j--) {
            carry += 256 * b58[j];
            b58[j] = carry % 58;
            carry /= 58;
        }
    }
    // Abaikan leading zeros di b58
    int j = 0;
    while (j < b58.size() && b58[j] == 0) j++;
    // Hasil: '1' sebanyak zeros + digit
    std::string result;
    result.reserve(zeros + (b58.size() - j));
    result.append(zeros, '1');
    for (int i = j; i < b58.size(); i++) {
        result += b58digits[b58[i]];
    }
    return result;
}
