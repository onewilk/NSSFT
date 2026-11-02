// SFT 的 USB 串流（游戏机在 SFT 里选 “USB - PC viewer”，用数据线连到本机，掌机模式）。
// 设备 1209:5F1E，接口 0：IN 0x81 收 SFTR 包（和网络上的一模一样），OUT 0x01 发请求（SFTK 等）。
// 底层读写由 ByteChannel 提供（鸿蒙上是 usbfs 直连或 ArkTS bulkTransfer 兼容传输），这里只管收流。
#pragma once

#include <atomic>
#include <memory>
#include <thread>

#include "byte_channel.h"
#include "sft_receiver.h"
#include "stream_source.h"

namespace nssft {

class SftUsbSource : public StreamSource {
public:
    SftUsbSource(std::unique_ptr<ByteChannel> channel, StreamCallbacks callbacks);
    ~SftUsbSource() override;

    SftUsbSource(const SftUsbSource&) = delete;
    SftUsbSource& operator=(const SftUsbSource&) = delete;

    void Start() override;
    // 停止前发 "SFTQ" 告诉游戏机接收端走了，它会马上放开 USB，不用等超时
    void Stop() override;
    SourceStats GetStats() const override { return receiver_.Stats(); }
    // 声音和画面在同一个端点上，关掉声音只是本地不播放
    void SetAudioEnabled(bool enabled) override { receiver_.SetAudioEnabled(enabled); }
    void RequestKeyframe() override { receiver_.RequestKeyframe(); }

private:
    void Run();

    std::unique_ptr<ByteChannel> channel_;
    std::atomic<bool> stop_{false};
    std::thread thread_;
    SftReceiver receiver_;
};

}  // namespace nssft
