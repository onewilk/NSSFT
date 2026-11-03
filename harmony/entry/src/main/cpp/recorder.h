// 录像：边收边压。和屏幕显示完全分开的一条链路，不影响播放：
//   收到的 H.264 → 第二个硬件解码器 →（省空间档需要缩小时：视频处理引擎缩放）→ 硬件编码器的输入 surface
//   → H.265（不支持时 H.264）→ MP4；游戏声音 PCM → AAC → 同一个 MP4。
// 解码器到编码器之间走 surface，画面在硬件里传，不经过 CPU 拷贝。
// 只录制（不显示画面）时，会话里没有显示解码器，只有这一条链路。
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "stream_source.h"

struct OH_AVCodec;
struct OH_AVBuffer;
struct OH_AVFormat;
struct OH_AVMuxer;
struct NativeWindow;
typedef struct NativeWindow OHNativeWindow;
class VideoDecoder;
class VideoEnhancer;

struct RecordConfig {
    std::string dir;        // 录像目录（应用沙箱里的路径）
    std::string baseName;   // 文件名，不含扩展名；中途换文件时依次加 _2、_3…
    int maxHeight = 1080;   // 输出画面的高度上限：省空间档 720（游戏机发 1080p 时用视频处理引擎缩小）
    int bitrateKbps = 8000; // 输出 1080p 时的目标码率；输出 720p 时按 0.6 倍（档位本身就是 720p 的除外）
    bool fixedBitrate = false;  // true：不按输出尺寸折算（省空间档：720p 4 Mbps）
    bool audio = true;      // 有没有声音轨（游戏机没在发声音时不加）
};

struct RecordStats {
    bool active = false;
    bool waitingKeyframe = false;  // 还在等第一个关键帧（或换文件后的关键帧）
    int64_t durationMs = 0;        // 已录时长（所有文件合计）
    uint64_t bytes = 0;            // 已写入的音视频数据
    uint64_t framesIn = 0;         // 送进录制解码器的帧
    uint64_t framesEncoded = 0;
    uint64_t framesDropped = 0;    // 等关键帧、积压时没录进去的帧
    int width = 0;                 // 当前输出尺寸
    int height = 0;
    int bitrateKbps = 0;
    bool hevc = false;
    bool scaled = false;           // 用视频处理引擎缩小了画面
    std::string error;             // 编码出错等，非空时应停止录制
    std::vector<std::string> files;
};

struct RecordSupport {
    int decoders = 0;    // 硬件 H.264 解码器最多能同时开几个
    bool hevc = false;   // 有硬件 H.265 编码器
    bool avc = false;    // 有硬件 H.264 编码器
    bool scaler = false; // 有视频处理引擎（省空间档缩小画面用）
};

class Recorder {
public:
    Recorder();  // 构造和析构都放在 .cpp：Segment 只在那里定义
    ~Recorder();

    static RecordSupport Support();

    // 主线程。streamWidth/Height：游戏机当前的画面尺寸，还没收到画面时传 0（等第一帧再建链路）
    std::string Start(const RecordConfig& config, int streamWidth, int streamHeight);
    // 网络线程（与会话的 OnVideo 同一线程）；数据会被拷贝，不阻塞收流
    void OnVideo(const nssft::VideoFrame& frame);
    void OnLoss();
    void OnAudio(const uint8_t* pcm, size_t size);
    // 主线程，每秒一次：画面尺寸变了就收尾当前文件、按新尺寸开下一个文件。返回 true 表示新建了链路（要请求关键帧）
    bool Poll();
    // 停止并写完文件（会阻塞到编码器吐完最后几帧，最多约 3 秒）。可以在任意线程调用，调用后不能再送数据
    void Finish();
    RecordStats Stats();

    // 以下由编解码器回调（.cpp 里的静态函数）转调
    struct Segment;

private:
    // 按 width x height（游戏机画面尺寸）建一段：文件、封装器、编码器、（缩放）、解码器。
    // 只在主线程调用，不持 mutex_（建链路要几十毫秒，不能挡住收流线程）；成功时放进 *out
    std::string OpenSegment(int width, int height, std::unique_ptr<Segment>* out);
    // 收尾一段：停解码 → 编码器吐完 → 写文件尾；没录进任何画面的文件直接删掉
    void CloseSegment(std::unique_ptr<Segment> seg);

    RecordConfig config_;
    std::mutex mutex_;  // 保护 seg_ 的替换（主线程）与使用（网络线程）
    std::unique_ptr<Segment> seg_;
    int wantWidth_ = 0;  // 最近一帧的画面尺寸（网络线程写，主线程 Poll 读）
    int wantHeight_ = 0;
    bool finished_ = false;
    int fileIndex_ = 0;

    // 已经收尾的文件的累计统计
    std::mutex statsMutex_;
    int64_t doneDurationMs_ = 0;
    uint64_t doneBytes_ = 0, doneFramesIn_ = 0, doneEncoded_ = 0, doneDropped_ = 0;
    std::vector<std::string> files_;
    std::string error_;
    std::atomic<uint64_t> droppedNoSegment_{0};  // 换文件期间没有链路、直接丢掉的帧
    std::atomic<bool> everStarted_{false};       // 已经录进过画面（之后的等待才算丢帧）
};
