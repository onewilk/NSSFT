// 一次串流会话：StreamSource（SFT 网络）→ VideoDecoder（画面）/ AudioPlayer（声音）
// 切后台时 PauseRendering：网络照常收，解码器和音频释放，只维护 GOP 缓存；
// 回前台时 ResumeRendering：新建解码器并重放缓存，直接追到最新画面。
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>

#include "audio_player.h"
#include "gop_cache.h"
#include "recorder.h"
#include "sft_pad.h"
#include "stream_source.h"
#include "video_decoder.h"
#include "video_enhancer.h"

struct SessionStats {
    bool active = false;
    bool renderingPaused = false;
    std::string message;
    nssft::SourceStats source;
    int decoderWidth = 0;  // 当前解码器按多大的画面配置
    int decoderHeight = 0;
    uint64_t framesRendered = 0;
    uint64_t videoDropped = 0;
    bool netOpt = false;
    int lastCatchUpMs = -1;
    uint64_t gopPackets = 0;
    uint64_t gopBytes = 0;
    bool audioEnabled = false;
    bool audioFastMode = false;
    uint64_t audioUnderruns = 0;
    int audioBufferedMs = 0;
    int audioTargetMs = 0;
    std::string decoderError;

    // 丢帧与定格
    bool freezeOnLoss = true;
    bool frozen = false;
    uint64_t lossEvents[int(nssft::LossCause::Count)] = {};  // 按原因分类的丢失事件
    uint64_t lostFrames = 0;       // 时间戳断档估计丢掉的帧数
    int frameIntervalUs = 0;       // 估计的正常帧间隔
    int keyframeIntervalMs = 0;    // 关键帧间隔（滑动平均）
    int lastFreezeMs = -1;
    DecoderCounters decoder;       // 定格、VSync、卡顿等解码器侧计数（跨重建累计）
    RenderTiming timing;           // 最近一个统计窗口的上屏节奏
    int vsyncPeriodUs = 0;

    // 画质增强：enhanceLevel 是实际生效的档位（设备不支持时为 0，原因见 enhanceError）
    int enhanceRequested = 0;
    int enhanceLevel = 0;
    int enhanceLatencyUs = 0;
    std::string enhanceError;
};

// 手柄（见 core/sft_pad.h）的设置：enabled 是用户打开了手柄功能、并且播放页在前台
struct PadConfig {
    bool enabled = false;
    bool faceByLabel = false;
    double deadZone = nssft::pad::kDefaultDeadZone;
    double triggerPoint = nssft::pad::kDefaultTriggerPoint;
};

struct PadStatus {
    bool takesInput = false;  // 游戏机接受手柄（打开了 “Controls from the viewer”）
    bool attached = false;    // 游戏机上已经接上了这个虚拟手柄
    uint64_t sent = 0;
    nssft::pad::PadState::Snapshot now;  // 正在按的（给测试框看）
};

// 按选项和回调创建串流来源（由 NAPI 层决定用哪种传输）
using SourceFactory = std::function<std::unique_ptr<nssft::StreamSource>(const nssft::StreamCallbacks&)>;

struct SessionConfig {
    std::string label;  // 只用于状态提示，例如 "192.168.49.5"
    uint64_t surfaceId = 0;
    bool audio = true;
    bool netOpt = true;
    bool freezeOnLoss = true;  // 丢帧后定格到下一个关键帧，不花屏
    int enhanceLevel = 0;      // 画质增强：0 关闭 / 1 标准 / 2 高
    bool display = true;       // false：只录制，不显示画面、不播放声音（没有 surface）
};

class Session {
public:
    ~Session();

    // 以下都在 ArkTS 主线程调用。返回空字符串表示成功，否则为错误信息
    std::string Start(const SourceFactory& factory, const SessionConfig& config);
    void Stop();
    void PauseRendering();
    std::string ResumeRendering(uint64_t surfaceId);
    // 播放中快捷开关：不断开视频
    std::string SetAudioEnabled(bool enabled);
    void SetNetOptimization(bool enabled);
    void SetFreezeOnLoss(bool on);
    // 画质增强档位；开关状态变化时重建视频链路（重放 GOP，画面直接追到最新）。
    // 返回空串表示成功，否则为错误信息（例如本机不支持，此时已退回直出）
    std::string SetEnhanceLevel(int level);
    std::vector<nssft::SocketFlow> SocketFlows() const;
    SessionStats Stats();

    // 录像（主线程）：和显示链路分开的另一条链路，见 recorder.h。返回空串表示已开始
    std::string StartRecording(RecordConfig config);
    // 摘下录像器交给调用方收尾（Finish 会阻塞几百毫秒到几秒，调用方放到工作线程做）；没在录时返回空
    std::unique_ptr<Recorder> StopRecording();
    bool Recording() const { return recording_; }
    RecordStats RecordingStats();

    // 手柄（主线程）：按键和轴来自界面的按键事件、焦点轴事件；发送在手柄自己的线程。只录制模式下没有手柄。
    void ConfigurePad(const PadConfig& config);
    void SetPadDevicePresent(bool present);
    // false：菜单或对话框开着（手柄接着，但什么都不按）
    void SetPadPlaying(bool playing);
    // 返回 true 表示这次输入交给了游戏机（调用方就不再让界面处理，免得手柄按键移动界面焦点）
    bool PadKey(int32_t keyCode, bool down);
    bool PadAxes(const nssft::pad::Axes& axes);
    // 触屏手柄：显示着就算有手柄；状态是整体给的（按键位 + 两个摇杆）
    void SetPadTouchShown(bool shown);
    void PadTouch(uint64_t buttons, double lx, double ly, double rx, double ry);
    void ResetPad();
    PadStatus PadStats() const;

private:
    // 网络线程回调
    void OnVideo(const nssft::VideoFrame& frame);
    void OnVideoLocked(const nssft::VideoFrame& frame, const uint8_t* data, size_t size, uint64_t ts);
    void OnAudio(const uint8_t* data, size_t size);
    // 视频数据丢失（持 videoMutex_ 调用）：计数、作废 GOP 缓存、通知解码器定格、请求关键帧
    void HandleLossLocked(nssft::LossCause cause);
    void RequestKeyframe();
    // 画面尺寸变了（持 videoMutex_，网络线程）：没开画质增强时就地换一个解码器
    void SwapDecoderLocked(int width, int height);
    // 新建一个按会话当前选项配置好的解码器（持 videoMutex_ 调用）
    std::unique_ptr<VideoDecoder> NewDecoderLocked(VideoEnhancer* enhancer);
    void SetMessage(const std::string& msg);
    // 每秒随统计调用：检查回前台后的追帧是否完成
    void UpdateResumeMessage();
    // 一条视频链路：屏幕窗口 +（可选）画质增强 + 解码器
    struct VideoPipeline {
        OHNativeWindow* window = nullptr;
        std::unique_ptr<VideoEnhancer> enhancer;
        std::unique_ptr<VideoDecoder> decoder;
        std::string enhanceError;  // 画质增强没能启用的原因（不影响播放）
    };
    // 创建视频链路（不持锁，耗时几十毫秒）
    std::string CreateVideo(uint64_t surfaceId, VideoPipeline* out);
    // 把旧解码器的计数累加到会话（持 videoMutex_）
    void AccumulateDecoderLocked(VideoDecoder* d);
    // 持锁把链路装上：GOP 重放（可选）+ 切换
    size_t InstallVideoLocked(VideoPipeline* p, bool replayGop);
    // 只释放视频（解码器 → 增强器 → 窗口），不动音频
    void ReleaseVideo();
    // 换一条视频链路（开关画质增强、增强器不出画面时退回直出），GOP 重放让画面直接追到最新
    std::string RebuildVideo();
    // 画质增强建起来了却迟迟不出画面（部分设备、模拟器）：退回直出（主线程调用）
    void CheckEnhancerStall();
    std::string CreateAudio();
    void ReleaseAudio();
    void ReleaseRendering();

    std::unique_ptr<nssft::StreamSource> client_;
    std::atomic<bool> audioEnabled_{false};
    std::atomic<bool> netOpt_{true};
    std::atomic<bool> paused_{false};
    std::atomic<bool> freezeOnLoss_{true};
    std::atomic<int> enhanceLevel_{0};
    uint64_t lastSurfaceId_ = 0;  // 主线程读写
    bool enhanceBroken_ = false;  // 本机上画质增强不出画面：本次会话不再尝试，直到用户重新选档位（主线程读写）
    // 回前台后的恢复进度：追帧完成（或等到关键帧出第一帧）后把状态文字更新成“已恢复实时画面”
    enum class ResumeState { None, CatchingUp, WaitingKeyframe };
    std::atomic<ResumeState> resumeState_{ResumeState::None};
    int64_t resumeAtMs_ = 0;

    // 网络线程与主线程共享，受 videoMutex_ 保护
    std::mutex videoMutex_;
    OHNativeWindow* window_ = nullptr;
    std::unique_ptr<VideoEnhancer> enhancer_;
    std::string enhanceError_;
    std::unique_ptr<VideoDecoder> video_;
    nssft::GopCache gop_;
    // 已释放解码器的累计统计，保证暂停/恢复后数字连续
    uint64_t renderedBase_ = 0;
    uint64_t droppedBase_ = 0;
    // 音频播放器在开关音频、切前后台时会重建，计数要累加，统计才不会倒退
    uint64_t underrunBase_ = 0;
    int lastCatchUpMs_ = -1;
    DecoderCounters decoderBase_;
    // 丢帧检测（网络线程，受 videoMutex_ 保护）
    nssft::FrameGapDetector gap_;
    uint64_t lossEvents_[int(nssft::LossCause::Count)] = {};
    uint64_t lastIdrUs_ = 0;
    // 游戏机发来的画面尺寸（受 videoMutex_ 保护）；还没收到画面时按 1080p 建解码器
    int streamWidth_ = 1920;
    int streamHeight_ = 1080;
    // 开着画质增强时尺寸变了：由主线程（每秒统计时）整条视频链路重建
    std::atomic<bool> resizePending_{false};
    int keyframeIntervalMs_ = 0;

    std::mutex audioMutex_;
    std::unique_ptr<AudioPlayer> audio_;

    // 录像器：网络线程送数据，主线程开始/停止（锁顺序：videoMutex_ → recordMutex_，反过来不行）
    std::mutex recordMutex_;
    std::unique_ptr<Recorder> recorder_;
    std::atomic<bool> recording_{false};
    bool display_ = true;  // 只录制模式下为 false（主线程读写）

    // 手柄：padState_ 主线程写、发送线程读（自带锁）；pad_ 在 client_ 之后建、之前停（发送线程要用 client_）
    nssft::pad::PadState padState_;
    std::unique_ptr<nssft::pad::PadSender> pad_;
    PadConfig padConfig_;

    std::mutex messageMutex_;
    std::string message_;
};
