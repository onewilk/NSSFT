// SftReceiver / SftUsbSource 单元测试：用假的 ByteChannel 模拟 USB 上零碎到达的数据、空探测包头、状态包、
// 写请求失败重试和断开。c++ -std=c++17 -pthread core/sft_receiver.cpp core/sft_usb_source.cpp core/sft_protocol.cpp
//   core/i18n.cpp core/log.cpp tools/sft_receiver_test.cpp && ./a.out
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../core/sft_protocol.h"
#include "../core/sft_receiver.h"
#include "../core/sft_usb_source.h"

using namespace nssft;

static int g_failed = 0;
#define CHECK(cond)                                                    \
    do {                                                               \
        if (!(cond)) {                                                 \
            std::printf("  ✗ %s:%d  %s\n", __FILE__, __LINE__, #cond); \
            ++g_failed;                                                \
        }                                                              \
    } while (0)

// 按给定的块大小吐出预先准备好的字节；吐完后按 endWithError 返回断开，否则一直超时
class FakeChannel : public ByteChannel {
public:
    std::vector<uint8_t> data;
    std::atomic<size_t> pos{0};
    size_t chunk = 7;
    std::atomic<bool> endWithError{true};
    int failWrites = 0;  // 前几次写入失败（模拟 USB 上游戏机没在收请求）
    std::mutex mutex;
    std::vector<std::string> writes;

    int Read(uint8_t* buf, size_t capacity, int timeoutMs) override {
        if (pos >= data.size()) {
            if (endWithError) return -1;
            std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
            return 0;
        }
        const size_t n = std::min({chunk, capacity, data.size() - pos.load()});
        std::memcpy(buf, data.data() + pos.load(), n);
        pos += n;
        return int(n);
    }
    int Write(const uint8_t* buf, size_t length, int) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (failWrites > 0) {
            --failWrites;
            return -1;
        }
        writes.emplace_back(reinterpret_cast<const char*>(buf), length);
        return int(length);
    }
    std::string LastError() const override { return "unplugged"; }
};

static void Append(std::vector<uint8_t>& out, uint16_t flags, uint32_t w, uint32_t h, uint32_t seq,
                   const std::vector<uint8_t>& payload) {
    sft::Header hd;
    hd.magic = sft::kMagic;
    hd.version = sft::kVersion;
    hd.flags = flags;
    hd.width = w;
    hd.height = h;
    hd.length = uint32_t(payload.size());
    hd.sequence = seq;
    uint8_t buf[sft::kHeaderSize];
    sft::WriteHeader(hd, buf);
    out.insert(out.end(), buf, buf + sizeof(buf));
    out.insert(out.end(), payload.begin(), payload.end());
}

static std::vector<uint8_t> Frame(bool key, size_t size) {
    std::vector<uint8_t> f = {0, 0, 0, 1, uint8_t(key ? 0x65 : 0x41)};
    f.resize(size, 0xAB);
    return f;
}

static void TestUsbStream() {
    std::printf("USB：零碎到达、空探测包头、状态包、声音、序号断档\n");
    auto ch = std::make_unique<FakeChannel>();
    std::vector<uint8_t>& d = ch->data;
    Append(d, 0, 0, 0, 0, {});  // 空探测包头
    std::vector<uint8_t> st(192, 0);
    st[4] = 3;
    std::memcpy(st.data() + 8, "No game on screen", 17);
    Append(d, sft::kFlagAudio | sft::kFlagStatus, 0, 0, 0, st);
    Append(d, sft::kFlagVideo | sft::kFlagKey, 1280, 720, 10, Frame(true, 5000));
    Append(d, sft::kFlagAudio, 48000, 2, 0, std::vector<uint8_t>(4096, 1));
    Append(d, sft::kFlagVideo, 1280, 720, 11, Frame(false, 1200));
    Append(d, sft::kFlagVideo, 1280, 720, 14, Frame(false, 900));  // 跳过 12、13
    d.insert(d.end(), {1, 2, 3, 4, 5});                            // 垃圾字节：要失步再对齐
    Append(d, sft::kFlagVideo | sft::kFlagKey, 1920, 1080, 15, Frame(true, 3000));
    ch->failWrites = 2;
    ch->endWithError = false;  // 先保持连接，等关键帧请求重试发出去，再模拟拔线
    FakeChannel* raw = ch.get();

    std::atomic<int> frames{0}, keys{0}, audioBytes{0}, losses{0}, resyncs{0};
    std::vector<std::string> statuses;
    std::mutex statusMutex;
    StreamCallbacks cb;
    cb.onVideo = [&](const VideoFrame& f) {
        ++frames;
        if (f.key) ++keys;
    };
    cb.onAudio = [&](const uint8_t*, size_t n) { audioBytes += int(n); };
    cb.onStatus = [&](const std::string& m) {
        std::lock_guard<std::mutex> lock(statusMutex);
        statuses.push_back(m);
    };
    cb.onVideoLoss = [&](LossCause c) {
        if (c == LossCause::SequenceGap) ++losses;
        if (c == LossCause::Resync) ++resyncs;
    };
    SftUsbSource src(std::move(ch), cb);
    src.Start();
    for (int i = 0; i < 50 && raw->pos < raw->data.size(); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(20));
    std::this_thread::sleep_for(std::chrono::milliseconds(800));  // 等关键帧请求重试发出去
    raw->endWithError = true;                                       // 拔线
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    src.Stop();

    const SourceStats s = src.GetStats();
    CHECK(frames == 4);
    CHECK(keys == 2);
    CHECK(audioBytes == 4096);
    CHECK(losses == 1);
    CHECK(s.lostFrames == 2);
    CHECK(resyncs == 1 && s.resyncs == 1);
    CHECK(s.statusReason == 3 && s.statusHead == "No game on screen");
    CHECK(s.width == 1920 && s.height == 1080);
    {
        std::lock_guard<std::mutex> lock(raw->mutex);
        bool sawKey = false;
        for (const auto& w : raw->writes) sawKey |= w == "SFTK";
        CHECK(sawKey);                                             // 前两次写失败后重试成功
        CHECK(!raw->writes.empty() && raw->writes.back() == "SFTQ");  // 停止时告别
    }
    std::lock_guard<std::mutex> lock(statusMutex);
    bool sawConsole = false, sawLost = false;
    for (const auto& m : statuses) {
        sawConsole |= m.find("No game on screen") != std::string::npos;
        sawLost |= m.find("unplugged") != std::string::npos;
    }
    CHECK(sawConsole);
    CHECK(sawLost);  // 拔线后提示里带着通道给的原因
}

static void TestPauseNotice() {
    std::printf("画面停 1.5 秒以上：提示回到主菜单的等待状态，不当作断开\n");
    auto ch = std::make_unique<FakeChannel>();
    ch->chunk = 1 << 20;
    ch->endWithError = false;
    Append(ch->data, sft::kFlagVideo | sft::kFlagKey, 1280, 720, 1, Frame(true, 2000));
    std::vector<std::string> statuses;
    std::mutex m;
    StreamCallbacks cb;
    cb.onStatus = [&](const std::string& s) {
        std::lock_guard<std::mutex> lock(m);
        statuses.push_back(s);
    };
    SftUsbSource src(std::move(ch), cb);
    src.Start();
    std::this_thread::sleep_for(std::chrono::milliseconds(2000));
    const bool connected = src.GetStats().connected;
    src.Stop();
    CHECK(connected);
    std::lock_guard<std::mutex> lock(m);
    CHECK(statuses.size() >= 3);
    CHECK(statuses.back().find("打开一款游戏") != std::string::npos);
}

int main() {
    TestUsbStream();
    TestPauseNotice();
    if (g_failed) {
        std::printf("sft_receiver_test: %d 项失败\n", g_failed);
        return 1;
    }
    std::printf("sft_receiver_test: 全部通过\n");
    return 0;
}
