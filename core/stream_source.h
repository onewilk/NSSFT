// 串流来源的公共接口：现在只有 SFT 网络（TCP 9950），以后的 USB 也实现这个接口。
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "frame_loss.h"

namespace nssft {

struct SourceStats {
    bool connected = false;
    uint64_t videoPackets = 0;
    uint64_t videoBytes = 0;
    uint64_t keyframes = 0;
    uint64_t audioPackets = 0;
    uint64_t audioBytes = 0;
    uint64_t statusPackets = 0;
    uint64_t keyRequests = 0;   // 发出的 SFTK
    uint64_t sequenceGaps = 0;  // 序号断档次数
    uint64_t lostFrames = 0;    // 断档里跳过的帧数
    uint64_t resyncs = 0;
    uint64_t reconnects = 0;
    uint32_t width = 0;  // 最近一帧视频的尺寸
    uint32_t height = 0;
    uint64_t ageTotalUs = 0;  // 游戏机端耗时（包头）的累计，算平均用
    uint64_t ageSamples = 0;
    bool consoleTakesInput = false;
    // 游戏机最近说明的“没有画面的原因”（reason 0 表示已恢复正常）
    uint32_t statusReason = 0;
    std::string statusHead;
    std::string statusDetail;
};

// 一帧视频；data 只在回调期间有效
struct VideoFrame {
    const uint8_t* data = nullptr;
    size_t size = 0;
    uint64_t timestampUs = 0;  // 本机时钟：收到的时刻减去游戏机端耗时
    uint32_t width = 0;
    uint32_t height = 0;
    bool key = false;
    uint32_t sequence = 0;
};

using VideoFn = std::function<void(const VideoFrame& frame)>;
using AudioFn = std::function<void(const uint8_t* pcm, size_t size)>;
using StatusFn = std::function<void(const std::string& message)>;
using LossFn = std::function<void(LossCause cause)>;

struct StreamCallbacks {
    VideoFn onVideo;
    AudioFn onAudio;    // 48 kHz 立体声 16 位 PCM
    StatusFn onStatus;  // 给用户看的连接状态
    // 发现视频数据丢失，与 onVideo 在同一个线程调用
    LossFn onVideoLoss;
};

// 一条已连接的 TCP 连接的地址（给系统网络加速标记数据流用）
struct SocketFlow {
    std::string localAddress;
    uint16_t localPort = 0;
    std::string remoteAddress;
    uint16_t remotePort = 0;
};

class StreamSource {
public:
    virtual ~StreamSource() = default;
    virtual void Start() = 0;
    // 阻塞到接收线程退出；返回后不会再有回调
    virtual void Stop() = 0;
    virtual SourceStats GetStats() const = 0;
    // SFT 的声音和画面在同一条连接上，关掉声音只是不再回调 onAudio（游戏机照常发）
    virtual void SetAudioEnabled(bool enabled) = 0;
    // 请游戏机马上发一个关键帧（丢帧后、解码器重建后）；同一时间只发一次，频率由实现限制
    virtual void RequestKeyframe() = 0;
    virtual void SetQuickAck(bool) {}
    // 录制中：请游戏机保持一种画面尺寸（断线重连后会自动再请求一次）；false 时解锁
    virtual void SetRecordSizeLock(bool) {}
    // 手柄（SFTI 消息，见 sft_pad.h）：任意线程调用，直接写到连接上；返回是否写出
    virtual bool SendInput(const uint8_t*, size_t) { return false; }
    // 游戏机现在接不接受手柄（游戏机上打开了 “Controls from the viewer”）
    virtual bool ConsoleTakesInput() const { return false; }
    virtual std::vector<SocketFlow> SocketFlows() const { return {}; }
};

}  // namespace nssft
