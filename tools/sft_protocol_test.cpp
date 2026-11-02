// SFTR v2 协议解析单元测试：c++ -std=c++17 core/sft_protocol.cpp tools/sft_protocol_test.cpp && ./a.out
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#include "../core/sft_protocol.h"

using namespace nssft::sft;

static int g_failed = 0;
#define CHECK(cond)                                                    \
    do {                                                               \
        if (!(cond)) {                                                 \
            std::printf("  ✗ %s:%d  %s\n", __FILE__, __LINE__, #cond); \
            ++g_failed;                                                \
        }                                                              \
    } while (0)

static Header Video(uint32_t w, uint32_t h, uint32_t len, bool key = false) {
    Header x;
    x.magic = kMagic;
    x.version = kVersion;
    x.flags = uint16_t(kFlagVideo | (key ? kFlagKey : 0));
    x.width = w;
    x.height = h;
    x.length = len;
    return x;
}

static void TestHeaderRoundTrip() {
    Header h = Video(1920, 1080, 123456, true);
    h.input = true;
    h.ageUs = 34000;
    h.crop = (1600u << 16) | 900u;
    h.sequence = 0xFFFFFFFE;
    uint8_t buf[kHeaderSize];
    WriteHeader(h, buf);
    CHECK(std::memcmp(buf, "SFTR", 4) == 0);  // magic 的字节序列
    CHECK(buf[6] == (kFlagVideo | kFlagKey | kFlagInput));
    const Header r = ParseHeader(buf);
    CHECK(r.magic == kMagic && r.version == 2);
    CHECK(r.flags == (kFlagVideo | kFlagKey));  // kFlagInput 单独拿出来
    CHECK(r.input);
    CHECK(r.width == 1920 && r.height == 1080 && r.length == 123456);
    CHECK(r.ageUs == 34000 && r.crop == ((1600u << 16) | 900u) && r.sequence == 0xFFFFFFFE);
}

static void TestClassify() {
    CHECK(Classify(Video(1920, 1080, 1000, true)) == PacketKind::Video);
    CHECK(Classify(Video(1280, 720, 1000)) == PacketKind::Video);
    CHECK(Classify(Video(1920, 1088, 1000)) == PacketKind::Video);  // NVENC 按整宏块编 1088
    CHECK(Classify(Video(1922, 1080, 1000)) == PacketKind::Invalid);
    CHECK(Classify(Video(1920, 1090, 1000)) == PacketKind::Invalid);
    CHECK(Classify(Video(1281, 720, 1000)) == PacketKind::Invalid);  // 奇数宽
    CHECK(Classify(Video(1920, 1080, 0)) == PacketKind::Invalid);
    CHECK(Classify(Video(1920, 1080, kMaxVideoBytes + 1)) == PacketKind::Invalid);

    Header bad = Video(1280, 720, 10);
    bad.magic = 0x12345678;
    CHECK(Classify(bad) == PacketKind::Invalid);
    bad = Video(1280, 720, 10);
    bad.version = 1;
    CHECK(Classify(bad) == PacketKind::Invalid);

    Header empty;
    empty.magic = kMagic;
    empty.version = kVersion;
    CHECK(Classify(empty) == PacketKind::Empty);

    Header audio;
    audio.magic = kMagic;
    audio.version = kVersion;
    audio.flags = kFlagAudio;
    audio.width = 48000;
    audio.height = 2;
    audio.length = 4096;
    CHECK(Classify(audio) == PacketKind::Audio);
    audio.length = 4098;  // 不是整数个立体声采样
    CHECK(Classify(audio) == PacketKind::Invalid);
    audio.length = 4096;
    audio.width = 44100;
    CHECK(Classify(audio) == PacketKind::Invalid);

    Header status;
    status.magic = kMagic;
    status.version = kVersion;
    status.flags = kFlagAudio | kFlagStatus;
    status.length = 192;
    CHECK(Classify(status) == PacketKind::Status);
    status.length = 4;
    CHECK(Classify(status) == PacketKind::Invalid);
    status.length = 192;
    status.flags = kFlagStatus;  // 状态包必须同时带 AUDIO（老客户端会当音频丢掉）
    CHECK(Classify(status) == PacketKind::Invalid);

    // 旧版的原始画面格式（flags 1 或 0 但有负载）不支持
    Header raw = Video(768, 432, 1000);
    raw.flags = 1;
    CHECK(Classify(raw) == PacketKind::Invalid);
    raw.flags = 0;
    CHECK(Classify(raw) == PacketKind::Invalid);
    // 不认识的标志位
    Header future = Video(1280, 720, 100);
    future.flags |= 0x200;
    CHECK(Classify(future) == PacketKind::Invalid);
}

static void TestStatus() {
    uint8_t buf[192] = {};
    buf[0] = 1;
    buf[4] = 3;
    std::memcpy(buf + 8, "No game on screen", 17);
    std::memcpy(buf + 72, "Start a game", 12);
    ConsoleStatus s;
    CHECK(ParseStatus(buf, sizeof(buf), &s));
    CHECK(s.version == 1 && s.reason == 3);
    CHECK(s.head == "No game on screen");
    CHECK(s.detail == "Start a game");
    // 标题写满 64 字节没有结尾 0：截在 64
    std::memset(buf + 8, 'A', 64);
    CHECK(ParseStatus(buf, sizeof(buf), &s));
    CHECK(s.head.size() == 64);
    // 只有 8 字节：没有文字
    CHECK(ParseStatus(buf, 8, &s));
    CHECK(s.head.empty() && s.detail.empty());
    CHECK(!ParseStatus(buf, 7, &s));
}

static void TestBeacon() {
    Beacon b;
    const char* msg = "SFTAP1 192.168.1.50 9950 Switch Frame Tap 0.7.20";
    CHECK(ParseBeacon(reinterpret_cast<const uint8_t*>(msg), std::strlen(msg), &b));
    CHECK(b.ip == "192.168.1.50" && b.port == 9950);
    CHECK(b.name == "Switch Frame Tap 0.7.20");

    const char* bare = "SFTAP1 10.0.0.2 9950";
    CHECK(ParseBeacon(reinterpret_cast<const uint8_t*>(bare), std::strlen(bare), &b));
    CHECK(b.ip == "10.0.0.2" && b.name.empty());

    const char* padded = "  SFTAP1\t10.0.0.3  9950  name  \n";
    CHECK(ParseBeacon(reinterpret_cast<const uint8_t*>(padded), std::strlen(padded), &b));
    CHECK(b.ip == "10.0.0.3" && b.name == "name");

    for (const char* bad : {"SFTAP2 10.0.0.2 9950", "SFTAP1 10.0.0 9950", "SFTAP1 10.0.0.256 9950",
                            "SFTAP1 10.0.0.2", "SFTAP1 10.0.0.2 99x0", "SFTAP1 10.0.0.2 70000", "", "hello"}) {
        CHECK(!ParseBeacon(reinterpret_cast<const uint8_t*>(bad), std::strlen(bad), &b));
    }

    CHECK(IsIPv4("0.0.0.0") && IsIPv4("255.255.255.255"));
    CHECK(!IsIPv4("1.2.3") && !IsIPv4("1.2.3.4.5") && !IsIPv4("1..2.3") && !IsIPv4("1.2.3.") && !IsIPv4("1234.1.1.1"));
}

int main() {
    TestHeaderRoundTrip();
    TestClassify();
    TestStatus();
    TestBeacon();
    if (g_failed) {
        std::printf("sft_protocol_test: %d 项失败\n", g_failed);
        return 1;
    }
    std::printf("sft_protocol_test: 全部通过\n");
    return 0;
}
