#include "sft_usb_source.h"

#include "i18n.h"
#include "log.h"

namespace nssft {

namespace {
constexpr char kGoodbye[4] = {'S', 'F', 'T', 'Q'};
}

SftUsbSource::SftUsbSource(std::unique_ptr<ByteChannel> channel, StreamCallbacks callbacks)
    : channel_(std::move(channel)), receiver_(std::move(callbacks), stop_) {}

SftUsbSource::~SftUsbSource() { Stop(); }

void SftUsbSource::Start() {
    if (thread_.joinable()) return;
    stop_ = false;
    thread_ = std::thread(&SftUsbSource::Run, this);
}

void SftUsbSource::Stop() {
    if (!thread_.joinable()) return;
    stop_ = true;
    thread_.join();
    // 收流线程退出后再发，避免和它的读写交错；发不出去（线已拔掉）也无妨
    channel_->Write(reinterpret_cast<const uint8_t*>(kGoodbye), sizeof(kGoodbye), 100);
}

void SftUsbSource::Run() {
    receiver_.SetConnected(true);
    receiver_.Status(L("已通过 USB 连接，在游戏机上打开一款游戏…", "已透過 USB 連線，在遊戲機上打開一款遊戲…",
                       "Connected over USB. Open a game on the console…"));
    receiver_.BeginConnection();
    const std::string why = receiver_.Run(*channel_);
    receiver_.SetConnected(false);
    if (stop_) return;
    // USB 断开（拔线、游戏机睡眠）没法在这里重连：同一个设备描述符已经失效，由界面提示后退出播放
    Logf(LogLevel::Warn, "USB 收流结束：%s", why.c_str());
    receiver_.Status(Format(L("USB 连接已断开（%s）", "USB 連線已中斷（%s）", "USB connection lost (%s)"), why.c_str()));
}

}  // namespace nssft
