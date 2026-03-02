#include <string>
#include <vector>
#include <cstdint>
#include <openssl/sha.h>

static const char* b58digits = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

std::string base58_encode(const uint8_t* data, size_t len) {
    int zeros = 0;
    while (zeros < len && data[zeros] == 0) zeros++;
    std::vector<uint8_t> b58((len - zeros) * 138 / 100 + 1, 0);
    for (int i = zeros; i < len; i++) {
        int carry = data[i];
        for (int j = b58.size() - 1; j >= 0; j--) {
            carry += 256 * b58[j];
            b58[j] = carry % 58;
            carry /= 58;
        }
    }
    int j = 0;
    while (j < b58.size() && b58[j] == 0) j++;
    std::string result;
    result.reserve(zeros + (b58.size() - j));
    result.append(zeros, '1');
    for (int i = j; i < b58.size(); i++) {
        result += b58digits[b58[i]];
    }
    return result;
}
