#include "sft_pad.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

namespace nssft::pad {

namespace {

// 状态没变时多久重发一次（游戏机 0.5 秒收不到就松开）；略小于 100 ms，免得定时器早醒一点就要多等一轮
constexpr int64_t kRepeatMs = 90;
constexpr auto kAttachedWait = std::chrono::milliseconds(100);
// 触屏摇杆的死区（界面上已经按摇杆半径归一化）
constexpr double kTouchDeadZone = 0.06;
// 没接上时多久看一次游戏机接不接受手柄
constexpr auto kIdleWait = std::chrono::milliseconds(250);
// USB 上游戏机这一刻没在收：隔一会再试
constexpr auto kRetryWait = std::chrono::milliseconds(20);

int64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

void Put32(uint8_t* p, uint32_t v) {
    for (int i = 0; i < 4; ++i) p[i] = uint8_t(v >> (8 * i));
}

void Put64(uint8_t* p, uint64_t v) {
    for (int i = 0; i < 8; ++i) p[i] = uint8_t(v >> (8 * i));
}

uint32_t Get32(const uint8_t* p) {
    uint32_t v = 0;
    for (int i = 0; i < 4; ++i) v |= uint32_t(p[i]) << (8 * i);
    return v;
}

uint64_t Get64(const uint8_t* p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v |= uint64_t(p[i]) << (8 * i);
    return v;
}

KeyTarget Button(uint64_t b, bool keyboard = false) {
    KeyTarget t;
    t.button = b;
    t.keyboard = keyboard;
    return t;
}

KeyTarget KeyStick(int stick, int dx, int dy) {
    KeyTarget t;
    t.stick = stick;
    t.dx = dx;
    t.dy = dy;
    t.keyboard = true;
    return t;
}

}  // namespace

void BuildMessage(bool on, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry, uint8_t out[kMessageSize]) {
    std::memcpy(out, "SFTI", 4);
    Put32(out + 4, on ? kFlagPadOn : 0);
    Put64(out + 8, on ? buttons : 0);
    Put32(out + 16, uint32_t(on ? lx : 0));
    Put32(out + 20, uint32_t(on ? ly : 0));
    Put32(out + 24, uint32_t(on ? rx : 0));
    Put32(out + 28, uint32_t(on ? ry : 0));
}

bool ParseMessage(const uint8_t* p, size_t n, Message* out) {
    if (n < kMessageSize || std::memcmp(p, "SFTI", 4) != 0) return false;
    out->flags = Get32(p + 4);
    out->buttons = Get64(p + 8);
    out->lx = int32_t(Get32(p + 16));
    out->ly = int32_t(Get32(p + 20));
    out->rx = int32_t(Get32(p + 24));
    out->ry = int32_t(Get32(p + 28));
    return true;
}

void Stick(double x, double y, double deadZone, int32_t* outX, int32_t* outY) {
    const double full = kStickMax;
    const double sx = x * full;
    const double sy = -y * full;
    const double m = std::sqrt(sx * sx + sy * sy);
    const double dead = deadZone * full;
    if (!(m > dead)) {  // 也挡住 NaN
        *outX = *outY = 0;
        return;
    }
    double k = (m - dead) / (full - dead) / m * full;
    if (m * k > full) k = full / m;  // 斜向推满时不超出圆
    *outX = int32_t(std::max(-full, std::min(full, sx * k)));
    *outY = int32_t(std::max(-full, std::min(full, sy * k)));
}

std::string ButtonNames(uint64_t buttons) {
    static const struct {
        uint64_t bit;
        const char* name;
    } kNames[] = {{kA, "A"},       {kB, "B"},         {kX, "X"},       {kY, "Y"},         {kL, "L"},
                  {kR, "R"},       {kZL, "ZL"},       {kZR, "ZR"},     {kL3, "L3"},       {kR3, "R3"},
                  {kPlus, "+"},    {kMinus, "−"}, {kUp, "↑"}, {kDown, "↓"}, {kLeft, "←"},
                  {kRight, "→"}, {kHome, "HOME"}, {kCapture, "◎"}};
    std::string out;
    for (const auto& n : kNames) {
        if (!(buttons & n.bit)) continue;
        if (!out.empty()) out += ' ';
        out += n.name;
    }
    return out;
}

KeyTarget MapKey(int32_t code, bool faceByLabel) {
    switch (code) {
        // 手柄：A/B/X/Y 是 Xbox 式的位置（下、右、左、上）；按位置时下面那个是游戏机的 B
        case key::kButtonA: return Button(faceByLabel ? kA : kB);
        case key::kButtonB: return Button(faceByLabel ? kB : kA);
        case key::kButtonX: return Button(faceByLabel ? kX : kY);
        case key::kButtonY: return Button(faceByLabel ? kY : kX);
        case key::kButtonL1: return Button(kL);
        case key::kButtonR1: return Button(kR);
        case key::kButtonL2: return Button(kZL);
        case key::kButtonR2: return Button(kZR);
        case key::kButtonThumbL: return Button(kL3);
        case key::kButtonThumbR: return Button(kR3);
        case key::kButtonStart: return Button(kPlus);
        case key::kButtonSelect: return Button(kMinus);
        case key::kButtonMode: return Button(kHome);
        case key::kButtonZ: return Button(kCapture);  // 游戏机手柄的截图键在系统里多半报成 Z
        // 十字键：手柄的十字键和键盘的方向键是同样的键码
        case key::kDpadUp: return Button(kUp);
        case key::kDpadDown: return Button(kDown);
        case key::kDpadLeft: return Button(kLeft);
        case key::kDpadRight: return Button(kRight);
        // 键盘（和常见模拟器的默认键位一样）：WASD 左摇杆、IJKL 右摇杆，Z X C V 是 A B X Y
        case key::Letter('W'): return KeyStick(0, 0, 1);
        case key::Letter('S'): return KeyStick(0, 0, -1);
        case key::Letter('A'): return KeyStick(0, -1, 0);
        case key::Letter('D'): return KeyStick(0, 1, 0);
        case key::Letter('I'): return KeyStick(1, 0, 1);
        case key::Letter('K'): return KeyStick(1, 0, -1);
        case key::Letter('J'): return KeyStick(1, -1, 0);
        case key::Letter('L'): return KeyStick(1, 1, 0);
        case key::Letter('F'): return Button(kL3, true);
        case key::Letter('H'): return Button(kR3, true);
        case key::Letter('Z'): return Button(kA, true);
        case key::Letter('X'): return Button(kB, true);
        case key::Letter('C'): return Button(kX, true);
        case key::Letter('V'): return Button(kY, true);
        case key::Letter('E'): return Button(kL, true);
        case key::Letter('Q'): return Button(kZL, true);
        case key::Letter('U'): return Button(kR, true);
        case key::Letter('O'): return Button(kZR, true);
        case key::kEquals:
        case key::kPlus:
        case key::kNumpadAdd: return Button(kPlus, true);
        case key::kMinus:
        case key::kNumpadSubtract: return Button(kMinus, true);
        case key::kMoveHome: return Button(kHome, true);
        default: return KeyTarget();
    }
}

// ---------------------------------------------------------------- PadState

void PadState::Tune(double deadZone, double triggerPoint) {
    std::lock_guard<std::mutex> lock(mutex_);
    dead_ = std::max(0.0, std::min(0.5, deadZone));
    point_ = std::max(0.05, std::min(0.95, triggerPoint));
    Recompute();
}

void PadState::SetFaceByLabel(bool byLabel) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (faceByLabel_ == byLabel) return;
    faceByLabel_ = byLabel;
    held_.clear();  // 按住的键换了意思：先全松开
    Recompute();
}

bool PadState::Key(int32_t keyCode, bool down) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!MapKey(keyCode, faceByLabel_).Mapped()) return false;
    auto it = std::find(held_.begin(), held_.end(), keyCode);
    if (down) {
        if (it == held_.end()) held_.push_back(keyCode);
        seen_ = true;
    } else if (it != held_.end()) {
        held_.erase(it);
    }
    Recompute();
    return true;
}

bool PadState::SetAxes(const Axes& a) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto take = [](double v, double* dst) {
        if (!std::isnan(v)) *dst = v;
    };
    take(a.lx, &axes_.lx);
    take(a.ly, &axes_.ly);
    take(a.rx, &axes_.rx);
    take(a.ry, &axes_.ry);
    take(a.lt, &axes_.lt);
    take(a.rt, &axes_.rt);
    take(a.hx, &axes_.hx);
    take(a.hy, &axes_.hy);
    const Snapshot before = snap_;
    Recompute();
    const bool changed = before.buttons != snap_.buttons || before.lx != snap_.lx || before.ly != snap_.ly ||
                         before.rx != snap_.rx || before.ry != snap_.ry;
    if (changed && !snap_.Idle()) seen_ = true;
    return changed;
}

bool PadState::SetTouch(uint64_t buttons, double lx, double ly, double rx, double ry) {
    std::lock_guard<std::mutex> lock(mutex_);
    touchButtons_ = buttons;
    const double v[4] = {lx, ly, rx, ry};
    for (int i = 0; i < 4; ++i) touch_[i] = std::isnan(v[i]) ? 0 : std::max(-1.0, std::min(1.0, v[i]));
    const Snapshot before = snap_;
    Recompute();
    return before.buttons != snap_.buttons || before.lx != snap_.lx || before.ly != snap_.ly ||
           before.rx != snap_.rx || before.ry != snap_.ry;
}

void PadState::Reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    held_.clear();
    axes_ = Axes{0, 0, 0, 0, 0, 0, 0, 0};
    touchButtons_ = 0;
    for (double& t : touch_) t = 0;
    snap_ = Snapshot();
}

PadState::Snapshot PadState::Get() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return snap_;
}

void PadState::Recompute() {
    uint64_t buttons = 0;
    int kx[2] = {0, 0};
    int ky[2] = {0, 0};
    for (int32_t code : held_) {
        const KeyTarget t = MapKey(code, faceByLabel_);
        buttons |= t.button;
        if (t.stick >= 0) {
            kx[t.stick] += t.dx;
            ky[t.stick] += t.dy;
        }
    }
    // 十字键报成轴的手柄（帽子开关）
    if (axes_.hx < -0.5) buttons |= kLeft;
    if (axes_.hx > 0.5) buttons |= kRight;
    if (axes_.hy < -0.5) buttons |= kUp;
    if (axes_.hy > 0.5) buttons |= kDown;
    // 模拟扳机按过按下点就算 ZL / ZR（很多手柄同时还会报 L2 / R2 键）
    if (axes_.lt > point_) buttons |= kZL;
    if (axes_.rt > point_) buttons |= kZR;
    buttons |= touchButtons_;

    // 摇杆：谁在推就用谁的，优先级 键盘 > 触屏 > 手柄
    int32_t sticks[4];
    Stick(axes_.lx, axes_.ly, dead_, &sticks[0], &sticks[1]);
    Stick(axes_.rx, axes_.ry, dead_, &sticks[2], &sticks[3]);
    for (int s = 0; s < 2; ++s) {
        int32_t x = 0, y = 0;
        Stick(touch_[s * 2], touch_[s * 2 + 1], kTouchDeadZone, &x, &y);  // 手指一碰就有一点偏移：留一个小死区
        if (x != 0 || y != 0) {
            sticks[s * 2] = x;
            sticks[s * 2 + 1] = y;
        }
    }
    // 键盘推摇杆：推满；斜着按两个方向时按圆收一点，和真摇杆一样
    for (int s = 0; s < 2; ++s) {
        const int dx = std::max(-1, std::min(1, kx[s]));
        const int dy = std::max(-1, std::min(1, ky[s]));
        if (dx == 0 && dy == 0) continue;
        const double k = (dx != 0 && dy != 0) ? kStickMax / std::sqrt(2.0) : double(kStickMax);
        sticks[s * 2] = int32_t(dx * k);
        sticks[s * 2 + 1] = int32_t(dy * k);
    }
    snap_.buttons = buttons;
    snap_.lx = sticks[0];
    snap_.ly = sticks[1];
    snap_.rx = sticks[2];
    snap_.ry = sticks[3];
}

// ---------------------------------------------------------------- PadSender

PadSender::PadSender(PadState& state, SendFn send, TakesFn takes)
    : state_(state), send_(std::move(send)), takes_(std::move(takes)) {
    thread_ = std::thread([this] { Run(); });
}

PadSender::~PadSender() { Stop(); }

void PadSender::SetEnabled(bool on) {
    if (enabled_.exchange(on) == on) return;
    if (!on) {
        state_.Reset();
        state_.ClearSeen();
    }
    Poke();
}

void PadSender::SetDevicePresent(bool present) {
    if (devicePresent_.exchange(present) == present) return;
    if (!present) state_.Reset();  // 拔掉时按着的键不会再报松开
    Poke();
}

void PadSender::SetTouchShown(bool shown) {
    if (touchShown_.exchange(shown) == shown) return;
    if (!shown) state_.SetTouch(0, 0, 0, 0, 0);
    Poke();
}

void PadSender::SetPlaying(bool on) {
    if (playing_.exchange(on) == on) return;
    if (!on) state_.Reset();
    Poke();
}

void PadSender::Poke() {
    std::lock_guard<std::mutex> lock(mutex_);
    dirty_ = true;
    cv_.notify_all();
}

void PadSender::Stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stop_ && !thread_.joinable()) return;
        stop_ = true;
        cv_.notify_all();
    }
    if (thread_.joinable()) thread_.join();
}

bool PadSender::ShouldAttach() const {
    return enabled_ && (devicePresent_ || touchShown_ || state_.SeenInput()) && takes_ && takes_();
}

void PadSender::Run() {
    uint8_t last[kMessageSize] = {};
    bool haveLast = false;
    int64_t lastMs = 0;
    bool retry = false;
    uint8_t m[kMessageSize];
    while (true) {
        {
            std::unique_lock<std::mutex> lock(mutex_);
            if (!dirty_ && !stop_) {
                cv_.wait_for(lock, retry ? kRetryWait : attached_ ? kAttachedWait : kIdleWait);
            }
            if (stop_) break;
            dirty_ = false;
        }
        retry = false;
        if (!ShouldAttach()) {
            if (attached_) {
                BuildMessage(false, 0, 0, 0, 0, 0, m);
                send_(m, sizeof(m));
                attached_ = false;
                ++sent_;
            }
            haveLast = false;
            continue;
        }
        if (playing_) {
            const PadState::Snapshot s = state_.Get();
            BuildMessage(true, s.buttons, s.lx, s.ly, s.rx, s.ry, m);
        } else {
            BuildMessage(true, 0, 0, 0, 0, 0, m);
        }
        const int64_t now = NowMs();
        if (haveLast && now - lastMs < kRepeatMs && std::memcmp(m, last, sizeof(m)) == 0) continue;
        if (send_(m, sizeof(m))) {
            std::memcpy(last, m, sizeof(m));
            haveLast = true;
            lastMs = now;
            attached_ = true;
            ++sent_;
        } else {
            haveLast = false;
            retry = true;
        }
    }
    // 会话结束：游戏机上拔掉这个手柄（连接已经断了也没关系，游戏机 0.5 秒后自己松开）
    if (attached_) {
        BuildMessage(false, 0, 0, 0, 0, 0, m);
        send_(m, sizeof(m));
        attached_ = false;
        ++sent_;
    }
}

}  // namespace nssft::pad
