#include "h264.h"

namespace nssft {

bool ContainsNalType(const uint8_t* p, size_t n, int nalType) {
    // 查找 00 00 01 起始码（00 00 00 01 也会被匹配到）
    for (size_t i = 0; i + 3 < n; ++i) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
            if ((p[i + 3] & 0x1F) == nalType) return true;
            i += 2;
        }
    }
    return false;
}

}  // namespace nssft
