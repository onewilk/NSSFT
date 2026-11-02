// H.264 硬件解码（AVCodec，Surface 模式）：解码结果直接渲染到 XComponent 的 NativeWindow。
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "frame_loss.h"
#include "gop_cache.h"

struct OH_AVCodec;
struct OH_AVBuffer;
struct OH_AVFormat;
struct NativeWindow;
typedef struct NativeWindow OHNativeWindow;

// 解码器重建（切后台、开关画质增强）时由会话累加，保证统计连续
struct DecoderCounters {
    uint64_t freezeEvents = 0;   // 因丢帧定格的次数
    uint64_t freezeTotalMs = 0;  // 定格累计时长
    uint64_t freezeGiveUps = 0;  // 等关键帧超时、放弃定格的次数
    uint64_t oversize = 0;       // 包超过解码器输入缓冲被丢弃
    uint64_t vsyncDeferred = 0;  // 与上一帧落在同一刷新周期、顺延到下一个 VSync 上屏
    uint64_t vsyncDropped = 0;   // 积压太多、为了不拉高延迟而跳过上屏
    uint64_t stutters = 0;       // 上屏间隔明显大于帧间隔（肉眼可见的卡顿）
    DecoderCounters& operator+=(const DecoderCounters& o) {
        freezeEvents += o.freezeEvents;
        freezeTotalMs += o.freezeTotalMs;
        freezeGiveUps += o.freezeGiveUps;
        oversize += o.oversize;
        vsyncDeferred += o.vsyncDeferred;
        vsyncDropped += o.vsyncDropped;
        stutters += o.stutters;
        return *this;
    }
};

// 上屏节奏：两次读取之间的窗口统计，读取后清零
struct RenderTiming {
    int jitterMs10 = 0;   // 上屏间隔与帧间隔之差的平均绝对值（0.1ms 单位）
    int maxGapMs = 0;     // 窗口内最长的上屏间隔
};

class VideoDecoder {
public:
    ~VideoDecoder();

    // width/height 是游戏机包头里的尺寸（SFT 720p 或 1080p）；尺寸变了由会话换一个解码器
    bool Init(OHNativeWindow* window, int width, int height, std::string* error);
    int Width() const { return width_; }
    int Height() const { return height_; }
    // 首个 IDR 不带 SPS/PPS 时补在前面的参数集（SFT 的关键帧都自带，一般用不上）
    void SetFallbackParamSets(std::vector<uint8_t> paramSets);
    // 从后台恢复时调用（须在任何 Submit 之前）：把缓存的 GOP 一次性送入解码，
    // 只渲染最后一帧及之后的帧，画面直接追到最新
    void Replay(std::vector<nssft::CachedPacket> gop);
    // 网络线程调用；数据会被拷贝
    void Submit(const uint8_t* data, size_t size, uint64_t timestampUs);
    void Release();

    // 丢帧定格：发现丢帧后不再送 P 帧（参考链已断，送进去只会花屏），画面停在最后一个完好的帧，
    // 等到下一个关键帧再继续；关闭时照常解码
    void SetFreezeOnLoss(bool on);
    // 网络线程在发现视频数据丢失时调用（与 Submit 串行）
    void OnFrameLoss(nssft::LossCause cause);
    bool Frozen() const { return frozen_; }
    int LastFreezeMs() const { return lastFreezeMs_; }
    // 正常帧间隔，用来判断上屏卡顿（由会话按时间戳估计后设置）
    void SetFrameIntervalUs(int64_t us) { frameIntervalNs_ = us * 1000; }
    DecoderCounters Counters() const;
    // 每成功送出一帧上屏（或送进画质增强）时回调，在解码输出线程调用；须在 Init 之前设置
    void SetFrameQueuedHook(std::function<void()> hook) { frameQueuedHook_ = std::move(hook); }
    RenderTiming TakeRenderTiming();

    uint64_t FramesRendered() const { return framesRendered_; }
    uint64_t FramesSkipped() const { return framesSkipped_; }
    uint64_t PacketsDropped() const { return packetsDropped_; }
    // 最近一次 Replay 到画面追上最新帧的耗时，-1 表示还没完成或没有发生
    int LastCatchUpMs() const { return lastCatchUpMs_; }
    std::string LastError();

private:
    struct InputSlot {
        uint32_t index;
        OH_AVBuffer* buffer;
    };
    struct Packet {
        std::vector<uint8_t> data;
        int64_t ptsUs;
    };

    static void OnError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    void FeedLoop();
    void Enqueue(Packet pkt, bool isIdr);

    OH_AVCodec* codec_ = nullptr;
    int width_ = 0;
    int height_ = 0;

    std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<InputSlot> inputs_;
    std::deque<Packet> packets_;
    bool running_ = false;
    std::thread feeder_;

    // 结束定格（Submit 线程）
    void EndFreeze(bool gaveUp);
    // 按 VSync 上屏（解码输出回调线程）
    void Present(OH_AVCodec* codec, uint32_t index);

    // 以下只在调用 Submit/Replay 的线程里访问（调用方保证串行）
    bool waitingKeyframe_ = true;
    bool lossFreeze_ = false;  // 当前是因为丢帧在等关键帧（区别于刚启动时的等待）
    int64_t freezeStartMs_ = 0;
    bool spsSent_ = false;
    std::vector<uint8_t> fallbackParamSets_;

    // 追帧：pts 小于该值的输出帧只解码不上屏
    std::atomic<bool> catchingUp_{false};
    std::atomic<int64_t> renderFromPts_{0};
    std::atomic<int64_t> catchUpStartMs_{0};
    std::atomic<int> lastCatchUpMs_{-1};

    std::atomic<bool> freezeOnLoss_{true};
    std::atomic<bool> frozen_{false};
    std::atomic<bool> lossPending_{false};  // 送解码线程发现包过大，交给 Submit 线程开始定格
    std::atomic<int> lastFreezeMs_{-1};
    std::atomic<uint64_t> freezeEvents_{0}, freezeTotalMs_{0}, freezeGiveUps_{0}, oversize_{0};

    // 上屏节奏（解码输出回调线程写，统计线程读）
    int64_t lastPresentNs_ = 0;
    std::atomic<int64_t> frameIntervalNs_{16'666'667};
    std::atomic<uint64_t> vsyncDeferred_{0}, vsyncDropped_{0}, stutters_{0};
    std::mutex timingMutex_;
    int64_t jitterSumUs_ = 0;
    int jitterCount_ = 0;
    int64_t maxGapUs_ = 0;

    std::function<void()> frameQueuedHook_;
    std::atomic<uint64_t> framesRendered_{0};
    std::atomic<uint64_t> framesSkipped_{0};
    std::atomic<uint64_t> packetsDropped_{0};
    std::string lastError_;
};
