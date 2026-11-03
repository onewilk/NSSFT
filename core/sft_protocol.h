// Switch Frame Tap（SFT，https://github.com/TomasUribe/switch-frame-tap）的串流协议 SFTR v2。
//
// 游戏机端（sysmodule）在 TCP 9950 上只接受一个客户端；没有客户端连着时，每秒在 UDP 9951 上广播
// "SFTAP1 <ip> 9950 <名称>"。连上后游戏机只管往下发包，每个包是 32 字节小端包头 + length 字节负载：
//
//   偏移  类型  字段
//    0    u32   magic = "SFTR"
//    4    u16   version = 2
//    6    u16   flags（见 Flag）
//    8    u32   宽（音频包为采样率 48000）
//   12    u32   高（音频包为声道数 2）
//   16    u32   这一帧在游戏机上已经过去的时间（微秒，从游戏交出画面到发出）
//   20    u32   length：负载字节数
//   24    u32   带 kFlagCrop 时：游戏实际画出的区域（w << 16 | h）
//   28    u32   序号（视频、音频各自递增）
//
// 负载：视频是一帧 H.264 Annex-B（关键帧带 SPS/PPS）；音频是 48 kHz 立体声 16 位 PCM；
// 状态包（kFlagAudio | kFlagStatus，采样率 0）说明游戏机为什么没有画面。
// 客户端可以随时往同一条连接上写请求，例如 "SFTK"（马上发一个关键帧）。
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace nssft::sft {

constexpr uint16_t kStreamPort = 9950;
constexpr uint16_t kBeaconPort = 9951;
constexpr uint32_t kMagic = 0x52544653;  // 字节序列 "SFTR"
constexpr uint16_t kVersion = 2;
constexpr size_t kHeaderSize = 32;

enum Flag : uint16_t {
    kFlagVideo = 2,
    kFlagKey = 4,       // 关键帧（IDR）
    kFlagAudio = 8,
    kFlagStatus = 16,   // 与 kFlagAudio 一起出现：没有画面的原因
    kFlagCrop = 32,     // 只发给声明了 "SFTC" 的客户端；NSSFT 不声明，游戏机自己裁好
    kFlagCropMid = 64,
    kFlagInput = 128,   // 游戏机接受客户端的手柄输入（除普通音频外每个包头都带）
};

constexpr uint32_t kMaxVideoBytes = 8u << 20;
constexpr uint32_t kMaxAudioBytes = 65536;
constexpr uint32_t kMaxStatusBytes = 4096;
constexpr uint32_t kMaxWidth = 1920;
constexpr uint32_t kMaxHeight = 1088;
constexpr int kAudioSampleRate = 48000;
constexpr int kAudioChannels = 2;

struct Header {
    uint32_t magic = 0;
    uint16_t version = 0;
    uint16_t flags = 0;  // 已去掉 kFlagInput
    bool input = false;  // 原始 flags 里的 kFlagInput
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t ageUs = 0;
    uint32_t length = 0;
    uint32_t crop = 0;
    uint32_t sequence = 0;
};

Header ParseHeader(const uint8_t* p);
// 测试和模拟服务端用；input 为真时写回 kFlagInput
void WriteHeader(const Header& h, uint8_t* out);

enum class PacketKind {
    Empty,    // 没有负载的空包头：游戏机在 USB 上探测客户端还在不在，跳过即可
    Video,
    Audio,
    Status,
    Invalid,  // 格式不对：要么失步了，要么是本客户端不认识的流格式
};

// 按 SFT 客户端的规则检查包头；Invalid 时 why 写原因（开发日志用）
PacketKind Classify(const Header& h, std::string* why = nullptr);

// 状态包负载：u32 版本、u32 原因（0 表示没问题）、标题 char[64]、说明 char[120]
struct ConsoleStatus {
    uint32_t version = 0;
    uint32_t reason = 0;
    std::string head;
    std::string detail;
};
bool ParseStatus(const uint8_t* p, size_t n, ConsoleStatus* out);

// UDP 9951 广播："SFTAP1 <ip> <port> <名称…>"。地址以 UDP 的来源地址为准，不信广播里写的
struct Beacon {
    std::string ip;
    uint16_t port = 0;
    std::string name;
};
bool ParseBeacon(const uint8_t* p, size_t n, Beacon* out);

// 客户端请求（直接写到同一条 TCP 连接上，游戏机按 4 字节一组读）
constexpr char kRequestKeyframe[4] = {'S', 'F', 'T', 'K'};
// 录制时请游戏机保持一种画面尺寸（尺寸不同的画面由游戏机缩放），录像就不用中途换文件；录完解锁。
// SFT 0.7.18 起支持；前 4 字节就是 SFTK，更早的版本只当作一次关键帧请求
constexpr char kRequestRecordLock[8] = {'S', 'F', 'T', 'K', 'S', 'F', 'T', 'L'};
constexpr char kRequestRecordUnlock[8] = {'S', 'F', 'T', 'K', 'S', 'F', 'T', 'U'};

bool IsIPv4(const std::string& s);

}  // namespace nssft::sft
