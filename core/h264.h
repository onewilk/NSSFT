// H.264 Annex-B 字节流的小工具（与具体串流协议无关）
#pragma once

#include <cstddef>
#include <cstdint>

namespace nssft {

constexpr int kNalIdr = 5;
constexpr int kNalSps = 7;
constexpr int kNalPps = 8;

// 字节流里是否有某种类型的 NAL
bool ContainsNalType(const uint8_t* p, size_t n, int nalType);

// 逐个回调 Annex-B 字节流里的 NAL：fn(含起始码的 NAL 指针, 长度, nal_unit_type)
template <typename Fn>
void ForEachNal(const uint8_t* p, size_t n, Fn&& fn) {
    size_t nalStart = n;  // n 表示“还没遇到第一个起始码”
    size_t header = 0;
    size_t i = 0;
    while (i + 3 <= n) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
            const size_t startCode = (i > 0 && p[i - 1] == 0) ? i - 1 : i;  // 兼容 4 字节起始码
            if (nalStart < n) fn(p + nalStart, startCode - nalStart, p[header] & 0x1F);
            nalStart = startCode;
            header = i + 3;
            i += 3;
        } else {
            ++i;
        }
    }
    if (nalStart < n && header < n) fn(p + nalStart, n - nalStart, p[header] & 0x1F);
}

}  // namespace nssft
