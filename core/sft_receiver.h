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
    void SetAudioEnabled(bool enabled) { audioEnabled_ = enabled; }
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
    void HandleVideo(const sft::Header& h, const uint8_t* payload, uint64_t receivedUs);
    void HandleStatus(const uint8_t* payload, size_t n);

    const StreamCallbacks callbacks_;
    const std::atomic<bool>& stop_;
    std::atomic<bool> audioEnabled_{true};
    std::atomic<bool> keyWanted_{false};

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
