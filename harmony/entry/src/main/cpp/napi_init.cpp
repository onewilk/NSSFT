// ArkTS <-> C++ 接口（libentry.so），声明见 types/libentry/Index.d.ts。
// 所有函数都在 ArkTS 主线程调用；状态由 ArkTS 定时轮询，避免跨线程回调。
#include <hilog/log.h>
#include <napi/native_api.h>

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "display_rate.h"
#include "i18n.h"
#include "log.h"
#include "session.h"
#include "sft_net_source.h"
#include "sft_usb_source.h"
#include "usb_host.h"

using nssft::L;

namespace {

std::unique_ptr<nssft::SftDiscovery> g_discovery;
std::unique_ptr<Session> g_session;
// USB 退回 ArkTS 兼容传输时：泵归串流来源所有，这里只留一个指针给 NAPI 喂数据（都在主线程访问）
JsPumpTransport* g_pump = nullptr;
napi_threadsafe_function g_usbWriteFn = nullptr;
// 手柄的设置和本机有没有手柄：与会话无关，新会话开始时带上
PadConfig g_padConfig;
bool g_padPresent = false;
bool g_padTouchShown = false;

std::string GetString(napi_env env, napi_value v) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) return "";
    std::vector<char> buf(len + 1, '\0');
    napi_get_value_string_utf8(env, v, buf.data(), buf.size(), &len);
    return std::string(buf.data(), len);
}

bool GetBool(napi_env env, napi_value v, bool fallback) {
    bool b = fallback;
    if (napi_get_value_bool(env, v, &b) != napi_ok) return fallback;
    return b;
}

napi_value MakeString(napi_env env, const std::string& s) {
    napi_value v;
    napi_create_string_utf8(env, s.c_str(), s.size(), &v);
    return v;
}

napi_value MakeBool(napi_env env, bool b) {
    napi_value v;
    napi_get_boolean(env, b, &v);
    return v;
}

napi_value MakeNumber(napi_env env, double d) {
    napi_value v;
    napi_create_double(env, d, &v);
    return v;
}

napi_value Undefined(napi_env env) {
    napi_value v;
    napi_get_undefined(env, &v);
    return v;
}

void Set(napi_env env, napi_value obj, const char* key, napi_value v) { napi_set_named_property(env, obj, key, v); }

// startDiscovery(): boolean —— 监听 UDP 9951 上游戏机的广播；端口被占用时返回 false
napi_value StartDiscovery(napi_env env, napi_callback_info) {
    if (!g_discovery) g_discovery = std::make_unique<nssft::SftDiscovery>();
    return MakeBool(env, g_discovery->Start());
}

// stopDiscovery(): void
napi_value StopDiscovery(napi_env env, napi_callback_info) {
    if (g_discovery) {
        g_discovery->Stop();
        g_discovery.reset();
    }
    return Undefined(env);
}

// getDevices(): DeviceInfo[] —— 最近 5 秒内广播过的游戏机
napi_value GetDevices(napi_env env, napi_callback_info) {
    napi_value arr;
    napi_create_array(env, &arr);
    if (!g_discovery) return arr;
    const auto devices = g_discovery->Devices();
    for (size_t i = 0; i < devices.size(); ++i) {
        napi_value obj;
        napi_create_object(env, &obj);
        Set(env, obj, "ip", MakeString(env, devices[i].ip));
        Set(env, obj, "port", MakeNumber(env, devices[i].port));
        Set(env, obj, "name", MakeString(env, devices[i].name));
        napi_set_element(env, arr, uint32_t(i), obj);
    }
    return arr;
}

int32_t GetInt(napi_env env, napi_value v, int32_t fallback) {
    int32_t i = fallback;
    if (napi_get_value_int32(env, v, &i) != napi_ok) return fallback;
    return i;
}

napi_value Prop(napi_env env, napi_value obj, const char* key) {
    napi_value v = nullptr;
    bool has = false;
    if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) return nullptr;
    napi_get_named_property(env, obj, key, &v);
    return v;
}

void StopSession() {
    // 先让阻塞在 ArkTS 泵上的读写立刻返回，串流线程才能尽快退出
    if (g_pump) g_pump->Close();
    if (g_session) {
        g_session->Stop();
        g_session.reset();
    }
    g_pump = nullptr;
    if (g_usbWriteFn) {
        napi_release_threadsafe_function(g_usbWriteFn, napi_tsfn_release);
        g_usbWriteFn = nullptr;
    }
}

// 线程安全函数的回调：在 ArkTS 主线程上调用 onUsbWrite()，让 ArkTS 来取要写的数据
void CallUsbWrite(napi_env env, napi_value jsCb, void*, void*) {
    if (env == nullptr || jsCb == nullptr) return;
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, jsCb, 0, nullptr, nullptr);
}

// connect(config: ConnectConfig): string —— 空串 = 已开始连接（之后看 getStats 的 message）
napi_value Connect(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return MakeString(env, L("参数不足", "參數不足", "missing arguments"));
    const napi_value cfg = args[0];
    auto str = [&](const char* k) { napi_value v = Prop(env, cfg, k); return v ? GetString(env, v) : std::string(); };
    auto num = [&](const char* k, int32_t d) { napi_value v = Prop(env, cfg, k); return v ? GetInt(env, v, d) : d; };
    auto flag = [&](const char* k, bool d) { napi_value v = Prop(env, cfg, k); return v ? GetBool(env, v, d) : d; };

    SessionConfig config;
    config.surfaceId = std::strtoull(str("surfaceId").c_str(), nullptr, 10);
    config.audio = flag("audio", true);
    config.netOpt = flag("netOpt", true);
    config.freezeOnLoss = flag("freezeOnLoss", true);
    config.enhanceLevel = num("enhanceLevel", 0);
    // 只录制：不显示画面、不播放声音，不需要 surface
    config.display = !flag("recordOnly", false);
    if (!config.display) config.audio = false;
    if (config.display && config.surfaceId == 0)
        return MakeString(env, L("surfaceId 无效", "surfaceId 無效", "invalid surfaceId"));

    StopSession();
    SourceFactory factory;
    if (flag("usb", false)) {
        const int fd = num("usbFd", -1);
        const int iface = num("usbInterface", 0);
        const uint8_t epIn = uint8_t(num("usbEpIn", 0x81));
        const uint8_t epOut = uint8_t(num("usbEpOut", 0x01));
        std::shared_ptr<std::unique_ptr<nssft::ByteChannel>> holder;
        if (flag("usbPump", false)) {
            napi_value cb = Prop(env, cfg, "onUsbWrite");
            if (cb == nullptr) return MakeString(env, L("缺少 onUsbWrite 回调", "缺少 onUsbWrite 回呼", "missing onUsbWrite callback"));
            napi_value name;
            napi_create_string_utf8(env, "usbWrite", NAPI_AUTO_LENGTH, &name);
            if (napi_create_threadsafe_function(env, cb, nullptr, name, 0, 1, nullptr, nullptr, nullptr, CallUsbWrite,
                                                &g_usbWriteFn) != napi_ok)
                return MakeString(env, L("创建 USB 写回调失败", "建立 USB 寫入回呼失敗", "failed to create the USB write callback"));
            const napi_threadsafe_function fn = g_usbWriteFn;
            auto pump = std::make_unique<JsPumpTransport>([fn] { napi_call_threadsafe_function(fn, nullptr, napi_tsfn_nonblocking); });
            g_pump = pump.get();
            holder = std::make_shared<std::unique_ptr<nssft::ByteChannel>>(std::move(pump));
            config.label = L("USB（兼容传输）", "USB（相容傳輸）", "USB (compatibility mode)");
        } else {
            if (fd < 0) return MakeString(env, L("USB 描述符无效", "USB 描述元無效", "invalid USB file descriptor"));
            holder = std::make_shared<std::unique_ptr<nssft::ByteChannel>>(
                std::make_unique<UsbFsTransport>(fd, iface, epIn, epOut));
            config.label = "USB";
        }
        factory = [holder](const nssft::StreamCallbacks& c) {
            return std::make_unique<nssft::SftUsbSource>(std::move(*holder), c);
        };
        config.netOpt = false;  // 快速确认、网络加速只对网络有意义
    } else {
        const std::string host = str("host");
        if (host.empty()) return MakeString(env, L("IP 地址无效", "IP 位址無效", "invalid IP address"));
        const int port = num("port", nssft::sft::kStreamPort);
        if (port <= 0 || port > 65535) return MakeString(env, L("端口无效", "連接埠無效", "invalid port"));
        factory = [host, port](const nssft::StreamCallbacks& c) {
            return std::make_unique<nssft::SftNetSource>(host, c, uint16_t(port));
        };
        config.label = host;
    }
    g_session = std::make_unique<Session>();
    g_session->ConfigurePad(g_padConfig);
    std::string err = g_session->Start(factory, config);
    if (!err.empty()) {
        StopSession();
    } else {
        g_session->SetPadDevicePresent(g_padPresent);
        g_session->SetPadTouchShown(g_padTouchShown);
    }
    return MakeString(env, err);
}

// disconnect(): void
napi_value Disconnect(napi_env env, napi_callback_info) {
    StopSession();
    return Undefined(env);
}

// setLanguage(lang: number): void —— 原生层状态文字的语言：0 简体 / 1 繁體 / 2 English
napi_value SetLanguage(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    nssft::SetLanguage(argc >= 1 ? GetInt(env, args[0], nssft::kLangHans) : nssft::kLangHans);
    return Undefined(env);
}

// pauseVideo(): void —— 切后台：释放解码器和音频，网络照常收、维护 GOP 缓存
napi_value PauseVideo(napi_env env, napi_callback_info) {
    if (g_session) g_session->PauseRendering();
    return Undefined(env);
}

// resumeVideo(surfaceId: string): string —— 回前台：重建解码器并重放 GOP（空串 = 成功）
napi_value ResumeVideo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!g_session) return MakeString(env, L("没有进行中的串流", "沒有進行中的串流", "no active stream"));
    if (argc < 1) return MakeString(env, L("参数不足", "參數不足", "missing arguments"));
    const uint64_t surfaceId = std::strtoull(GetString(env, args[0]).c_str(), nullptr, 10);
    if (surfaceId == 0) return MakeString(env, L("surfaceId 无效", "surfaceId 無效", "invalid surfaceId"));
    return MakeString(env, g_session->ResumeRendering(surfaceId));
}

// setAudioEnabled(enabled: boolean): string —— 播放中开关音频通道，空串 = 成功
napi_value SetAudioEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!g_session) return MakeString(env, "");
    return MakeString(env, g_session->SetAudioEnabled(argc >= 1 && GetBool(env, args[0], true)));
}

// setNetOptimization(enabled: boolean): void —— TCP 快速确认
napi_value SetNetOptimization(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_session) g_session->SetNetOptimization(argc >= 1 && GetBool(env, args[0], true));
    return Undefined(env);
}

// setFreezeOnLoss(on: boolean): void —— 丢帧时定格画面
napi_value SetFreezeOnLoss(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_session) g_session->SetFreezeOnLoss(argc >= 1 && GetBool(env, args[0], true));
    return Undefined(env);
}

// setRefreshRateHint(fps: number): void —— 播放时请求的屏幕刷新率，0 = 交还系统决定（与会话无关，进程级）
napi_value SetRefreshRateHint(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t fps = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &fps);
    DisplayRateVote::Get().Set(fps);
    return Undefined(env);
}

// setEnhanceLevel(level: number): string —— 画质增强 0 关闭 / 1 标准 / 2 高；空串 = 成功
napi_value SetEnhanceLevel(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!g_session) return MakeString(env, "");
    return MakeString(env, g_session->SetEnhanceLevel(argc >= 1 ? GetInt(env, args[0], 0) : 0));
}

// getSocketFlows(): SocketFlow[] —— 当前已连接的 TCP 连接的地址，给网络加速接口标记高优先级。
// 不传 socket 描述符：传给系统服务的描述符会被它持有，我们 close() 后连接仍然不断开
napi_value GetSocketFlows(napi_env env, napi_callback_info) {
    napi_value arr;
    napi_create_array(env, &arr);
    if (!g_session) return arr;
    const auto flows = g_session->SocketFlows();
    for (size_t i = 0; i < flows.size(); ++i) {
        napi_value obj;
        napi_create_object(env, &obj);
        Set(env, obj, "localAddress", MakeString(env, flows[i].localAddress));
        Set(env, obj, "localPort", MakeNumber(env, flows[i].localPort));
        Set(env, obj, "remoteAddress", MakeString(env, flows[i].remoteAddress));
        Set(env, obj, "remotePort", MakeNumber(env, flows[i].remotePort));
        napi_set_element(env, arr, uint32_t(i), obj);
    }
    return arr;
}

// usbProbe(fd, interfaceId, epIn?): UsbProbeResult —— 验证能否直接对 usbfs 发 ioctl（顺便读序列号）
napi_value UsbProbe(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    UsbProbeResult r;
    if (argc < 2) {
        r.error = L("参数不足", "參數不足", "missing arguments");
    } else {
        r = ProbeUsbFs(GetInt(env, args[0], -1), GetInt(env, args[1], 0), argc >= 3 ? GetInt(env, args[2], -1) : -1);
    }
    napi_value obj;
    napi_create_object(env, &obj);
    Set(env, obj, "ok", MakeBool(env, r.ok));
    Set(env, obj, "serial", MakeString(env, r.serial));
    Set(env, obj, "error", MakeString(env, r.error));
    Set(env, obj, "bulkRefused", MakeBool(env, r.bulkRefused));
    return obj;
}

// usbFeed(data: ArrayBuffer, length: number): void —— 兼容传输：ArkTS 读到的 IN 端点数据
napi_value UsbFeed(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!g_pump || argc < 2) return Undefined(env);
    void* data = nullptr;
    size_t size = 0;
    if (napi_get_arraybuffer_info(env, args[0], &data, &size) != napi_ok) return Undefined(env);
    const int32_t n = GetInt(env, args[1], 0);
    if (n > 0 && size_t(n) <= size) g_pump->Feed(static_cast<const uint8_t*>(data), size_t(n));
    return Undefined(env);
}

// usbFeedError(): void —— 兼容传输：设备断开或读取出错
napi_value UsbFeedError(napi_env env, napi_callback_info) {
    if (g_pump) g_pump->FeedError();
    return Undefined(env);
}

// usbTakeWrite(): ArrayBuffer | undefined —— 兼容传输：取出待写入 OUT 端点的数据
napi_value UsbTakeWrite(napi_env env, napi_callback_info) {
    std::vector<uint8_t> out;
    if (!g_pump || !g_pump->TakeWrite(&out)) return Undefined(env);
    void* data = nullptr;
    napi_value buf;
    napi_create_arraybuffer(env, out.size(), &data, &buf);
    std::memcpy(data, out.data(), out.size());
    return buf;
}

// usbWriteDone(result: number): void —— 兼容传输：bulkTransfer 的返回值（写入字节数，<0 失败）
napi_value UsbWriteDone(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_pump) g_pump->WriteDone(argc >= 1 ? GetInt(env, args[0], -1) : -1);
    return Undefined(env);
}

// ---------------------------------------------------------------- 录像

// recordSupport(): RecordSupport —— 本机能不能边播边录（要两路硬件解码）、只录制（一路）、用哪种编码
napi_value RecordSupportInfo(napi_env env, napi_callback_info) {
    const RecordSupport s = Recorder::Support();
    napi_value obj;
    napi_create_object(env, &obj);
    Set(env, obj, "decoders", MakeNumber(env, s.decoders));
    Set(env, obj, "hevc", MakeBool(env, s.hevc));
    Set(env, obj, "avc", MakeBool(env, s.avc));
    Set(env, obj, "scaler", MakeBool(env, s.scaler));
    return obj;
}

// startRecording(config: RecordConfig): string —— 空串 = 已开始
napi_value StartRecording(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return MakeString(env, L("参数不足", "參數不足", "missing arguments"));
    if (!g_session) return MakeString(env, L("没有进行中的串流", "沒有進行中的串流", "no active stream"));
    const napi_value cfg = args[0];
    RecordConfig c;
    napi_value v = Prop(env, cfg, "dir");
    c.dir = v ? GetString(env, v) : "";
    v = Prop(env, cfg, "name");
    c.baseName = v ? GetString(env, v) : "";
    v = Prop(env, cfg, "maxHeight");
    c.maxHeight = v ? GetInt(env, v, 1080) : 1080;
    v = Prop(env, cfg, "bitrateKbps");
    c.bitrateKbps = v ? GetInt(env, v, 8000) : 8000;
    v = Prop(env, cfg, "fixedBitrate");
    c.fixedBitrate = v ? GetBool(env, v, false) : false;
    if (c.dir.empty() || c.baseName.empty())
        return MakeString(env, L("录像路径无效", "錄影路徑無效", "invalid recording path"));
    return MakeString(env, g_session->StartRecording(c));
}

napi_value MakeRecordStats(napi_env env, const RecordStats& s) {
    napi_value obj;
    napi_create_object(env, &obj);
    Set(env, obj, "active", MakeBool(env, s.active));
    Set(env, obj, "waitingKeyframe", MakeBool(env, s.waitingKeyframe));
    Set(env, obj, "durationMs", MakeNumber(env, double(s.durationMs)));
    Set(env, obj, "bytes", MakeNumber(env, double(s.bytes)));
    Set(env, obj, "framesIn", MakeNumber(env, double(s.framesIn)));
    Set(env, obj, "framesEncoded", MakeNumber(env, double(s.framesEncoded)));
    Set(env, obj, "framesDropped", MakeNumber(env, double(s.framesDropped)));
    Set(env, obj, "width", MakeNumber(env, s.width));
    Set(env, obj, "height", MakeNumber(env, s.height));
    Set(env, obj, "bitrateKbps", MakeNumber(env, s.bitrateKbps));
    Set(env, obj, "hevc", MakeBool(env, s.hevc));
    Set(env, obj, "scaled", MakeBool(env, s.scaled));
    Set(env, obj, "error", MakeString(env, s.error));
    napi_value files;
    napi_create_array_with_length(env, s.files.size(), &files);
    for (size_t i = 0; i < s.files.size(); ++i) napi_set_element(env, files, uint32_t(i), MakeString(env, s.files[i]));
    Set(env, obj, "files", files);
    return obj;
}

// getRecordStats(): RecordStats
napi_value GetRecordStats(napi_env env, napi_callback_info) {
    return MakeRecordStats(env, g_session ? g_session->RecordingStats() : RecordStats());
}

// stopRecording(): Promise<RecordStats> —— 收尾（编码器吐完、写文件尾）放到工作线程，不卡界面
struct StopRecordingWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::unique_ptr<Recorder> recorder;
    RecordStats result;
};

napi_value StopRecording(napi_env env, napi_callback_info) {
    napi_value promise;
    auto* w = new StopRecordingWork();
    napi_create_promise(env, &w->deferred, &promise);
    if (g_session) w->recorder = g_session->StopRecording();
    napi_value name;
    napi_create_string_utf8(env, "stopRecording", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(
        env, nullptr, name,
        [](napi_env, void* data) {
            auto* w = static_cast<StopRecordingWork*>(data);
            if (w->recorder) {
                w->recorder->Finish();
                w->result = w->recorder->Stats();
                w->recorder.reset();
            }
        },
        [](napi_env env, napi_status, void* data) {
            auto* w = static_cast<StopRecordingWork*>(data);
            napi_resolve_deferred(env, w->deferred, MakeRecordStats(env, w->result));
            napi_delete_async_work(env, w->work);
            delete w;
        },
        w, &w->work);
    napi_queue_async_work(env, w->work);
    return promise;
}

double GetDouble(napi_env env, napi_value v, double fallback) {
    double d = fallback;
    if (v == nullptr || napi_get_value_double(env, v, &d) != napi_ok) return fallback;
    return d;
}

// padConfigure({ enabled, faceByLabel, deadZone, triggerPoint }): void —— 手柄设置（enabled：用户打开了、且播放页在前台）
napi_value PadConfigure(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return Undefined(env);
    napi_value v = Prop(env, args[0], "enabled");
    g_padConfig.enabled = v ? GetBool(env, v, false) : false;
    v = Prop(env, args[0], "faceByLabel");
    g_padConfig.faceByLabel = v ? GetBool(env, v, false) : false;
    g_padConfig.deadZone = GetDouble(env, Prop(env, args[0], "deadZone"), nssft::pad::kDefaultDeadZone);
    g_padConfig.triggerPoint = GetDouble(env, Prop(env, args[0], "triggerPoint"), nssft::pad::kDefaultTriggerPoint);
    if (g_session) g_session->ConfigurePad(g_padConfig);
    return Undefined(env);
}

// padDevicePresent(present: boolean): void —— 本机连着手柄（系统输入设备里有手柄）
napi_value PadDevicePresent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    g_padPresent = argc >= 1 && GetBool(env, args[0], false);
    if (g_session) g_session->SetPadDevicePresent(g_padPresent);
    return Undefined(env);
}

// padPlaying(on: boolean): void —— false：菜单或对话框开着，手柄接着但什么都不按
napi_value PadPlaying(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_session) g_session->SetPadPlaying(argc >= 1 && GetBool(env, args[0], true));
    return Undefined(env);
}

// padKey(keyCode: number, down: boolean): boolean —— 返回 true：这个键交给了游戏机，界面别再处理
napi_value PadKey(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2 || !g_session) return MakeBool(env, false);
    return MakeBool(env, g_session->PadKey(GetInt(env, args[0], 0), GetBool(env, args[1], false)));
}

// padAxes(lx, ly, rx, ry, lt, rt, hx, hy): boolean —— 摇杆 -1..1（y 向下为正）、扳机 0..1、十字键；这次没报的轴传 NaN
napi_value PadAxes(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!g_session) return MakeBool(env, false);
    double v[8];
    for (size_t i = 0; i < 8; ++i) v[i] = i < argc ? GetDouble(env, args[i], NAN) : NAN;
    const nssft::pad::Axes a{v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]};
    return MakeBool(env, g_session->PadAxes(a));
}

// padTouchShown(shown: boolean): void —— 触屏手柄显示着（显示着就算有手柄，接上游戏机）
napi_value PadTouchShown(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    g_padTouchShown = argc >= 1 && GetBool(env, args[0], false);
    if (g_session) g_session->SetPadTouchShown(g_padTouchShown);
    return Undefined(env);
}

// padTouch(buttons, lx, ly, rx, ry): void —— 触屏手柄的整体状态：按键位（HidNpadButton）、摇杆 -1..1（y 向下为正）
napi_value PadTouch(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!g_session || argc < 5) return Undefined(env);
    const double b = GetDouble(env, args[0], 0);
    g_session->PadTouch(b > 0 ? uint64_t(b) : 0, GetDouble(env, args[1], 0), GetDouble(env, args[2], 0),
                        GetDouble(env, args[3], 0), GetDouble(env, args[4], 0));
    return Undefined(env);
}

// padReset(): void —— 松开一切（失去焦点、切后台时按着的键不会再报松开）
napi_value PadReset(napi_env env, napi_callback_info) {
    if (g_session) g_session->ResetPad();
    return Undefined(env);
}

// getPadStatus(): PadStatus
napi_value GetPadStatus(napi_env env, napi_callback_info) {
    PadStatus s;
    if (g_session) s = g_session->PadStats();
    napi_value obj;
    napi_create_object(env, &obj);
    Set(env, obj, "takesInput", MakeBool(env, s.takesInput));
    Set(env, obj, "attached", MakeBool(env, s.attached));
    Set(env, obj, "sent", MakeNumber(env, double(s.sent)));
    Set(env, obj, "buttons", MakeString(env, nssft::pad::ButtonNames(s.now.buttons)));
    Set(env, obj, "lx", MakeNumber(env, s.now.lx));
    Set(env, obj, "ly", MakeNumber(env, s.now.ly));
    Set(env, obj, "rx", MakeNumber(env, s.now.rx));
    Set(env, obj, "ry", MakeNumber(env, s.now.ry));
    return obj;
}

// getStats(): SessionStats
napi_value GetStats(napi_env env, napi_callback_info) {
    SessionStats s;
    if (g_session) s = g_session->Stats();

    napi_value obj;
    napi_create_object(env, &obj);
    Set(env, obj, "active", MakeBool(env, s.active));
    Set(env, obj, "renderingPaused", MakeBool(env, s.renderingPaused));
    Set(env, obj, "message", MakeString(env, s.message));

    const nssft::SourceStats& src = s.source;
    Set(env, obj, "connected", MakeBool(env, src.connected));
    Set(env, obj, "videoPackets", MakeNumber(env, double(src.videoPackets)));
    Set(env, obj, "videoBytes", MakeNumber(env, double(src.videoBytes)));
    Set(env, obj, "keyframes", MakeNumber(env, double(src.keyframes)));
    Set(env, obj, "audioPackets", MakeNumber(env, double(src.audioPackets)));
    Set(env, obj, "audioBytes", MakeNumber(env, double(src.audioBytes)));
    Set(env, obj, "keyRequests", MakeNumber(env, double(src.keyRequests)));
    Set(env, obj, "resyncs", MakeNumber(env, double(src.resyncs)));
    Set(env, obj, "reconnects", MakeNumber(env, double(src.reconnects)));
    Set(env, obj, "streamWidth", MakeNumber(env, src.width));
    Set(env, obj, "streamHeight", MakeNumber(env, src.height));
    Set(env, obj, "consoleAgeMs", MakeNumber(env, src.ageSamples ? double(src.ageTotalUs) / double(src.ageSamples) / 1000.0 : 0));
    Set(env, obj, "consoleTakesInput", MakeBool(env, src.consoleTakesInput));
    Set(env, obj, "consoleStatusReason", MakeNumber(env, src.statusReason));
    Set(env, obj, "consoleStatusHead", MakeString(env, src.statusHead));
    Set(env, obj, "consoleStatusDetail", MakeString(env, src.statusDetail));
    Set(env, obj, "decoderWidth", MakeNumber(env, s.decoderWidth));
    Set(env, obj, "decoderHeight", MakeNumber(env, s.decoderHeight));

    Set(env, obj, "framesRendered", MakeNumber(env, double(s.framesRendered)));
    Set(env, obj, "videoDropped", MakeNumber(env, double(s.videoDropped)));
    Set(env, obj, "lastCatchUpMs", MakeNumber(env, double(s.lastCatchUpMs)));
    Set(env, obj, "netOpt", MakeBool(env, s.netOpt));
    Set(env, obj, "gopPackets", MakeNumber(env, double(s.gopPackets)));
    Set(env, obj, "gopBytes", MakeNumber(env, double(s.gopBytes)));
    Set(env, obj, "audioEnabled", MakeBool(env, s.audioEnabled));
    Set(env, obj, "audioFastMode", MakeBool(env, s.audioFastMode));
    Set(env, obj, "audioUnderruns", MakeNumber(env, double(s.audioUnderruns)));
    Set(env, obj, "audioBufferedMs", MakeNumber(env, double(s.audioBufferedMs)));
    Set(env, obj, "audioTargetMs", MakeNumber(env, double(s.audioTargetMs)));
    Set(env, obj, "decoderError", MakeString(env, s.decoderError));

    using nssft::LossCause;
    Set(env, obj, "freezeOnLoss", MakeBool(env, s.freezeOnLoss));
    Set(env, obj, "frozen", MakeBool(env, s.frozen));
    Set(env, obj, "lossGap", MakeNumber(env, double(s.lossEvents[int(LossCause::SequenceGap)])));
    Set(env, obj, "lossResync", MakeNumber(env, double(s.lossEvents[int(LossCause::Resync)])));
    Set(env, obj, "lossOversize", MakeNumber(env, double(s.decoder.oversize)));
    Set(env, obj, "lostFrames", MakeNumber(env, double(s.lostFrames)));
    Set(env, obj, "frameIntervalUs", MakeNumber(env, double(s.frameIntervalUs)));
    Set(env, obj, "keyframeIntervalMs", MakeNumber(env, double(s.keyframeIntervalMs)));
    Set(env, obj, "freezeEvents", MakeNumber(env, double(s.decoder.freezeEvents)));
    Set(env, obj, "freezeTotalMs", MakeNumber(env, double(s.decoder.freezeTotalMs)));
    Set(env, obj, "freezeGiveUps", MakeNumber(env, double(s.decoder.freezeGiveUps)));
    Set(env, obj, "lastFreezeMs", MakeNumber(env, double(s.lastFreezeMs)));
    Set(env, obj, "vsyncPeriodUs", MakeNumber(env, double(s.vsyncPeriodUs)));
    Set(env, obj, "vsyncDeferred", MakeNumber(env, double(s.decoder.vsyncDeferred)));
    Set(env, obj, "vsyncDropped", MakeNumber(env, double(s.decoder.vsyncDropped)));
    Set(env, obj, "stutters", MakeNumber(env, double(s.decoder.stutters)));
    Set(env, obj, "renderJitterMs", MakeNumber(env, double(s.timing.jitterMs10) / 10.0));
    Set(env, obj, "renderMaxGapMs", MakeNumber(env, double(s.timing.maxGapMs)));
    Set(env, obj, "enhanceRequested", MakeNumber(env, double(s.enhanceRequested)));
    Set(env, obj, "enhanceLevel", MakeNumber(env, double(s.enhanceLevel)));
    Set(env, obj, "enhanceLatencyUs", MakeNumber(env, double(s.enhanceLatencyUs)));
    Set(env, obj, "enhanceError", MakeString(env, s.enhanceError));
    return obj;
}

void HilogSink(nssft::LogLevel level, const std::string& msg) {
    ::LogLevel l = LOG_INFO;
    switch (level) {
        case nssft::LogLevel::Debug: l = LOG_DEBUG; break;
        case nssft::LogLevel::Info: l = LOG_INFO; break;
        case nssft::LogLevel::Warn: l = LOG_WARN; break;
        case nssft::LogLevel::Error: l = LOG_ERROR; break;
    }
    OH_LOG_Print(LOG_APP, l, 0x5346, "NSSFT", "%{public}s", msg.c_str());
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    nssft::SetLogSink(&HilogSink);
    napi_property_descriptor desc[] = {
        {"startDiscovery", nullptr, StartDiscovery, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopDiscovery", nullptr, StopDiscovery, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDevices", nullptr, GetDevices, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"connect", nullptr, Connect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"disconnect", nullptr, Disconnect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pauseVideo", nullptr, PauseVideo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resumeVideo", nullptr, ResumeVideo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setAudioEnabled", nullptr, SetAudioEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setNetOptimization", nullptr, SetNetOptimization, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setFreezeOnLoss", nullptr, SetFreezeOnLoss, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setRefreshRateHint", nullptr, SetRefreshRateHint, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setEnhanceLevel", nullptr, SetEnhanceLevel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSocketFlows", nullptr, GetSocketFlows, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStats", nullptr, GetStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recordSupport", nullptr, RecordSupportInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startRecording", nullptr, StartRecording, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopRecording", nullptr, StopRecording, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRecordStats", nullptr, GetRecordStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"padConfigure", nullptr, PadConfigure, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"padDevicePresent", nullptr, PadDevicePresent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"padPlaying", nullptr, PadPlaying, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"padKey", nullptr, PadKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"padAxes", nullptr, PadAxes, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"padReset", nullptr, PadReset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"padTouchShown", nullptr, PadTouchShown, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"padTouch", nullptr, PadTouch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPadStatus", nullptr, GetPadStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"usbProbe", nullptr, UsbProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"usbFeed", nullptr, UsbFeed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"usbFeedError", nullptr, UsbFeedError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"usbTakeWrite", nullptr, UsbTakeWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"usbWriteDone", nullptr, UsbWriteDone, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setLanguage", nullptr, SetLanguage, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) { napi_module_register(&g_module); }
