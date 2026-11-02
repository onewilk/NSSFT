#include "gop_cache.h"

#include "h264.h"

namespace nssft {

void GopCache::Push(const uint8_t* data, size_t size, uint64_t timestampUs) {
    bool isIdr = false;
    ForEachNal(data, size, [&](const uint8_t* nal, size_t len, int type) {
        if (type == 7) sps_.assign(nal, nal + len);
        else if (type == 8) pps_.assign(nal, nal + len);
        else if (type == 5) isIdr = true;
    });

    if (isIdr) {
        packets_.clear();
        bytes_ = 0;
    } else if (packets_.empty()) {
        return;  // 还没有关键帧，P 帧无法单独解码，不缓存
    }

    packets_.push_back({std::vector<uint8_t>(data, data + size), timestampUs});
    bytes_ += size;
    if (bytes_ > maxBytes_ || packets_.size() > maxPackets_) Clear();
}

void GopCache::Clear() {
    packets_.clear();
    bytes_ = 0;
}

std::vector<uint8_t> GopCache::ParamSets() const {
    if (sps_.empty() || pps_.empty()) return {};
    std::vector<uint8_t> out(sps_);
    out.insert(out.end(), pps_.begin(), pps_.end());
    return out;
}

std::vector<CachedPacket> GopCache::Snapshot() const {
    std::vector<CachedPacket> out(packets_.begin(), packets_.end());
    if (out.empty()) return out;

    auto& first = out.front().data;
    if (!ContainsNalType(first.data(), first.size(), kNalSps)) {
        // SFT 的关键帧都自带 SPS/PPS；万一没有，就用最近见过的（从没见过就原样交出去）
        const std::vector<uint8_t> prefix = ParamSets();
        first.insert(first.begin(), prefix.begin(), prefix.end());
    }
    return out;
}

}  // namespace nssft
