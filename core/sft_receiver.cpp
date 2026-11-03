#include "sft_receiver.h"

#include <algorithm>
#include <chrono>
#include <cstring>

#include "i18n.h"
#include "log.h"

namespace nssft {

namespace {

// 读通道的时间片：挂起的关键帧请求、画面停顿检查都在这个间隔里处理，Stop() 也最多等这么久
constexpr int kSliceMs = 100;
// 包头之后负载读一半卡住这么久就当作断开
constexpr int64_t kPayloadTimeoutMs = 5000;
// 收到过画面后这么久没有新画面：游戏机回到了主菜单（默认按 HOME 就停流）或游戏暂停输出
constexpr int64_t kVideoPauseMs = 1500;
// 两次关键帧请求的最小间隔；USB 上游戏机没在收请求时写入会失败，隔 150 ms 再试，最多试约 2 秒（与 SFT 客户端一致）
constexpr int64_t kKeyRequestGapMs = 300;
constexpr int64_t kKeyRetryMs = 150;
constexpr int kKeyMaxTries = 14;
// 包头里游戏机端耗时的合理上限，超过就不用来推算时间戳
constexpr uint32_t kMaxAgeUs = 1'000'000;
// 序号一次跳这么多不当作丢帧，而是游戏机重新开始了一段串流
constexpr uint32_t kMaxPlausibleGap = 600;
// 读缓冲：USB 一次 bulk 读最多 128 KB，TCP 也按块读，再从缓冲里切出包头和负载
constexpr size_t kReadBufferSize = 256 * 1024;

int64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

uint64_t NowUs() {
    using namespace std::chrono;
    return uint64_t(duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count());
}

}  // namespace

SftReceiver::SftReceiver(StreamCallbacks callbacks, const std::atomic<bool>& stop)
    : callbacks_(std::move(callbacks)), stop_(stop), rbuf_(kReadBufferSize) {}

void SftReceiver::BeginConnection() {
    rpos_ = rlen_ = 0;
    lastError_.clear();
    haveSequence_ = false;
    streaming_ = false;
    lastVideoMs_ = 0;
    lastKeyRequestMs_ = 0;
    keyRetryAtMs_ = 0;
    keyTries_ = 0;
    takesInput_ = false;  // 等新连接的包头说
    keyWanted_ = true;  // 连上就要一个关键帧，不用等游戏机的下一个（网络下最长 4 秒一个）
    requestRetryAtMs_ = 0;
    requestTries_ = 0;
    std::lock_guard<std::mutex> lock(requestMutex_);
    requests_.clear();  // 上一条连接没发出去的请求作废
    // 正在录制：新连接游戏机默认不锁尺寸，再请求一次
    if (sizeLocked_) requests_.emplace_back(sft::kRequestRecordLock, sizeof(sft::kRequestRecordLock));
}

void SftReceiver::SetRecordSizeLock(bool on) {
    if (sizeLocked_.exchange(on) == on) return;
    if (on) {
        QueueRequest(sft::kRequestRecordLock, sizeof(sft::kRequestRecordLock));
    } else {
        QueueRequest(sft::kRequestRecordUnlock, sizeof(sft::kRequestRecordUnlock));
    }
}

void SftReceiver::QueueRequest(const char* bytes, size_t n) {
    std::lock_guard<std::mutex> lock(requestMutex_);
    requests_.emplace_back(bytes, n);
}

void SftReceiver::FlushRequests(ByteChannel& ch) {
    const int64_t now = NowMs();
    if (now < requestRetryAtMs_) return;
    std::unique_lock<std::mutex> write(writeMutex_, std::try_to_lock);
    if (!write.owns_lock()) return;  // 手柄线程正在写：下一轮再发
    std::lock_guard<std::mutex> lock(requestMutex_);
    while (!requests_.empty()) {
        const std::string& r = requests_.front();
        const int n = ch.Write(reinterpret_cast<const uint8_t*>(r.data()), r.size(), 20);
        if (n != int(r.size())) {
            // USB：游戏机这一刻没在收请求，过一会再试；试够次数就放弃这一条
            if (++requestTries_ < kKeyMaxTries) {
                requestRetryAtMs_ = now + kKeyRetryMs;
                return;
            }
            Logf(LogLevel::Warn, "请求 %s 一直发不出去，放弃", r.c_str());
        }
        requests_.erase(requests_.begin());
        requestTries_ = 0;
        requestRetryAtMs_ = 0;
    }
}

bool SftReceiver::SendInput(const uint8_t* data, size_t size) {
    std::lock_guard<std::mutex> lock(writeMutex_);
    if (channel_ == nullptr || stop_) return false;
    return channel_->Write(data, size, 20) == int(size);
}

void SftReceiver::SetConnected(bool connected) {
    if (!connected) takesInput_ = false;
    std::lock_guard<std::mutex> lock(statsMutex_);
    stats_.connected = connected;
    if (!connected) stats_.consoleTakesInput = false;
}

void SftReceiver::AddReconnect() {
    std::lock_guard<std::mutex> lock(statsMutex_);
    ++stats_.reconnects;
}

SourceStats SftReceiver::Stats() const {
    std::lock_guard<std::mutex> lock(statsMutex_);
    return stats_;
}

void SftReceiver::Status(const std::string& message) {
    if (callbacks_.onStatus && !stop_) callbacks_.onStatus(message);
}

void SftReceiver::FlushKeyRequest(ByteChannel& ch) {
    if (!keyWanted_) return;
    const int64_t now = NowMs();
    if (now - lastKeyRequestMs_ < kKeyRequestGapMs || now < keyRetryAtMs_) return;  // 先留着，过一会再发
    std::unique_lock<std::mutex> write(writeMutex_, std::try_to_lock);
    if (!write.owns_lock()) return;  // 手柄线程正在写：下一轮再发
    const int n = ch.Write(reinterpret_cast<const uint8_t*>(sft::kRequestKeyframe), sizeof(sft::kRequestKeyframe), 20);
    write.unlock();
    if (n == int(sizeof(sft::kRequestKeyframe))) {
        keyWanted_ = false;
        keyTries_ = 0;
        keyRetryAtMs_ = 0;
        lastKeyRequestMs_ = now;
        std::lock_guard<std::mutex> lock(statsMutex_);
        ++stats_.keyRequests;
        return;
    }
    // USB：游戏机这一刻没在收请求，过一会再试；试够次数就放弃这一次（之后丢帧还会再请求）
    if (++keyTries_ < kKeyMaxTries) {
        keyRetryAtMs_ = now + kKeyRetryMs;
    } else {
        Logf(LogLevel::Warn, "关键帧请求一直发不出去，放弃这一次");
        keyWanted_ = false;
        keyTries_ = 0;
        keyRetryAtMs_ = 0;
        lastKeyRequestMs_ = now;
    }
}

void SftReceiver::Idle(ByteChannel& ch) {
    FlushKeyRequest(ch);
    FlushRequests(ch);
    if (streaming_ && NowMs() - lastVideoMs_ > kVideoPauseMs) {
        // 游戏机回到主菜单（SFT 默认按 HOME 就停流）：连接还在，等下一段画面，不当作断开
        streaming_ = false;
        Status(L("已连接，在游戏机上打开一款游戏…", "已連線，在遊戲機上打開一款遊戲…",
                 "Connected. Open a game on the console…"));
    }
}

bool SftReceiver::Fill(ByteChannel& ch, int idleMs) {
    const int64_t start = NowMs();
    while (!stop_) {
        const int n = ch.Read(rbuf_.data(), rbuf_.size(), kSliceMs);
        if (n > 0) {
            rpos_ = 0;
            rlen_ = size_t(n);
            return true;
        }
        if (n < 0) {
            lastError_ = ch.LastError();
            return false;
        }
        Idle(ch);
        if (idleMs > 0 && NowMs() - start > idleMs) {
            lastError_ = L("接收超时", "接收逾時", "receive timed out");
            return false;
        }
    }
    return false;
}

bool SftReceiver::RecvExact(ByteChannel& ch, uint8_t* dst, size_t n, bool idleAllowed) {
    size_t got = 0;
    while (got < n) {
        if (rpos_ >= rlen_ && !Fill(ch, idleAllowed && got == 0 ? 0 : int(kPayloadTimeoutMs))) return false;
        const size_t take = std::min(n - got, rlen_ - rpos_);
        std::memcpy(dst + got, rbuf_.data() + rpos_, take);
        rpos_ += take;
        got += take;
    }
    return true;
}

bool SftReceiver::Resync(ByteChannel& ch, uint8_t* header) {
    static constexpr uint8_t kMagicBytes[4] = {'S', 'F', 'T', 'R'};
    constexpr size_t kSize = sft::kHeaderSize;
    // 下一个包头往往已经落在刚读进来的这 32 字节里（前面只是多了几个字节）：先在这里面找，
    // 找到就把它挪到开头、补齐剩下的字节；不先找的话，后面逐字节找会正好跳过它
    for (size_t k = 1; k + 4 <= kSize; ++k) {
        if (std::memcmp(header + k, kMagicBytes, 4) == 0) {
            std::memmove(header, header + k, kSize - k);
            return RecvExact(ch, header + kSize - k, k, false);
        }
    }
    // 没找到：末尾几个字节可能是 "SFTR" 的开头，接着往后逐字节找
    int run = 0;
    for (int len = 3; len > 0; --len) {
        if (std::memcmp(header + kSize - len, kMagicBytes, size_t(len)) == 0) {
            run = len;
            break;
        }
    }
    uint8_t b = 0;
    while (run < 4) {
        if (!RecvExact(ch, &b, 1, false)) return false;
        run = (b == kMagicBytes[run]) ? run + 1 : (b == kMagicBytes[0] ? 1 : 0);
    }
    std::memcpy(header, kMagicBytes, 4);
    return RecvExact(ch, header + 4, sft::kHeaderSize - 4, false);
}

std::string SftReceiver::Run(ByteChannel& ch) {
    // 这条连接在 Run 期间给手柄线程用（SendInput）；返回前摘掉
    struct ChannelScope {
        SftReceiver& r;
        ChannelScope(SftReceiver& receiver, ByteChannel& c) : r(receiver) {
            std::lock_guard<std::mutex> lock(r.writeMutex_);
            r.channel_ = &c;
        }
        ~ChannelScope() {
            std::lock_guard<std::mutex> lock(r.writeMutex_);
            r.channel_ = nullptr;
        }
    } scope(*this, ch);
    std::vector<uint8_t> payload;
    payload.reserve(512 * 1024);
    uint8_t hdr[sft::kHeaderSize];

    while (!stop_) {
        FlushKeyRequest(ch);
        FlushRequests(ch);
        // 等包头时允许长时间没数据（没有游戏在屏幕上时游戏机什么都不发）；断线由底层通道发现
        if (!RecvExact(ch, hdr, sizeof(hdr), true)) break;
        uint64_t receivedUs = NowUs();

        sft::Header h = sft::ParseHeader(hdr);
        std::string why;
        sft::PacketKind kind = sft::Classify(h, &why);
        bool alive = true;
        while (kind == sft::PacketKind::Invalid && alive) {
            if (h.magic == sft::kMagic && h.version == sft::kVersion && h.length <= sft::kMaxVideoBytes) {
                // 包头完整、只是格式不认识（比如以后的新包类型）：跳过它的负载，连接照常
                Logf(LogLevel::Warn, "跳过不认识的包：%s（flags 0x%x，%u 字节）", why.c_str(), unsigned(h.flags),
                     unsigned(h.length));
                payload.resize(h.length);
                alive = (h.length == 0 || RecvExact(ch, payload.data(), h.length, false)) &&
                        RecvExact(ch, hdr, sizeof(hdr), true);
            } else {
                Logf(LogLevel::Warn, "包头失步（%s），重新对齐", why.c_str());
                {
                    std::lock_guard<std::mutex> lock(statsMutex_);
                    ++stats_.resyncs;
                }
                if (callbacks_.onVideoLoss) callbacks_.onVideoLoss(LossCause::Resync);
                keyWanted_ = true;
                haveSequence_ = false;
                alive = Resync(ch, hdr);
            }
            receivedUs = NowUs();
            h = sft::ParseHeader(hdr);
            kind = sft::Classify(h, &why);
        }
        if (!alive) break;
        if (kind == sft::PacketKind::Empty) continue;  // USB 上游戏机探测接收端还在不在

        payload.resize(h.length);
        if (!RecvExact(ch, payload.data(), h.length, false)) break;

        switch (kind) {
            case sft::PacketKind::Video:
                HandleVideo(h, payload.data(), receivedUs);
                break;
            case sft::PacketKind::Audio: {
                {
                    std::lock_guard<std::mutex> lock(statsMutex_);
                    ++stats_.audioPackets;
                    stats_.audioBytes += h.length;
                }
                if (audioEnabled_ && callbacks_.onAudio) callbacks_.onAudio(payload.data(), h.length);
                break;
            }
            case sft::PacketKind::Status:
                // 状态包（游戏机在主菜单等没有画面时）也带 kFlagInput
                takesInput_ = h.input;
                {
                    std::lock_guard<std::mutex> lock(statsMutex_);
                    stats_.consoleTakesInput = h.input;
                }
                HandleStatus(payload.data(), h.length);
                break;
            default:
                break;
        }
    }
    if (stop_) return std::string();
    return lastError_.empty() ? std::string(L("连接已断开", "連線已中斷", "connection closed")) : lastError_;
}

void SftReceiver::HandleVideo(const sft::Header& h, const uint8_t* payload, uint64_t receivedUs) {
    bool lost = false;
    uint32_t gap = 0;
    if (haveSequence_) {
        gap = h.sequence - lastSequence_ - 1;  // 无符号回绕
        if (gap != 0) {
            if (gap < kMaxPlausibleGap) {
                lost = true;
            } else {
                // 序号倒退或大跳：游戏机重新开始了一段串流（关掉游戏、换游戏），新段从关键帧开始
                Logf(LogLevel::Info, "视频序号从 %u 跳到 %u，当作新的一段串流", unsigned(lastSequence_),
                     unsigned(h.sequence));
            }
        }
    }
    haveSequence_ = true;
    lastSequence_ = h.sequence;

    const bool resumed = !streaming_;
    bool resized = false;
    {
        std::lock_guard<std::mutex> lock(statsMutex_);
        ++stats_.videoPackets;
        stats_.videoBytes += h.length;
        if (h.flags & sft::kFlagKey) ++stats_.keyframes;
        if (lost) {
            ++stats_.sequenceGaps;
            stats_.lostFrames += gap;
        }
        resized = stats_.width != h.width || stats_.height != h.height;
        stats_.width = h.width;
        stats_.height = h.height;
        if (h.ageUs <= kMaxAgeUs) {
            stats_.ageTotalUs += h.ageUs;
            ++stats_.ageSamples;
        }
        stats_.consoleTakesInput = h.input;
    }
    takesInput_ = h.input;
    streaming_ = true;
    lastVideoMs_ = NowMs();

    if (lost) {
        Logf(LogLevel::Warn, "视频序号断档：跳过 %u 帧", unsigned(gap));
        if (callbacks_.onVideoLoss) callbacks_.onVideoLoss(LossCause::SequenceGap);
        keyWanted_ = true;
    }
    if (resumed || resized) {
        Logf(LogLevel::Info, "视频 %ux%u", unsigned(h.width), unsigned(h.height));
        Status(Format(L("正在接收 %u×%u", "正在接收 %u×%u", "Receiving %u×%u"), unsigned(h.width), unsigned(h.height)));
    }

    VideoFrame f;
    f.data = payload;
    f.size = h.length;
    f.timestampUs = (h.ageUs <= kMaxAgeUs && receivedUs > h.ageUs) ? receivedUs - h.ageUs : receivedUs;
    f.width = h.width;
    f.height = h.height;
    f.key = (h.flags & sft::kFlagKey) != 0;
    f.sequence = h.sequence;
    if (callbacks_.onVideo) callbacks_.onVideo(f);
}

void SftReceiver::HandleStatus(const uint8_t* payload, size_t n) {
    sft::ConsoleStatus st;
    if (!sft::ParseStatus(payload, n, &st)) return;
    uint32_t previous = 0;
    {
        std::lock_guard<std::mutex> lock(statsMutex_);
        ++stats_.statusPackets;
        previous = stats_.statusReason;
        stats_.statusReason = st.reason;
        stats_.statusHead = st.head;
        stats_.statusDetail = st.detail;
    }
    if (st.reason == 0) {
        if (previous != 0) Status(L("已连接，在游戏机上打开一款游戏…", "已連線，在遊戲機上打開一款遊戲…",
                                    "Connected. Open a game on the console…"));
        return;
    }
    if (previous != st.reason) Logf(LogLevel::Info, "游戏机状态 %u：%s / %s", unsigned(st.reason), st.head.c_str(), st.detail.c_str());
    // 原因文字来自游戏机（SFT 只有英文），原样显示
    std::string text = st.head;
    if (!st.detail.empty()) text += text.empty() ? st.detail : " · " + st.detail;
    Status(Format(L("游戏机：%s", "遊戲機：%s", "Console: %s"), text.c_str()));
}

}  // namespace nssft
