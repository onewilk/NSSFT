// 客户端手柄（SFT 0.7.20 起；游戏机上的 SFT 打开 “Controls from the viewer” 后，包头带 kFlagInput）：
// 本机的手柄、键盘和触屏手柄 → 游戏机上的一个手柄。
//
//   PadState   按键和摇杆的当前状态（UI 线程写入，发送线程读取）：按键码 → 游戏机按键，摇杆死区，扳机按下点
//   PadSender  一个小线程：状态一变就发一条 SFTI，之后每 100 ms 重发（游戏机 0.5 秒收不到就松开手柄）；
//              不再用手柄时发一次 flags=0，游戏机拔掉这个虚拟手柄
//
// 一个客户端在游戏机上只对应一个手柄（消息里没有手柄编号）：本机接了几个手柄、键盘、触屏手柄，都合并成这一个。
// SFTI 消息（32 字节，小端，与 SFT 的 PadMsg 一致）：
//   0  "SFTI"   4  u32 flags（1 = 有手柄，0 = 拔掉）   8  u64 按键（HidNpadButton 位，另加 bit 18 HOME、bit 19 截图）
//   16 i32 lx   20 i32 ly   24 i32 rx   28 i32 ry（-32767..32767，向上为正）
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace nssft::pad {

// 游戏机读的按键位（HidNpadButton）
constexpr uint64_t kA = 1ull << 0;
constexpr uint64_t kB = 1ull << 1;
constexpr uint64_t kX = 1ull << 2;
constexpr uint64_t kY = 1ull << 3;
constexpr uint64_t kL3 = 1ull << 4;
constexpr uint64_t kR3 = 1ull << 5;
constexpr uint64_t kL = 1ull << 6;
constexpr uint64_t kR = 1ull << 7;
constexpr uint64_t kZL = 1ull << 8;
constexpr uint64_t kZR = 1ull << 9;
constexpr uint64_t kPlus = 1ull << 10;
constexpr uint64_t kMinus = 1ull << 11;
constexpr uint64_t kLeft = 1ull << 12;
constexpr uint64_t kUp = 1ull << 13;
constexpr uint64_t kRight = 1ull << 14;
constexpr uint64_t kDown = 1ull << 15;
constexpr uint64_t kHome = 1ull << 18;
constexpr uint64_t kCapture = 1ull << 19;

constexpr size_t kMessageSize = 32;
constexpr uint32_t kFlagPadOn = 1;
constexpr int32_t kStickMax = 32767;
// 和 SFT 的 PC / Android 客户端一样的手感
constexpr double kDefaultDeadZone = 0.08;
constexpr double kDefaultTriggerPoint = 0.30;

// on 为 false：本机没有手柄了，游戏机拔掉虚拟手柄（其余字段写 0）
void BuildMessage(bool on, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry, uint8_t out[kMessageSize]);

struct Message {
    uint32_t flags = 0;
    uint64_t buttons = 0;
    int32_t lx = 0, ly = 0, rx = 0, ry = 0;
};
// 测试和模拟服务端用
bool ParseMessage(const uint8_t* p, size_t n, Message* out);

// 一个摇杆：x、y 是系统报的值（-1..1，y 向下为正），换成游戏机的（-32767..32767，向上为正）。
// 小的圆形死区（摇杆静止时会漂几个百分点），死区外拉伸到满量程
void Stick(double x, double y, double deadZone, int32_t* outX, int32_t* outY);

// 按键的名字（“A ZL 上”这种，给“正在按”的测试框看）
std::string ButtonNames(uint64_t buttons);

// 鸿蒙的按键码（@kit.InputKit 的 KeyCode）
namespace key {
constexpr int32_t kDpadUp = 2012, kDpadDown = 2013, kDpadLeft = 2014, kDpadRight = 2015;
constexpr int32_t kA = 2017;  // 字母键 A..Z 连续：kA + 0..25
constexpr int32_t kMinus = 2057, kEquals = 2058, kPlus = 2066, kMoveHome = 2081;
constexpr int32_t kNumpadSubtract = 2115, kNumpadAdd = 2116;
constexpr int32_t kButtonA = 2301, kButtonB = 2302, kButtonC = 2303, kButtonX = 2304, kButtonY = 2305,
                  kButtonZ = 2306, kButtonL1 = 2307, kButtonR1 = 2308, kButtonL2 = 2309, kButtonR2 = 2310,
                  kButtonSelect = 2311, kButtonStart = 2312, kButtonMode = 2313, kButtonThumbL = 2314,
                  kButtonThumbR = 2315;
constexpr int32_t Letter(char c) { return kA + (c - 'A'); }
}  // namespace key

// 一个按键码在游戏机上是什么：按键，或者键盘模拟的摇杆方向
struct KeyTarget {
    uint64_t button = 0;
    // 键盘模拟摇杆：stick 0 左 / 1 右，dx、dy 是方向（游戏机坐标，向上为正）
    int stick = -1;
    int dx = 0, dy = 0;
    bool keyboard = false;  // 来自键盘（不是手柄的按键）
    bool Mapped() const { return button != 0 || stick >= 0; }
};
// faceByLabel：手柄的 A/B/X/Y 按标签对应（A 就是 A）；默认按位置（下面那个是 B，和游戏机手柄的位置一样）
KeyTarget MapKey(int32_t keyCode, bool faceByLabel);

// 轴的输入（某个轴这次没报时传 NaN，保留上一次的值）
struct Axes {
    double lx, ly, rx, ry;  // 摇杆 -1..1，y 向下为正
    double lt, rt;          // 扳机 0..1
    double hx, hy;          // 十字键（帽子开关）-1..1，y 向下为正
};

class PadState {
public:
    // 死区 0..0.5，扳机按下点 0.05..0.95
    void Tune(double deadZone, double triggerPoint);
    void SetFaceByLabel(bool byLabel);
    // 一个键按下或松开；返回这个键有没有对应（有对应的键在串流时由手柄功能接管，不再给界面）
    bool Key(int32_t keyCode, bool down);
    // 返回游戏机看到的状态有没有变
    bool SetAxes(const Axes& a);
    // 触屏手柄的整体状态：按键位 + 两个摇杆（-1..1，y 向下为正，界面已经按摇杆半径归一化）
    bool SetTouch(uint64_t buttons, double lx, double ly, double rx, double ry);
    // 松开一切（菜单打开、切后台、换布局时）
    void Reset();
    // 最近有没有收到过有对应的输入（有了才在游戏机上接上虚拟手柄，免得没手柄时也占一个手柄位）
    bool SeenInput() const { return seen_; }
    void ClearSeen() { seen_ = false; }

    struct Snapshot {
        uint64_t buttons = 0;
        int32_t lx = 0, ly = 0, rx = 0, ry = 0;
        bool Idle() const { return buttons == 0 && lx == 0 && ly == 0 && rx == 0 && ry == 0; }
    };
    Snapshot Get() const;

private:
    void Recompute();  // 持锁：按住的键 + 轴 → snap_

    mutable std::mutex mutex_;
    std::vector<int32_t> held_;  // 按住的键（有对应的）
    bool faceByLabel_ = false;
    double dead_ = kDefaultDeadZone;
    double point_ = kDefaultTriggerPoint;
    Axes axes_{0, 0, 0, 0, 0, 0, 0, 0};
    uint64_t touchButtons_ = 0;
    double touch_[4] = {0, 0, 0, 0};
    Snapshot snap_;
    std::atomic<bool> seen_{false};
};

// 发送线程。send：把一条消息写到连接上（任意线程调用，返回是否写出）；takes：游戏机现在接不接受手柄
class PadSender {
public:
    using SendFn = std::function<bool(const uint8_t* data, size_t size)>;
    using TakesFn = std::function<bool()>;

    PadSender(PadState& state, SendFn send, TakesFn takes);
    ~PadSender();

    // 用户打开了手柄功能，且播放页在前台。关掉时发一次“拔掉”
    void SetEnabled(bool on);
    // 本机现在连着手柄（系统的输入设备列表里有）
    void SetDevicePresent(bool present);
    // 触屏手柄显示着（显示着就算有手柄，接上游戏机）
    void SetTouchShown(bool shown);
    // false：菜单或对话框开着，手柄挂在游戏机上但什么都不按（按键给菜单用）
    void SetPlaying(bool on);
    // 状态变了，马上发
    void Poke();
    // 会话结束前调用：接着的话发一次“拔掉”，然后结束线程
    void Stop();

    bool Attached() const { return attached_; }
    uint64_t Sent() const { return sent_; }

private:
    void Run();
    bool ShouldAttach() const;

    PadState& state_;
    const SendFn send_;
    const TakesFn takes_;
    std::atomic<bool> enabled_{false};
    std::atomic<bool> devicePresent_{false};
    std::atomic<bool> touchShown_{false};
    std::atomic<bool> playing_{true};
    std::atomic<bool> attached_{false};
    std::atomic<uint64_t> sent_{0};

    std::mutex mutex_;
    std::condition_variable cv_;
    bool dirty_ = false;
    bool stop_ = false;
    std::thread thread_;
};

}  // namespace nssft::pad
