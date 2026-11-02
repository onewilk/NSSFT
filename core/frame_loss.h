// 视频丢帧检测。
// SFT 的每个视频包都带序号（包头 kind 字段），游戏机端的发送线程在网络忙时会跳过帧，客户端看到的就是序号断档。
// 断档之后的 P 帧参考链已经断了，照常解码会花屏到下一个关键帧，所以要定格并请求关键帧（SFTK）。
// FrameGapDetector 仍然按时间戳估计帧间隔，给上屏卡顿判断用；丢帧次数以序号为准。
#pragma once

#include <cstdint>

namespace nssft {

// 丢失原因（统计分类用）
enum class LossCause : int {
    SequenceGap = 0,  // 视频包序号断档（游戏机端跳过了帧）
    Resync = 1,       // 包头失步，丢了一段字节后重新对齐
    Oversize = 2,     // 包超过解码器输入缓冲，只能丢弃
    Count = 3,
};

class FrameGapDetector {
public:
    // 每收到一帧视频调用一次；返回估计丢掉的帧数，0 表示连续
    int OnFrame(uint64_t timestampUs);
    void Reset();
    // 估计的正常帧间隔（微秒）：60 帧/秒的游戏约 16667，30 帧/秒约 33333。
    // 初值取 30 帧/秒：从大往小学不会在开头把 30 帧/秒的正常间隔误报成断档
    int64_t IntervalUs() const { return intervalUs_; }

private:
    void Learn(int64_t deltaUs);

    static constexpr int kWindow = 31;
    bool hasLast_ = false;
    uint64_t lastUs_ = 0;
    int64_t window_[kWindow] = {};
    int count_ = 0;
    int next_ = 0;
    int64_t intervalUs_ = 33333;
};

}  // namespace nssft
