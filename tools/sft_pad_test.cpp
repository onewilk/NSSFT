// 手柄（core/sft_pad.*）的单元测试：SFTI 消息格式、按键对应、摇杆死区、键盘摇杆、发送线程的重发与“拔掉”
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#include "../core/sft_pad.h"

using namespace nssft::pad;

static int g_failed = 0;
#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            std::printf("  ✗ %s:%d  %s\n", __FILE__, __LINE__, #cond); \
            ++g_failed;                                                 \
        }                                                               \
    } while (0)

static void TestMessage() {
    std::printf("SFTI 消息：32 字节小端，字段位置与 SFT 的 PadMsg 一致\n");
    uint8_t m[kMessageSize];
    BuildMessage(true, kA | kZR | kHome, 100, -200, 32767, -32767, m);
    CHECK(std::memcmp(m, "SFTI", 4) == 0);
    CHECK(m[4] == 1 && m[5] == 0 && m[6] == 0 && m[7] == 0);
    CHECK(m[8] == 0x01 && m[9] == 0x02 && m[10] == 0x04);  // A=bit0, ZR=bit9, HOME=bit18
    CHECK(m[16] == 100 && m[17] == 0);
    CHECK(m[20] == 0x38 && m[21] == 0xFF && m[22] == 0xFF && m[23] == 0xFF);  // -200
    Message p;
    CHECK(ParseMessage(m, sizeof(m), &p));
    CHECK(p.flags == 1 && p.buttons == (kA | kZR | kHome));
    CHECK(p.lx == 100 && p.ly == -200 && p.rx == 32767 && p.ry == -32767);
    BuildMessage(false, kA, 5, 5, 5, 5, m);  // 拔掉：其余都写 0
    CHECK(ParseMessage(m, sizeof(m), &p));
    CHECK(p.flags == 0 && p.buttons == 0 && p.lx == 0 && p.ry == 0);
    CHECK(!ParseMessage(m, 31, &p));
}

static void TestMapping() {
    std::printf("按键对应：A/B/X/Y 按位置（默认）或按标签；其余键；键盘\n");
    CHECK(MapKey(key::kButtonA, false).button == kB);  // 下面那个是 B
    CHECK(MapKey(key::kButtonB, false).button == kA);
    CHECK(MapKey(key::kButtonX, false).button == kY);
    CHECK(MapKey(key::kButtonY, false).button == kX);
    CHECK(MapKey(key::kButtonA, true).button == kA);
    CHECK(MapKey(key::kButtonY, true).button == kY);
    CHECK(MapKey(key::kButtonSelect, false).button == kMinus);
    CHECK(MapKey(key::kButtonStart, false).button == kPlus);
    CHECK(MapKey(key::kButtonMode, false).button == kHome);
    CHECK(MapKey(key::kButtonL2, false).button == kZL);
    CHECK(MapKey(key::kButtonThumbR, false).button == kR3);
    CHECK(MapKey(key::kDpadLeft, false).button == kLeft);
    CHECK(MapKey(key::Letter('Z'), false).button == kA && MapKey(key::Letter('Z'), false).keyboard);
    CHECK(MapKey(key::Letter('W'), false).stick == 0 && MapKey(key::Letter('W'), false).dy == 1);
    CHECK(MapKey(key::Letter('L'), false).stick == 1 && MapKey(key::Letter('L'), false).dx == 1);
    CHECK(!MapKey(2054 /* Enter */, false).Mapped());
    CHECK(!MapKey(2070 /* Esc */, false).Mapped());
}

static void TestStick() {
    std::printf("摇杆：圆形死区、拉伸到满量程、y 轴翻转、斜向不超出圆\n");
    int32_t x = 1, y = 1;
    Stick(0.05, -0.05, kDefaultDeadZone, &x, &y);
    CHECK(x == 0 && y == 0);
    Stick(1.0, 0, kDefaultDeadZone, &x, &y);
    CHECK(x == 32767 && y == 0);
    Stick(0, -1.0, kDefaultDeadZone, &x, &y);  // 系统里 y 向下为正：推上去是 -1
    CHECK(x == 0 && y == 32767);
    Stick(1.0, 1.0, kDefaultDeadZone, &x, &y);
    CHECK(std::abs(std::sqrt(double(x) * x + double(y) * y) - 32767) < 2);
    CHECK(x > 0 && y < 0);
    Stick(0.5, 0, kDefaultDeadZone, &x, &y);
    CHECK(x > 14800 && x < 15100);  // (0.5-0.08)/(1-0.08) 满量程 ≈ 14958
    Stick(NAN, 0, kDefaultDeadZone, &x, &y);
    CHECK(x == 0 && y == 0);
}

static void TestState() {
    std::printf("状态：按住的键、两个键对应同一个按键、键盘摇杆、轴、换布局时松开\n");
    PadState s;
    CHECK(!s.SeenInput());
    CHECK(!s.Key(2054, true));  // 没对应的键：不接管
    CHECK(!s.SeenInput());
    CHECK(s.Key(key::kButtonA, true));
    CHECK(s.SeenInput());
    CHECK(s.Get().buttons == kB);
    CHECK(s.Key(key::Letter('X'), true));  // 键盘的 X 也是 B
    CHECK(s.Key(key::kButtonA, false));
    CHECK(s.Get().buttons == kB);  // 键盘那个还按着
    CHECK(s.Key(key::Letter('X'), false));
    CHECK(s.Get().buttons == 0);

    s.Key(key::Letter('W'), true);
    CHECK(s.Get().lx == 0 && s.Get().ly == 32767);
    s.Key(key::Letter('D'), true);
    const auto d = s.Get();
    CHECK(d.lx == d.ly && d.lx > 23000 && d.lx < 23300);  // 斜向按圆收
    s.Key(key::Letter('W'), false);
    s.Key(key::Letter('D'), false);
    CHECK(s.Get().Idle());

    Axes a{0.6, 0, NAN, NAN, 0.5, 0.1, 0, -1};
    CHECK(s.SetAxes(a));
    auto g = s.Get();
    CHECK(g.lx > 0 && g.ly == 0);
    CHECK(g.buttons == (kZL | kUp));  // 左扳机过了 30%，十字键向上
    Axes b{NAN, NAN, 0, -1, NAN, NAN, NAN, NAN};  // 只报了右摇杆：其余保留
    CHECK(s.SetAxes(b));
    g = s.Get();
    CHECK(g.lx > 0 && g.ry == 32767 && g.buttons == (kZL | kUp));
    CHECK(!s.SetAxes(b));  // 没变
    s.Key(key::Letter('J'), true);  // 键盘推右摇杆时盖过手柄的右摇杆
    CHECK(s.Get().rx == -32767 && s.Get().ry == 0);
    s.Key(key::Letter('J'), false);
    s.Reset();
    CHECK(s.Get().Idle());

    s.Key(key::kButtonA, true);
    s.SetFaceByLabel(true);  // 换布局：按着的键先全松开
    CHECK(s.Get().buttons == 0);
    s.Key(key::kButtonA, true);
    CHECK(s.Get().buttons == kA);
}

static void TestTouch() {
    std::printf("触屏手柄：按键合并、摇杆优先级（键盘 > 触屏 > 手柄）、小死区\n");
    PadState s;
    Axes a{0.5, 0, NAN, NAN, NAN, NAN, NAN, NAN};
    s.SetAxes(a);
    const int32_t padLx = s.Get().lx;
    CHECK(padLx > 0);
    CHECK(s.SetTouch(kA | kZR, -1, 0, 0, -1));
    auto g = s.Get();
    CHECK(g.buttons == (kA | kZR));
    CHECK(g.lx == -32767 && g.ly == 0);  // 触屏的左摇杆盖过手柄
    CHECK(g.rx == 0 && g.ry == 32767);
    s.Key(key::kButtonB, true);
    CHECK(s.Get().buttons == (kA | kZR));  // 手柄的 B 键（按位置是 A）和触屏的 A 合并
    s.Key(key::kButtonY, true);
    CHECK(s.Get().buttons == (kA | kZR | kX));
    s.Key(key::Letter('D'), true);  // 键盘优先
    CHECK(s.Get().lx == 32767);
    s.Key(key::Letter('D'), false);
    CHECK(s.SetTouch(0, 0.03, 0.02, 0, 0));  // 手指刚碰到：死区内不算
    g = s.Get();
    CHECK(g.lx == padLx && g.ry == 0);  // 触屏没推时回到手柄的摇杆
    CHECK(g.buttons == (kA | kX));  // 手柄还按着 B、Y
}

struct Sink {
    std::mutex m;
    std::vector<Message> got;
    std::vector<int64_t> atMs;
    std::atomic<bool> fail{false};
    bool Send(const uint8_t* p, size_t n) {
        if (fail) return false;
        Message msg;
        if (!ParseMessage(p, n, &msg)) return false;
        std::lock_guard<std::mutex> lock(m);
        got.push_back(msg);
        atMs.push_back(std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now().time_since_epoch())
                           .count());
        return true;
    }
    size_t Count() {
        std::lock_guard<std::mutex> lock(m);
        return got.size();
    }
    Message Last() {
        std::lock_guard<std::mutex> lock(m);
        return got.empty() ? Message() : got.back();
    }
};

static void Sleep(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

static void TestSender() {
    std::printf("发送线程：有手柄且游戏机接受时才接上、变了马上发、每 100 ms 重发、关掉和结束时拔掉\n");
    PadState s;
    Sink sink;
    std::atomic<bool> takes{false};
    PadSender sender(
        s, [&](const uint8_t* p, size_t n) { return sink.Send(p, n); }, [&] { return takes.load(); });
    sender.SetEnabled(true);
    Sleep(150);
    CHECK(sink.Count() == 0);  // 没有手柄、游戏机也没要：什么都不发
    sender.SetDevicePresent(true);
    Sleep(150);
    CHECK(sink.Count() == 0);  // 游戏机没打开 “Controls from the viewer”
    takes = true;
    Sleep(400);  // 没接上时 250 ms 看一次
    CHECK(sender.Attached());
    const size_t before = sink.Count();
    CHECK(before >= 1 && sink.Last().flags == 1 && sink.Last().buttons == 0);

    s.Key(key::kButtonB, true);
    sender.Poke();
    Sleep(15);
    CHECK(sink.Last().buttons == kA);  // 变了马上发

    const size_t c0 = sink.Count();
    Sleep(1000);
    const size_t repeats = sink.Count() - c0;
    CHECK(repeats >= 8 && repeats <= 12);  // 没变时大约每 100 ms 一条
    {
        std::lock_guard<std::mutex> lock(sink.m);
        int64_t worst = 0;
        for (size_t i = c0 + 1; i < sink.atMs.size(); ++i) worst = std::max(worst, sink.atMs[i] - sink.atMs[i - 1]);
        CHECK(worst < 200);
    }

    sender.SetPlaying(false);  // 菜单开着：接着，但什么都不按
    Sleep(20);
    CHECK(sink.Last().flags == 1 && sink.Last().buttons == 0);
    sender.SetPlaying(true);

    sender.SetEnabled(false);  // 关掉：拔掉
    Sleep(20);
    CHECK(sink.Last().flags == 0);
    CHECK(!sender.Attached());
    const size_t off = sink.Count();
    Sleep(300);
    CHECK(sink.Count() == off);  // 拔掉后不再发

    // 键盘：没有手柄设备时，按过有对应的键才接上
    sender.SetDevicePresent(false);
    sender.SetEnabled(true);
    Sleep(300);
    CHECK(!sender.Attached());
    s.Key(key::Letter('Z'), true);
    sender.Poke();
    Sleep(20);
    CHECK(sender.Attached() && sink.Last().buttons == kA);

    // USB 上一时写不出去：很快重试
    sink.fail = true;
    s.Key(key::Letter('Z'), false);
    sender.Poke();
    Sleep(30);
    sink.fail = false;
    Sleep(40);
    CHECK(sink.Last().buttons == 0);

    // 触屏手柄显示着也算有手柄
    sender.SetEnabled(false);
    Sleep(20);
    sender.SetEnabled(true);
    sender.SetTouchShown(true);
    Sleep(300);
    CHECK(sender.Attached());
    s.SetTouch(kHome, 0, 0, 0, 0);
    sender.Poke();
    Sleep(20);
    CHECK(sink.Last().buttons == kHome);
    sender.SetTouchShown(false);  // 收起：触屏的键松开，没有别的手柄就拔掉
    Sleep(30);
    CHECK(sink.Last().flags == 0);

    sender.Stop();  // 结束：拔掉
    CHECK(sink.Last().flags == 0);
    const size_t end = sink.Count();
    Sleep(150);
    CHECK(sink.Count() == end);
}

int main() {
    TestMessage();
    TestMapping();
    TestStick();
    TestState();
    TestTouch();
    TestSender();
    if (g_failed) {
        std::printf("sft_pad_test: %d 项失败\n", g_failed);
        return 1;
    }
    std::printf("sft_pad_test: 全部通过\n");
    return 0;
}
