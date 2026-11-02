#include "sft_protocol.h"

#include <algorithm>
#include <cstring>
#include <vector>

namespace nssft::sft {

namespace {

uint32_t U32(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
uint16_t U16(const uint8_t* p) { return uint16_t(p[0] | p[1] << 8); }

void Put32(uint8_t* p, uint32_t v) {
    p[0] = uint8_t(v);
    p[1] = uint8_t(v >> 8);
    p[2] = uint8_t(v >> 16);
    p[3] = uint8_t(v >> 24);
}

void Put16(uint8_t* p, uint16_t v) {
    p[0] = uint8_t(v);
    p[1] = uint8_t(v >> 8);
}

std::string CString(const uint8_t* p, size_t max) {
    size_t n = 0;
    while (n < max && p[n] != 0) ++n;
    return std::string(reinterpret_cast<const char*>(p), n);
}

constexpr uint16_t kKnownFlags = kFlagVideo | kFlagKey | kFlagAudio | kFlagStatus | kFlagCrop | kFlagCropMid;

}  // namespace

Header ParseHeader(const uint8_t* p) {
    Header h;
    h.magic = U32(p);
    h.version = U16(p + 4);
    const uint16_t raw = U16(p + 6);
    h.input = (raw & kFlagInput) != 0;
    h.flags = uint16_t(raw & ~kFlagInput);
    h.width = U32(p + 8);
    h.height = U32(p + 12);
    h.ageUs = U32(p + 16);
    h.length = U32(p + 20);
    h.crop = U32(p + 24);
    h.sequence = U32(p + 28);
    return h;
}

void WriteHeader(const Header& h, uint8_t* out) {
    Put32(out, h.magic);
    Put16(out + 4, h.version);
    Put16(out + 6, uint16_t(h.flags | (h.input ? kFlagInput : 0)));
    Put32(out + 8, h.width);
    Put32(out + 12, h.height);
    Put32(out + 16, h.ageUs);
    Put32(out + 20, h.length);
    Put32(out + 24, h.crop);
    Put32(out + 28, h.sequence);
}

PacketKind Classify(const Header& h, std::string* why) {
    auto bad = [why](const char* reason) {
        if (why) *why = reason;
        return PacketKind::Invalid;
    };
    if (h.magic != kMagic) return bad("包头 magic 不对");
    if (h.version != kVersion) return bad("不是 SFTR v2");
    if (h.flags == 0 && h.length == 0) return PacketKind::Empty;
    if ((h.flags & ~kKnownFlags) != 0) return bad("不认识的流格式标志");

    if (h.flags & kFlagStatus) {
        if (h.flags != (kFlagAudio | kFlagStatus) || h.length < 8 || h.length > kMaxStatusBytes) return bad("状态包格式不对");
        return PacketKind::Status;
    }
    if (h.flags & kFlagAudio) {
        if (h.flags != kFlagAudio || h.width != uint32_t(kAudioSampleRate) || h.height != uint32_t(kAudioChannels) ||
            h.length == 0 || h.length > kMaxAudioBytes || h.length % 4 != 0)
            return bad("音频包不是 48 kHz 立体声 16 位 PCM");
        return PacketKind::Audio;
    }
    if ((h.flags & kFlagVideo) == 0) return bad("既不是视频也不是音频（旧版的原始画面格式）");
    if (h.width < 16 || h.width > kMaxWidth || h.height < 16 || h.height > kMaxHeight || h.width % 2 != 0 ||
        h.height % 2 != 0)
        return bad("视频尺寸超出范围");
    if (h.length == 0 || h.length > kMaxVideoBytes) return bad("视频包大小超出范围");
    return PacketKind::Video;
}

bool ParseStatus(const uint8_t* p, size_t n, ConsoleStatus* out) {
    if (n < 8) return false;
    out->version = U32(p);
    out->reason = U32(p + 4);
    out->head = n > 8 ? CString(p + 8, std::min<size_t>(64, n - 8)) : std::string();
    out->detail = n > 72 ? CString(p + 72, std::min<size_t>(120, n - 72)) : std::string();
    return true;
}

bool IsIPv4(const std::string& s) {
    int parts = 0;
    size_t i = 0;
    while (i <= s.size()) {
        size_t j = i;
        int value = 0;
        while (j < s.size() && s[j] >= '0' && s[j] <= '9' && j - i < 3) value = value * 10 + (s[j++] - '0');
        if (j == i || value > 255) return false;
        ++parts;
        if (j == s.size()) break;
        if (s[j] != '.') return false;
        i = j + 1;
    }
    return parts == 4;
}

bool ParseBeacon(const uint8_t* p, size_t n, Beacon* out) {
    // 按空白切成 "SFTAP1"、ip、端口、名称（名称可以带空格，取剩下的全部）
    std::string text(reinterpret_cast<const char*>(p), n);
    std::vector<std::string> fields;
    size_t i = 0;
    while (i < text.size() && fields.size() < 3) {
        while (i < text.size() && (text[i] == ' ' || text[i] == '\t' || text[i] == '\r' || text[i] == '\n')) ++i;
        size_t j = i;
        while (j < text.size() && text[j] != ' ' && text[j] != '\t' && text[j] != '\r' && text[j] != '\n') ++j;
        if (j > i) fields.push_back(text.substr(i, j - i));
        i = j;
    }
    if (fields.size() < 3 || fields[0] != "SFTAP1" || !IsIPv4(fields[1])) return false;
    int port = 0;
    for (char c : fields[2]) {
        if (c < '0' || c > '9' || port > 65535) return false;
        port = port * 10 + (c - '0');
    }
    if (port <= 0 || port > 65535) return false;
    std::string name = i < text.size() ? text.substr(i) : std::string();
    const size_t a = name.find_first_not_of(" \t\r\n");
    const size_t b = name.find_last_not_of(" \t\r\n\0", std::string::npos, 5);
    name = a == std::string::npos ? std::string() : name.substr(a, b - a + 1);
    out->ip = fields[1];
    out->port = uint16_t(port);
    out->name = name;
    return true;
}

}  // namespace nssft::sft
