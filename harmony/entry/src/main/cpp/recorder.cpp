#include "recorder.h"

#include <multimedia/native_audio_channel_layout.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avmuxer.h>
#include <native_window/external_window.h>

#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <thread>

#include "h264.h"
#include "i18n.h"
#include "log.h"
#include "video_decoder.h"
#include "video_enhancer.h"

using nssft::Format;
using nssft::L;
using nssft::Logf;
using nssft::LogLevel;

namespace {

int64_t NowUs() {
    using namespace std::chrono;
    return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

constexpr int kSampleRate = 48000;
constexpr int kChannels = 2;
constexpr int kAacFrameSamples = 1024;                                  // AAC-LC 每帧 1024 个采样点
constexpr size_t kAacFrameBytes = kAacFrameSamples * kChannels * 2;     // 16 位立体声
constexpr size_t kMaxPendingPcm = size_t(kSampleRate) * kChannels * 2;  // 最多积压 1 秒，再多就丢最旧的
constexpr int kAudioBitrate = 160000;
// AAC-LC、48 kHz、双声道的 AudioSpecificConfig：00010 0011 0010 000
constexpr uint8_t kAacConfig[2] = {0x11, 0x90};
// 声音时间戳按采样数推算，与到达时间偏差超过这么多就重新对齐（中间丢过声音包）
constexpr int64_t kAudioResyncUs = 250'000;
// 收尾时等编码器吐完最后几帧的上限
constexpr int kEosWaitMs = 2500;

OH_AVCapability* HardwareCap(const char* mime, bool encoder) {
    return OH_AVCodec_GetCapabilityByCategory(mime, encoder, HARDWARE);
}

// 输出尺寸：不超过档位的高度上限，按 16:9（或游戏机画面的比例）等比缩小，宽高取偶数
void OutputSize(int w, int h, int maxHeight, int* ow, int* oh) {
    if (h <= maxHeight) {
        *ow = w;
        *oh = h;
        return;
    }
    *oh = maxHeight & ~1;
    *ow = int(int64_t(w) * maxHeight / h) & ~1;
}
}  // namespace

struct Recorder::Segment {
    std::string path;
    int fd = -1;
    OH_AVMuxer* muxer = nullptr;
    int videoTrack = -1;
    int audioTrack = -1;
    std::mutex muxMutex;
    bool muxing = false;

    int streamWidth = 0, streamHeight = 0;  // 这一段按多大的游戏机画面建
    int width = 0, height = 0;              // 输出尺寸
    int bitrateKbps = 0;
    bool hevc = false;

    OH_AVCodec* venc = nullptr;
    OHNativeWindow* encWindow = nullptr;
    std::unique_ptr<VideoEnhancer> scaler;
    std::unique_ptr<VideoDecoder> decoder;
    OH_AVCodec* aenc = nullptr;

    // 第一个关键帧送进解码器的时刻：音视频时间戳都从这里算起
    std::atomic<bool> started{false};
    std::atomic<int64_t> t0Us{0};
    std::atomic<int64_t> lastVideoPtsUs{-1};
    std::atomic<int64_t> firstVideoPtsUs{-1};

    // 声音输入（网络线程放 PCM，编码器线程给空缓冲）
    std::mutex audioMutex;
    std::deque<std::pair<uint32_t, OH_AVBuffer*>> audioInputs;
    std::vector<uint8_t> pcm;
    bool audioBased = false;
    int64_t audioBaseUs = 0;
    int64_t audioSamples = 0;
    bool audioClosing = false;

    // 收尾
    std::mutex eosMutex;
    std::condition_variable eosCv;
    bool videoEos = false;
    bool audioEos = false;

    std::atomic<bool> closing{false};
    std::atomic<uint64_t> framesIn{0}, framesEncoded{0}, bytes{0};
    std::mutex errorMutex;
    std::string error;

    void SetError(const std::string& e) {
        std::lock_guard<std::mutex> lock(errorMutex);
        if (error.empty()) error = e;
    }
    std::string Error() {
        std::lock_guard<std::mutex> lock(errorMutex);
        return error;
    }

    void Write(int track, OH_AVBuffer* buffer) {
        std::lock_guard<std::mutex> lock(muxMutex);
        if (!muxing || track < 0) return;
        const int32_t rc = OH_AVMuxer_WriteSampleBuffer(muxer, uint32_t(track), buffer);
        if (rc != AV_ERR_OK) Logf(LogLevel::Warn, "录像写入失败（轨道 %d）：%d", track, int(rc));
    }

    // 有空的输入缓冲、攒够一帧 PCM 就送进 AAC 编码器（持 audioMutex 调用）
    void PumpAudioLocked() {
        while (!audioClosing && pcm.size() >= kAacFrameBytes && !audioInputs.empty()) {
            const auto slot = audioInputs.front();
            audioInputs.pop_front();
            const int64_t now = NowUs() - t0Us;
            // 这一帧 PCM 的到达时刻：队列里排在它后面的数据还没播完的时长要减掉
            const int64_t arrival = now - int64_t(pcm.size() / (kChannels * 2)) * 1'000'000 / kSampleRate;
            int64_t pts = audioBaseUs + audioSamples * 1'000'000 / kSampleRate;
            if (!audioBased || std::llabs(pts - arrival) > kAudioResyncUs) {
                if (audioBased) Logf(LogLevel::Info, "录像声音时间戳重新对齐（偏差 %lld ms）", (long long)((pts - arrival) / 1000));
                audioBased = true;
                audioBaseUs = std::max<int64_t>(0, arrival);
                audioSamples = 0;
                pts = audioBaseUs;
            }
            std::memcpy(OH_AVBuffer_GetAddr(slot.second), pcm.data(), kAacFrameBytes);
            pcm.erase(pcm.begin(), pcm.begin() + kAacFrameBytes);
            OH_AVCodecBufferAttr attr{};
            attr.pts = pts;
            attr.size = int32_t(kAacFrameBytes);
            attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
            OH_AVBuffer_SetBufferAttr(slot.second, &attr);
            audioSamples += kAacFrameSamples;
            if (OH_AudioCodec_PushInputBuffer(aenc, slot.first) != AV_ERR_OK) Logf(LogLevel::Warn, "录像声音送入编码器失败");
        }
    }
};

namespace {
using Segment = Recorder::Segment;

// ---- 视频编码器回调（surface 输入，只用到输出）
void OnVencError(OH_AVCodec*, int32_t code, void* ud) {
    Logf(LogLevel::Error, "录像视频编码器出错：%d", code);
    static_cast<Segment*>(ud)->SetError(
        Format(L("视频编码出错 %d", "視訊編碼出錯 %d", "video encoder error %d"), int(code)));
}
void OnVencFormat(OH_AVCodec*, OH_AVFormat*, void*) {}
void OnVencNeedInput(OH_AVCodec*, uint32_t, OH_AVBuffer*, void*) {}
void OnVencOutput(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* ud) {
    auto* s = static_cast<Segment*>(ud);
    OH_AVCodecBufferAttr attr{};
    OH_AVBuffer_GetBufferAttr(buffer, &attr);
    if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        OH_VideoEncoder_FreeOutputBuffer(codec, index);
        std::lock_guard<std::mutex> lock(s->eosMutex);
        s->videoEos = true;
        s->eosCv.notify_all();
        return;
    }
    if (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) {
        // 参数集（VPS/SPS/PPS）：交给封装器写进文件头
        attr.pts = 0;
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
        s->Write(s->videoTrack, buffer);
    } else if (attr.size > 0) {
        // 时间戳用编码完成的时刻（相对第一个关键帧）：画面送进来的节奏就是收到的节奏，
        // 不依赖 surface 上传递的时间戳；同时保证严格递增
        int64_t pts = std::max<int64_t>(0, NowUs() - s->t0Us);
        const int64_t last = s->lastVideoPtsUs;
        if (pts <= last) pts = last + 1;
        s->lastVideoPtsUs = pts;
        if (s->firstVideoPtsUs < 0) s->firstVideoPtsUs = pts;
        attr.pts = pts;
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
        s->Write(s->videoTrack, buffer);
        ++s->framesEncoded;
        s->bytes += uint64_t(attr.size);
    }
    OH_VideoEncoder_FreeOutputBuffer(codec, index);
}

// ---- AAC 编码器回调
void OnAencError(OH_AVCodec*, int32_t code, void* ud) {
    Logf(LogLevel::Error, "录像声音编码器出错：%d", code);
    static_cast<Segment*>(ud)->SetError(
        Format(L("声音编码出错 %d", "聲音編碼出錯 %d", "audio encoder error %d"), int(code)));
}
void OnAencFormat(OH_AVCodec*, OH_AVFormat*, void*) {}
void OnAencNeedInput(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer, void* ud) {
    auto* s = static_cast<Segment*>(ud);
    std::lock_guard<std::mutex> lock(s->audioMutex);
    s->audioInputs.push_back({index, buffer});
    s->PumpAudioLocked();
}
void OnAencOutput(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* ud) {
    auto* s = static_cast<Segment*>(ud);
    OH_AVCodecBufferAttr attr{};
    OH_AVBuffer_GetBufferAttr(buffer, &attr);
    if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        OH_AudioCodec_FreeOutputBuffer(codec, index);
        std::lock_guard<std::mutex> lock(s->eosMutex);
        s->audioEos = true;
        s->eosCv.notify_all();
        return;
    }
    // AudioSpecificConfig 已在加轨时写好；编码器给的这一份不再重复写
    if (!(attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) && attr.size > 0) {
        // 编码器没关掉 ADTS 头时去掉它（MP4 里存的是裸 AAC 帧）
        const uint8_t* p = OH_AVBuffer_GetAddr(buffer) + attr.offset;
        if (attr.size > 7 && p[0] == 0xFF && (p[1] & 0xF6) == 0xF0) {
            const int header = (p[1] & 0x01) ? 7 : 9;  // protection_absent=1 时没有 CRC
            if (attr.size > header) {
                attr.offset += header;
                attr.size -= header;
            }
        }
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
        s->Write(s->audioTrack, buffer);
        s->bytes += uint64_t(attr.size);
    }
    OH_AudioCodec_FreeOutputBuffer(codec, index);
}
}  // namespace

RecordSupport Recorder::Support() {
    RecordSupport s;
    if (OH_AVCapability* dec = HardwareCap(OH_AVCODEC_MIMETYPE_VIDEO_AVC, false)) {
        s.decoders = OH_AVCapability_GetMaxSupportedInstances(dec);
    }
    s.hevc = HardwareCap(OH_AVCODEC_MIMETYPE_VIDEO_HEVC, true) != nullptr;
    s.avc = HardwareCap(OH_AVCODEC_MIMETYPE_VIDEO_AVC, true) != nullptr;
    s.scaler = VideoEnhancer::Supported();
    return s;
}

Recorder::Recorder() = default;
Recorder::~Recorder() { Finish(); }

std::string Recorder::Start(const RecordConfig& config, int streamWidth, int streamHeight) {
    config_ = config;
    if (!config_.dir.empty() && config_.dir.back() == '/') config_.dir.pop_back();
    const RecordSupport sup = Support();
    if (!sup.hevc && !sup.avc)
        return L("本机没有可用的硬件视频编码器", "本機沒有可用的硬體視訊編碼器", "no hardware video encoder on this device");
    if (sup.decoders < 1)
        return L("本机没有可用的硬件 H.264 解码器", "本機沒有可用的硬體 H.264 解碼器", "no hardware H.264 decoder on this device");
    {
        std::lock_guard<std::mutex> lock(mutex_);
        wantWidth_ = streamWidth;
        wantHeight_ = streamHeight;
    }
    if (streamWidth <= 0 || streamHeight <= 0) {
        Logf(LogLevel::Info, "录像：等第一帧画面再建链路");
        return "";
    }
    std::unique_ptr<Segment> seg;
    const std::string error = OpenSegment(streamWidth, streamHeight, &seg);
    if (!error.empty()) return error;
    std::lock_guard<std::mutex> lock(mutex_);
    seg_ = std::move(seg);
    return "";
}

std::string Recorder::OpenSegment(int width, int height, std::unique_ptr<Segment>* out) {
    auto s = std::make_unique<Segment>();
    s->streamWidth = width;
    s->streamHeight = height;
    const RecordSupport sup = Support();
    s->hevc = sup.hevc;
    int ow = width, oh = height;
    OutputSize(width, height, config_.maxHeight, &ow, &oh);
    const bool scale = (ow != width || oh != height) && sup.scaler;
    if (!scale) {
        if (ow != width) Logf(LogLevel::Info, "录像：本机不能缩放画面，按 %dx%d 录制", width, height);
        ow = width;
        oh = height;
    }
    s->width = ow;
    s->height = oh;
    int kbps = config_.bitrateKbps;
    if (!config_.fixedBitrate && oh < 1000) kbps = kbps * 6 / 10;  // 720p：码率按 0.6 倍
    if (!s->hevc) kbps = kbps * 3 / 2;                               // H.264 压缩率低一些，码率提高一半
    s->bitrateKbps = kbps;

    ++fileIndex_;
    s->path = config_.dir + "/" + config_.baseName + (fileIndex_ > 1 ? "_" + std::to_string(fileIndex_) : "") + ".mp4";
    s->fd = open(s->path.c_str(), O_CREAT | O_RDWR | O_TRUNC, 0644);
    if (s->fd < 0)
        return Format(L("无法创建录像文件：%s", "無法建立錄影檔案：%s", "cannot create the recording file: %s"),
                      std::strerror(errno));

    auto fail = [&](const std::string& why) {
        // 已建的部分交给 CloseSegment 统一释放（它会删掉空文件）
        CloseSegment(std::move(s));
        return why;
    };

    // ---- 封装器：视频轨 + 声音轨
    s->muxer = OH_AVMuxer_Create(s->fd, AV_OUTPUT_FORMAT_MPEG_4);
    if (s->muxer == nullptr) return fail(L("创建 MP4 封装器失败", "建立 MP4 封裝器失敗", "failed to create the MP4 muxer"));
    const char* vmime = s->hevc ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC : OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    OH_AVFormat* vf = OH_AVFormat_CreateVideoFormat(vmime, ow, oh);
    int32_t rc = OH_AVMuxer_AddTrack(s->muxer, &s->videoTrack, vf);
    OH_AVFormat_Destroy(vf);
    if (rc != AV_ERR_OK || s->videoTrack < 0)
        return fail(Format(L("添加视频轨失败：%d", "新增視訊軌失敗：%d", "failed to add the video track: %d"), int(rc)));
    if (config_.audio) {
        OH_AVFormat* af = OH_AVFormat_CreateAudioFormat(OH_AVCODEC_MIMETYPE_AUDIO_AAC, kSampleRate, kChannels);
        OH_AVFormat_SetIntValue(af, OH_MD_KEY_PROFILE, AAC_PROFILE_LC);
        OH_AVFormat_SetBuffer(af, OH_MD_KEY_CODEC_CONFIG, kAacConfig, sizeof(kAacConfig));
        rc = OH_AVMuxer_AddTrack(s->muxer, &s->audioTrack, af);
        OH_AVFormat_Destroy(af);
        if (rc != AV_ERR_OK || s->audioTrack < 0) {
            Logf(LogLevel::Warn, "录像添加声音轨失败（%d），只录画面", int(rc));
            s->audioTrack = -1;
        }
    }
    rc = OH_AVMuxer_Start(s->muxer);
    if (rc != AV_ERR_OK) return fail(Format(L("MP4 封装器启动失败：%d", "MP4 封裝器啟動失敗：%d", "MP4 muxer failed to start: %d"), int(rc)));
    s->muxing = true;

    // ---- 视频编码器（surface 输入）
    OH_AVCapability* cap = HardwareCap(vmime, true);
    const char* name = cap != nullptr ? OH_AVCapability_GetName(cap) : nullptr;
    s->venc = name != nullptr ? OH_VideoEncoder_CreateByName(name) : OH_VideoEncoder_CreateByMime(vmime);
    if (s->venc == nullptr) return fail(L("创建视频编码器失败", "建立視訊編碼器失敗", "failed to create the video encoder"));
    OH_AVCodecCallback vcb = {&OnVencError, &OnVencFormat, &OnVencNeedInput, &OnVencOutput};
    OH_VideoEncoder_RegisterCallback(s->venc, vcb, s.get());
    OH_AVFormat* ef = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(ef, OH_MD_KEY_WIDTH, ow);
    OH_AVFormat_SetIntValue(ef, OH_MD_KEY_HEIGHT, oh);
    OH_AVFormat_SetIntValue(ef, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetDoubleValue(ef, OH_MD_KEY_FRAME_RATE, 60.0);
    OH_AVFormat_SetLongValue(ef, OH_MD_KEY_BITRATE, int64_t(kbps) * 1000);
    OH_AVFormat_SetIntValue(ef, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, BITRATE_MODE_VBR);
    OH_AVFormat_SetIntValue(ef, OH_MD_KEY_I_FRAME_INTERVAL, 2000);  // 每 2 秒一个关键帧，拖动进度条时定位快
    OH_AVFormat_SetIntValue(ef, OH_MD_KEY_PROFILE, s->hevc ? int(HEVC_PROFILE_MAIN) : int(AVC_PROFILE_HIGH));
    rc = OH_VideoEncoder_Configure(s->venc, ef);
    OH_AVFormat_Destroy(ef);
    if (rc != AV_ERR_OK)
        return fail(Format(L("视频编码器配置失败：%d", "視訊編碼器設定失敗：%d", "video encoder configure failed: %d"), int(rc)));
    rc = OH_VideoEncoder_GetSurface(s->venc, &s->encWindow);
    if (rc != AV_ERR_OK || s->encWindow == nullptr)
        return fail(Format(L("取编码器输入面失败：%d", "取得編碼器輸入面失敗：%d", "failed to get the encoder surface: %d"), int(rc)));
    OH_NativeWindow_NativeWindowHandleOpt(s->encWindow, SET_BUFFER_GEOMETRY, ow, oh);
    rc = OH_VideoEncoder_Prepare(s->venc);
    if (rc == AV_ERR_OK) rc = OH_VideoEncoder_Start(s->venc);
    if (rc != AV_ERR_OK)
        return fail(Format(L("视频编码器启动失败：%d", "視訊編碼器啟動失敗：%d", "video encoder failed to start: %d"), int(rc)));

    // ---- 缩放（省空间档、游戏机发 1080p）：视频处理引擎缩到编码器的尺寸
    OHNativeWindow* decOut = s->encWindow;
    if (scale) {
        std::string why;
        s->scaler = std::make_unique<VideoEnhancer>();
        if (s->scaler->Init(s->encWindow, 1, &why)) {
            decOut = s->scaler->InputWindow();
        } else {
            return fail(Format(L("画面缩放初始化失败：%s", "畫面縮放初始化失敗：%s", "scaler init failed: %s"), why.c_str()));
        }
    }

    // ---- 声音编码器
    if (s->audioTrack >= 0) {
        s->aenc = OH_AudioCodec_CreateByMime(OH_AVCODEC_MIMETYPE_AUDIO_AAC, true);
        if (s->aenc != nullptr) {
            OH_AVCodecCallback acb = {&OnAencError, &OnAencFormat, &OnAencNeedInput, &OnAencOutput};
            OH_AudioCodec_RegisterCallback(s->aenc, acb, s.get());
            OH_AVFormat* af = OH_AVFormat_Create();
            OH_AVFormat_SetIntValue(af, OH_MD_KEY_AUD_CHANNEL_COUNT, kChannels);
            OH_AVFormat_SetIntValue(af, OH_MD_KEY_AUD_SAMPLE_RATE, kSampleRate);
            OH_AVFormat_SetLongValue(af, OH_MD_KEY_BITRATE, kAudioBitrate);
            OH_AVFormat_SetIntValue(af, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
            OH_AVFormat_SetLongValue(af, OH_MD_KEY_CHANNEL_LAYOUT, CH_LAYOUT_STEREO);
            OH_AVFormat_SetIntValue(af, OH_MD_KEY_PROFILE, AAC_PROFILE_LC);
            OH_AVFormat_SetIntValue(af, OH_MD_KEY_AAC_IS_ADTS, 0);
            rc = OH_AudioCodec_Configure(s->aenc, af);
            OH_AVFormat_Destroy(af);
            if (rc == AV_ERR_OK) rc = OH_AudioCodec_Prepare(s->aenc);
            if (rc == AV_ERR_OK) rc = OH_AudioCodec_Start(s->aenc);
            if (rc != AV_ERR_OK) {
                Logf(LogLevel::Warn, "录像声音编码器启动失败（%d），只录画面", int(rc));
                OH_AudioCodec_Destroy(s->aenc);
                s->aenc = nullptr;
            }
        }
    }

    // ---- 解码器：解出来立即交给编码器（或缩放），丢帧后等关键帧，不录花屏
    s->decoder = std::make_unique<VideoDecoder>();
    s->decoder->SetDirectRender(true);
    s->decoder->SetFreezeOnLoss(true);
    std::string why;
    if (!s->decoder->Init(decOut, width, height, &why))
        return fail(Format(L("录像解码器启动失败：%s", "錄影解碼器啟動失敗：%s", "recording decoder failed to start: %s"), why.c_str()));

    Logf(LogLevel::Info, "录像开始：%s，%dx%d → %dx%d，%s %d kbps%s%s", s->path.c_str(), width, height, ow, oh,
         s->hevc ? "H.265" : "H.264", kbps, scale ? "，缩放" : "", s->aenc ? "，带声音" : "，无声音");
    *out = std::move(s);
    return "";
}

void Recorder::OnVideo(const nssft::VideoFrame& f) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (finished_) return;
    wantWidth_ = int(f.width);
    wantHeight_ = int(f.height);
    Segment* s = seg_.get();
    if (s == nullptr || s->closing || s->streamWidth != int(f.width) || s->streamHeight != int(f.height)) {
        // 尺寸变了：等主线程换文件。已经开录之后这段时间的帧才算“没录进去”
        if (everStarted_) ++droppedNoSegment_;
        return;
    }
    if (!s->started) {
        if (!f.key && !nssft::ContainsNalType(f.data, f.size, nssft::kNalIdr)) {
            if (everStarted_) ++droppedNoSegment_;  // 换文件后等关键帧（刚开始录时的等待不算）
            return;
        }
        s->t0Us = NowUs();
        s->started = true;
        everStarted_ = true;
    }
    ++s->framesIn;
    s->decoder->Submit(f.data, f.size, f.timestampUs);
}

void Recorder::OnLoss() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (seg_ && seg_->decoder && !seg_->closing) seg_->decoder->OnFrameLoss(nssft::LossCause::SequenceGap);
}

void Recorder::OnAudio(const uint8_t* pcm, size_t size) {
    std::lock_guard<std::mutex> lock(mutex_);
    Segment* s = seg_.get();
    if (s == nullptr || s->aenc == nullptr || !s->started || s->closing) return;  // 第一帧画面之前的声音不录
    std::lock_guard<std::mutex> alock(s->audioMutex);
    s->pcm.insert(s->pcm.end(), pcm, pcm + size);
    if (s->pcm.size() > kMaxPendingPcm) {
        // 编码器跟不上（几乎不会）：丢掉最旧的，时间戳会在下一帧重新对齐
        const size_t drop = (s->pcm.size() - kMaxPendingPcm + kAacFrameBytes - 1) / kAacFrameBytes * kAacFrameBytes;
        s->pcm.erase(s->pcm.begin(), s->pcm.begin() + std::min(drop, s->pcm.size()));
    }
    s->PumpAudioLocked();
}

bool Recorder::Poll() {
    std::unique_ptr<Segment> old;
    int w = 0, h = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (finished_ || wantWidth_ <= 0 || wantHeight_ <= 0) return false;
        if (seg_ && seg_->streamWidth == wantWidth_ && seg_->streamHeight == wantHeight_) return false;
        old = std::move(seg_);
        w = wantWidth_;
        h = wantHeight_;
    }
    if (old) {
        Logf(LogLevel::Info, "录像：画面尺寸变为 %dx%d，换一个文件", w, h);
        old->closing = true;
        CloseSegment(std::move(old));
    }
    std::unique_ptr<Segment> seg;
    const std::string error = OpenSegment(w, h, &seg);
    if (!error.empty()) {
        Logf(LogLevel::Error, "录像换文件失败：%s", error.c_str());
        std::lock_guard<std::mutex> slock(statsMutex_);
        if (error_.empty()) error_ = error;
        // 不再重试：留着 wantWidth_，但标记失败，ArkTS 看到 error 会停止录制
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (finished_) {
        // 换文件的同时被停止了：这一段直接收尾（没有画面，会被删掉）
        CloseSegment(std::move(seg));
        return false;
    }
    seg_ = std::move(seg);
    return true;
}

void Recorder::CloseSegment(std::unique_ptr<Segment> s) {
    if (!s) return;
    s->closing = true;
    // 1. 停解码（不再往编码器的输入面送画面），再停缩放
    if (s->decoder) s->decoder->Release();
    if (s->scaler) s->scaler->Release();
    // 2. 视频编码器吐完剩下的帧
    if (s->venc != nullptr) {
        if (s->framesIn > 0 && OH_VideoEncoder_NotifyEndOfStream(s->venc) == AV_ERR_OK) {
            std::unique_lock<std::mutex> lock(s->eosMutex);
            if (!s->eosCv.wait_for(lock, std::chrono::milliseconds(kEosWaitMs), [&] { return s->videoEos; }))
                Logf(LogLevel::Warn, "录像视频编码器没在 %d ms 内结束", kEosWaitMs);
        }
        OH_VideoEncoder_Stop(s->venc);
    }
    // 3. 声音编码器：送一个结束标记，等它吐完
    if (s->aenc != nullptr) {
        bool sentEos = false;
        for (int i = 0; i < 50 && !sentEos; ++i) {
            {
                std::lock_guard<std::mutex> lock(s->audioMutex);
                s->audioClosing = true;
                if (!s->audioInputs.empty()) {
                    const auto slot = s->audioInputs.front();
                    s->audioInputs.pop_front();
                    OH_AVCodecBufferAttr attr{};
                    attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
                    OH_AVBuffer_SetBufferAttr(slot.second, &attr);
                    sentEos = OH_AudioCodec_PushInputBuffer(s->aenc, slot.first) == AV_ERR_OK;
                }
            }
            if (!sentEos) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        if (sentEos) {
            std::unique_lock<std::mutex> lock(s->eosMutex);
            s->eosCv.wait_for(lock, std::chrono::milliseconds(1000), [&] { return s->audioEos; });
        }
        OH_AudioCodec_Stop(s->aenc);
    }
    // 4. 写文件尾
    {
        std::lock_guard<std::mutex> lock(s->muxMutex);
        if (s->muxer != nullptr) {
            if (s->muxing && OH_AVMuxer_Stop(s->muxer) != AV_ERR_OK) Logf(LogLevel::Warn, "录像写文件尾失败");
            s->muxing = false;
            OH_AVMuxer_Destroy(s->muxer);
            s->muxer = nullptr;
        }
    }
    if (s->venc != nullptr) {
        OH_VideoEncoder_Destroy(s->venc);
        s->venc = nullptr;
    }
    if (s->aenc != nullptr) {
        OH_AudioCodec_Destroy(s->aenc);
        s->aenc = nullptr;
    }
    if (s->encWindow != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(s->encWindow);
        s->encWindow = nullptr;
    }
    if (s->fd >= 0) {
        close(s->fd);
        s->fd = -1;
    }

    const int64_t first = s->firstVideoPtsUs, last = s->lastVideoPtsUs;
    const int64_t durationMs = first >= 0 && last > first ? (last - first) / 1000 : 0;
    std::lock_guard<std::mutex> lock(statsMutex_);
    if (s->framesEncoded == 0) {
        unlink(s->path.c_str());  // 一帧都没录进去（还没等到关键帧就停了）：不留空文件
        Logf(LogLevel::Info, "录像文件没有画面，已删除：%s", s->path.c_str());
    } else {
        files_.push_back(s->path);
        Logf(LogLevel::Info, "录像文件完成：%s，%llu 帧，%lld ms，%llu 字节", s->path.c_str(),
             (unsigned long long)s->framesEncoded.load(), (long long)durationMs, (unsigned long long)s->bytes.load());
    }
    doneDurationMs_ += durationMs;
    doneBytes_ += s->bytes;
    doneFramesIn_ += s->framesIn;
    doneEncoded_ += s->framesEncoded;
    if (s->decoder) doneDropped_ += s->decoder->PacketsDropped();
    const std::string e = s->Error();
    if (!e.empty() && error_.empty()) error_ = e;
}

void Recorder::Finish() {
    std::unique_ptr<Segment> s;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (finished_) return;
        finished_ = true;
        s = std::move(seg_);
        if (s) s->closing = true;
    }
    CloseSegment(std::move(s));
}

RecordStats Recorder::Stats() {
    RecordStats r;
    {
        std::lock_guard<std::mutex> lock(statsMutex_);
        r.durationMs = doneDurationMs_;
        r.bytes = doneBytes_;
        r.framesIn = doneFramesIn_;
        r.framesEncoded = doneEncoded_;
        r.framesDropped = doneDropped_ + droppedNoSegment_;
        r.files = files_;
        r.error = error_;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    r.active = !finished_;
    if (seg_) {
        Segment* s = seg_.get();
        r.waitingKeyframe = !s->started || s->framesEncoded == 0;
        const int64_t first = s->firstVideoPtsUs, last = s->lastVideoPtsUs;
        if (first >= 0 && last > first) r.durationMs += (last - first) / 1000;
        r.bytes += s->bytes;
        r.framesIn += s->framesIn;
        r.framesEncoded += s->framesEncoded;
        if (s->decoder) r.framesDropped += s->decoder->PacketsDropped();
        r.width = s->width;
        r.height = s->height;
        r.bitrateKbps = s->bitrateKbps;
        r.hevc = s->hevc;
        r.scaled = s->scaler != nullptr;
        const std::string e = s->Error();
        if (!e.empty() && r.error.empty()) r.error = e;
        if (!s->path.empty()) r.files.push_back(s->path);
    } else if (r.active) {
        r.waitingKeyframe = true;
    }
    return r;
}
