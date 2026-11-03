// SFTR v2 收流：从一条 ByteChannel 上按包头读包、校验、分发，并负责关键帧请求、统计和给用户看的状态。
// 网络（SftNetSource）和 USB（SftUsbSource）共用这一份逻辑。
#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "byte_channel.h"
#include "sft_protocol.h"
#include "stream_source.h"

namespace nssft {

class SftReceiver {
public:
    // stop：所属来源的停止标志（只读）
    SftReceiver(StreamCallbacks callbacks, const std::atomic<bool>& stop);

    // 新的一次连接开始前调用：清掉序号状态和读缓冲，马上请求一个关键帧
    void BeginConnection();
    // 收流直到连接断开或停止。返回断开的原因（给用户看），停止时返回空串
    std::string Run(ByteChannel& channel);

    void RequestKeyframe() { keyWanted_ = true; }
    // 录制时的尺寸锁定：发 SFTKSFTL / SFTKSFTU；锁定状态会记住，重连后再发一次（新连接游戏机默认不锁）
    void SetRecordSizeLock(bool on);
    void SetAudioEnabled(bool enabled) { audioEnabled_ = enabled; }
    // 手柄消息（SFTI）：由手柄的发送线程调用，直接写到当前连接上；没连着或这一刻写不出去时返回 false
    bool SendInput(const uint8_t* data, size_t size);
    // 游戏机现在接不接受手柄（最近的包头带 kFlagInput）；断开后为 false
    bool ConsoleTakesInput() const { return takesInput_; }
    void SetConnected(bool connected);
    void AddReconnect();
    SourceStats Stats() const;
    void Status(const std::string& message);

private:
    bool Fill(ByteChannel& ch, int idleMs);  // 读缓冲为空时从通道补一批数据；false 表示断开或停止
    bool RecvExact(ByteChannel& ch, uint8_t* dst, size_t n, bool idleAllowed);
    bool Resync(ByteChannel& ch, uint8_t* header);
    void Idle(ByteChannel& ch);  // 没数据的空档：发挂起的请求、检查画面是不是停了
    void FlushKeyRequest(ByteChannel& ch);
    // 发挂起的其他请求（尺寸锁定等）；USB 上写失败时隔一会再试
    void FlushRequests(ByteChannel& ch);
    void QueueRequest(const char* bytes, size_t n);
    void HandleVideo(const sft::Header& h, const uint8_t* payload, uint64_t receivedUs);
    void HandleStatus(const uint8_t* payload, size_t n);

    const StreamCallbacks callbacks_;
    const std::atomic<bool>& stop_;
    std::atomic<bool> audioEnabled_{true};
    std::atomic<bool> keyWanted_{false};
    std::atomic<bool> sizeLocked_{false};
    std::atomic<bool> takesInput_{false};

    // 写连接：收流线程（请求）和手柄线程（SFTI）都写，用 writeMutex_ 串起来。收流线程只 try_lock，
    // 拿不到就下一轮再发，不会因为手柄那边在写（USB 上可能要等一会）而耽误收画面
    std::mutex writeMutex_;
    ByteChannel* channel_ = nullptr;  // Run 期间指向当前连接，受 writeMutex_ 保护

    // 挂起的其他请求（主线程放入，收流线程发出）
    std::mutex requestMutex_;
    std::vector<std::string> requests_;
    int64_t requestRetryAtMs_ = 0;  // 只在收流线程里用
    int requestTries_ = 0;

    // 只在收流线程里用
    std::vector<uint8_t> rbuf_;
    size_t rpos_ = 0;
    size_t rlen_ = 0;
    std::string lastError_;
    bool haveSequence_ = false;
    uint32_t lastSequence_ = 0;
    bool streaming_ = false;       // 正在收到画面（停了 1.5 秒以上就算停）
    int64_t lastVideoMs_ = 0;
    int64_t lastKeyRequestMs_ = 0;
    int64_t keyRetryAtMs_ = 0;
    int keyTries_ = 0;

    mutable std::mutex statsMutex_;
    SourceStats stats_;
};

}  // namespace nssft
