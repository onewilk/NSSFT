// 桌面版 SFT 收流探针：用和鸿蒙端同一套 core/ 代码连游戏机（或 tools/mock_sft.py），打印收流统计。
//
//   sh tools/build_probe.sh && build/sft_probe 192.168.1.50 [秒数，默认 10]
//   build/sft_probe --discover [秒数]        # 只监听 UDP 9951 广播
//
// 视频序号断档时会像客户端一样请求关键帧（SFTK）。退出码：收到过视频为 0，否则为 1。
// 环境变量 SFT_PAD_TEST=1：当作接着一个手柄，第 1 秒起按住手柄的 B 键（按位置对应游戏机的 A）半秒（测 SFTI）。
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

#include "../core/h264.h"
#include "../core/sft_net_source.h"
#include "../core/sft_pad.h"

using namespace nssft;

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "用法：%s <游戏机 IP> [秒数] | --discover [秒数]\n", argv[0]);
        return 2;
    }
    const int seconds = argc > 2 ? std::atoi(argv[2]) : 10;
    // 测试脚本用别的端口，免得和本机真的 SFT 客户端冲突
    const char* portEnv = std::getenv("SFT_PORT");
    const char* beaconEnv = std::getenv("SFT_BEACON_PORT");
    const uint16_t port = portEnv ? uint16_t(std::atoi(portEnv)) : sft::kStreamPort;
    const uint16_t beaconPort = beaconEnv ? uint16_t(std::atoi(beaconEnv)) : sft::kBeaconPort;

    if (std::strcmp(argv[1], "--discover") == 0) {
        SftDiscovery d;
        if (!d.Start(beaconPort)) return 1;
        std::this_thread::sleep_for(std::chrono::seconds(seconds));
        const auto devices = d.Devices();
        for (const auto& dev : devices) std::printf("%s:%u  %s\n", dev.ip.c_str(), unsigned(dev.port), dev.name.c_str());
        d.Stop();
        return devices.empty() ? 1 : 0;
    }

    std::atomic<uint64_t> frames{0}, idrs{0}, mismatched{0}, audioBytes{0}, losses{0};
    StreamSource* self = nullptr;
    StreamCallbacks cb;
    cb.onVideo = [&](const VideoFrame& f) {
        ++frames;
        const bool idr = ContainsNalType(f.data, f.size, kNalIdr);
        if (idr) ++idrs;
        if (idr != f.key) ++mismatched;  // 包头的 KEY 标志应该和码流一致
    };
    cb.onAudio = [&](const uint8_t*, size_t n) { audioBytes += n; };
    cb.onStatus = [](const std::string& m) { std::printf("[状态] %s\n", m.c_str()); };
    cb.onVideoLoss = [&](LossCause c) {
        ++losses;
        std::printf("[丢失] 原因 %d\n", int(c));
        if (self) self->RequestKeyframe();
    };

    SftNetSource source(argv[1], cb, port);
    self = &source;
    source.Start();
    const bool padTest = std::getenv("SFT_PAD_TEST") != nullptr;
    pad::PadState padState;
    pad::PadSender padSender(
        padState, [&](const uint8_t* p, size_t n) { return source.SendInput(p, n); },
        [&] { return source.ConsoleTakesInput(); });
    if (padTest) {
        padSender.SetDevicePresent(true);
        padSender.SetEnabled(true);
    }
    const auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < seconds; ++i) {
        if (padTest && i == 1) {
            padState.Key(pad::key::kButtonB, true);
            padSender.Poke();
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            padState.Key(pad::key::kButtonB, false);
            padSender.Poke();
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        } else {
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
        const SourceStats s = source.GetStats();
        std::printf("%2ds  视频 %llu 帧（关键帧 %llu）%ux%u  %.1f Mbps  音频 %llu 包  请求 %llu  断档 %llu（%llu 帧）\n", i + 1,
                    (unsigned long long)s.videoPackets, (unsigned long long)s.keyframes, s.width, s.height,
                    s.videoBytes * 8.0 / 1e6 /
                        std::max(1.0, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count()),
                    (unsigned long long)s.audioPackets, (unsigned long long)s.keyRequests,
                    (unsigned long long)s.sequenceGaps, (unsigned long long)s.lostFrames);
    }
    const bool takesInput = source.ConsoleTakesInput();
    padSender.Stop();  // 接着的话先拔掉手柄，再断开
    source.Stop();
    const SourceStats s = source.GetStats();
    std::printf("结果：frames=%llu idr=%llu key_mismatch=%llu audio_bytes=%llu losses=%llu key_requests=%llu "
                "gaps=%llu lost=%llu resyncs=%llu reconnects=%llu avg_age_us=%llu takes_input=%d pad_sent=%llu\n",
                (unsigned long long)frames.load(), (unsigned long long)idrs.load(),
                (unsigned long long)mismatched.load(), (unsigned long long)audioBytes.load(),
                (unsigned long long)losses.load(), (unsigned long long)s.keyRequests,
                (unsigned long long)s.sequenceGaps, (unsigned long long)s.lostFrames, (unsigned long long)s.resyncs,
                (unsigned long long)s.reconnects,
                (unsigned long long)(s.ageSamples ? s.ageTotalUs / s.ageSamples : 0), takesInput ? 1 : 0,
                (unsigned long long)padSender.Sent());
    return frames > 0 ? 0 : 1;
}
