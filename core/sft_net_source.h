// SFT 网络串流客户端：连 TCP 9950，断线自动重连；以及 UDP 9951 上的游戏机广播发现。
#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "sft_protocol.h"
#include "sft_receiver.h"
#include "stream_source.h"

namespace nssft {

class SftNetSource : public StreamSource {
public:
    SftNetSource(std::string host, StreamCallbacks callbacks, uint16_t port = sft::kStreamPort);
    ~SftNetSource() override;

    SftNetSource(const SftNetSource&) = delete;
    SftNetSource& operator=(const SftNetSource&) = delete;

    void Start() override;
    void Stop() override;
    SourceStats GetStats() const override { return receiver_.Stats(); }
    void SetAudioEnabled(bool enabled) override { receiver_.SetAudioEnabled(enabled); }
    void RequestKeyframe() override { receiver_.RequestKeyframe(); }
    // 每次收完数据立即回 ACK（TCP_QUICKACK，仅 Linux/鸿蒙内核有效）
    void SetQuickAck(bool enabled) override { quickAck_ = enabled; }
    std::vector<SocketFlow> SocketFlows() const override;

private:
    void Run();
    bool Sleep(int ms);  // 可被 Stop 打断；返回 false 表示要停了

    const std::string host_;
    const uint16_t port_;

    std::atomic<bool> stop_{false};
    std::atomic<bool> quickAck_{true};
    std::thread thread_;
    mutable std::mutex fdMutex_;  // 主线程读地址时，防止接收线程同时关掉 socket
    int fd_ = -1;
    SftReceiver receiver_;
};

class SftDiscovery {
public:
    struct Device {
        std::string ip;
        uint16_t port = 0;
        std::string name;
    };

    ~SftDiscovery();
    bool Start(uint16_t port = sft::kBeaconPort);
    void Stop();
    // 最近 5 秒内广播过的游戏机（有客户端连着时游戏机不广播）
    std::vector<Device> Devices() const;

private:
    void Run();

    struct Entry {
        Device device;
        int64_t lastSeenMs;
    };

    std::atomic<bool> stop_{false};
    int fd_ = -1;
    std::thread thread_;
    mutable std::mutex mutex_;
    std::vector<Entry> devices_;
};

}  // namespace nssft
