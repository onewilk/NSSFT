#include "sft_net_source.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstring>

#include "i18n.h"
#include "log.h"

namespace nssft {

namespace {

#ifdef MSG_NOSIGNAL
constexpr int kSendFlags = MSG_NOSIGNAL;
#else
constexpr int kSendFlags = 0;
#endif

constexpr int kConnectTimeoutMs = 3000;
constexpr int kRetryDelayMs = 1000;

int64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

void SetInt(int fd, int level, int opt, int value) { setsockopt(fd, level, opt, &value, sizeof(value)); }

void SetRecvTimeout(int fd, int ms) {
    timeval tv{};
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

bool ResolveIPv4(const std::string& host, in_addr* out) {
    if (inet_pton(AF_INET, host.c_str(), out) == 1) return true;
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* res = nullptr;
    if (getaddrinfo(host.c_str(), nullptr, &hints, &res) != 0 || res == nullptr) return false;
    *out = reinterpret_cast<sockaddr_in*>(res->ai_addr)->sin_addr;
    freeaddrinfo(res);
    return true;
}

int ConnectWithTimeout(const std::string& host, uint16_t port, int timeoutMs) {
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (!ResolveIPv4(host, &addr.sin_addr)) {
        errno = EHOSTUNREACH;
        return -1;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
#ifdef SO_NOSIGPIPE
    SetInt(fd, SOL_SOCKET, SO_NOSIGPIPE, 1);
#endif

    const int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    if (rc < 0 && errno != EINPROGRESS) {
        const int err = errno;
        close(fd);
        errno = err;
        return -1;
    }
    if (rc < 0) {
        pollfd pfd{fd, POLLOUT, 0};
        rc = poll(&pfd, 1, timeoutMs);
        int err = 0;
        socklen_t len = sizeof(err);
        if (rc <= 0) {
            err = (rc == 0) ? ETIMEDOUT : errno;
        } else {
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
        }
        if (err != 0) {
            close(fd);
            errno = err;
            return -1;
        }
    }
    fcntl(fd, F_SETFL, flags);

    SetInt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
    // 1080p 关键帧可达几百 KB；接收缓冲给大一些，游戏机的发送线程就少等
    SetInt(fd, SOL_SOCKET, SO_RCVBUF, 2 << 20);
    // 游戏机休眠、断网、重启后留下的半开连接靠保活发现：约 11 秒（5 + 2×3）内 recv 报错，然后重连。
    // 没有游戏在屏幕上时游戏机本来就什么都不发，不能用“多久没数据”来判断断线
    SetInt(fd, SOL_SOCKET, SO_KEEPALIVE, 1);
#if defined(TCP_KEEPIDLE)
    SetInt(fd, IPPROTO_TCP, TCP_KEEPIDLE, 5);
#elif defined(TCP_KEEPALIVE)
    SetInt(fd, IPPROTO_TCP, TCP_KEEPALIVE, 5);
#endif
#ifdef TCP_KEEPINTVL
    SetInt(fd, IPPROTO_TCP, TCP_KEEPINTVL, 2);
#endif
#ifdef TCP_KEEPCNT
    SetInt(fd, IPPROTO_TCP, TCP_KEEPCNT, 3);
#endif
    return fd;
}

bool SendAll(int fd, const uint8_t* p, size_t n) {
    while (n > 0) {
        ssize_t r = send(fd, p, n, kSendFlags);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return false;
        p += r;
        n -= size_t(r);
    }
    return true;
}

// 连接失败的原因（给用户看）
std::string ConnectError(int err, const std::string& host) {
    switch (err) {
        case ECONNREFUSED:
            // 地址上有设备，但 9950 没人监听：游戏机的连接方式还是 USB（改完要重启游戏机才生效）
            return Format(L("%s 上的游戏机有回应，但没有通过网络串流：请在游戏机的 SFT 里把连接方式改成“网络”并重启游戏机",
                            "%s 上的遊戲機有回應，但沒有透過網路串流：請在遊戲機的 SFT 裡把連線方式改成「網路」並重新啟動遊戲機",
                            "The console at %s answered but is not streaming over the network: set Connection to "
                            "Network in SFT on the console and restart it"),
                          host.c_str());
        case ETIMEDOUT:
            return Format(L("连接 %s 超时", "連線 %s 逾時", "Connecting to %s timed out"), host.c_str());
        case EHOSTUNREACH:
        case ENETUNREACH:
        case EHOSTDOWN:
            return Format(L("找不到 %s（网络不通）", "找不到 %s（網路不通）", "Cannot reach %s (no route)"), host.c_str());
        default:
            return Format(L("连不上 %s（%s）", "連不上 %s（%s）", "Cannot connect to %s (%s)"), host.c_str(),
                          std::strerror(err));
    }
}

// TCP 连接上的读写
class TcpChannel : public ByteChannel {
public:
    TcpChannel(int fd, const std::atomic<bool>& quickAck) : fd_(fd), quickAck_(quickAck) {}

    int Read(uint8_t* buf, size_t capacity, int timeoutMs) override {
        pollfd pfd{fd_, POLLIN, 0};
        const int rc = poll(&pfd, 1, timeoutMs);
        if (rc == 0) return 0;
        if (rc < 0) return errno == EINTR ? 0 : Fail(errno);
        const ssize_t r = recv(fd_, buf, capacity, 0);
        if (r > 0) {
#ifdef TCP_QUICKACK
            // Linux 的快速 ACK 是一次性的，每次收完都要重新打开
            if (quickAck_) SetInt(fd_, IPPROTO_TCP, TCP_QUICKACK, 1);
#endif
            return int(r);
        }
        if (r == 0) {
            error_ = L("游戏机断开了连接", "遊戲機中斷了連線", "the console closed the connection");
            return -1;
        }
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return Fail(errno);
    }

    int Write(const uint8_t* buf, size_t length, int) override {
        return SendAll(fd_, buf, length) ? int(length) : Fail(errno);
    }

    std::string LastError() const override { return error_; }

private:
    int Fail(int err) {
        error_ = err == ETIMEDOUT ? L("连接超时（游戏机没有响应）", "連線逾時（遊戲機沒有回應）", "connection timed out (the console stopped responding)")
                                  : Format(L("连接出错（%s）", "連線出錯（%s）", "connection error (%s)"), std::strerror(err));
        return -1;
    }

    const int fd_;
    [[maybe_unused]] const std::atomic<bool>& quickAck_;  // 没有 TCP_QUICKACK 的平台（主机测试）用不到
    std::string error_;
};

}  // namespace

// ---------------------------------------------------------------------------
// SftNetSource

SftNetSource::SftNetSource(std::string host, StreamCallbacks callbacks, uint16_t port)
    : host_(std::move(host)), port_(port), receiver_(std::move(callbacks), stop_) {}

SftNetSource::~SftNetSource() { Stop(); }

void SftNetSource::Start() {
    if (thread_.joinable()) return;
    stop_ = false;
    thread_ = std::thread(&SftNetSource::Run, this);
}

void SftNetSource::Stop() {
    stop_ = true;
    if (thread_.joinable()) thread_.join();
}

std::vector<SocketFlow> SftNetSource::SocketFlows() const {
    std::vector<SocketFlow> flows;
    std::lock_guard<std::mutex> lock(fdMutex_);
    if (fd_ < 0) return flows;
    sockaddr_in local{}, remote{};
    socklen_t localLen = sizeof(local), remoteLen = sizeof(remote);
    if (getsockname(fd_, reinterpret_cast<sockaddr*>(&local), &localLen) != 0 ||
        getpeername(fd_, reinterpret_cast<sockaddr*>(&remote), &remoteLen) != 0)
        return flows;
    char localIp[INET_ADDRSTRLEN] = {}, remoteIp[INET_ADDRSTRLEN] = {};
    inet_ntop(AF_INET, &local.sin_addr, localIp, sizeof(localIp));
    inet_ntop(AF_INET, &remote.sin_addr, remoteIp, sizeof(remoteIp));
    flows.push_back({localIp, ntohs(local.sin_port), remoteIp, ntohs(remote.sin_port)});
    return flows;
}

bool SftNetSource::Sleep(int ms) {
    const int64_t until = NowMs() + ms;
    while (!stop_ && NowMs() < until) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    return !stop_;
}

void SftNetSource::Run() {
    bool everConnected = false;
    while (!stop_) {
        receiver_.Status(Format(L("正在连接 %s:%u…", "正在連線 %s:%u…", "Connecting to %s:%u…"), host_.c_str(),
                                unsigned(port_)));
        const int fd = ConnectWithTimeout(host_, port_, kConnectTimeoutMs);
        if (fd < 0) {
            const int err = errno;
            Logf(LogLevel::Warn, "连接 %s:%u 失败：%s", host_.c_str(), unsigned(port_), std::strerror(err));
            const std::string why = ConnectError(err, host_);
            // 被拒绝时提示要停留久一点，用户需要去游戏机上改设置
            receiver_.Status(err == ECONNREFUSED ? why : Format(L("%s，正在重试…", "%s，正在重試…", "%s. Retrying…"), why.c_str()));
            if (everConnected) receiver_.AddReconnect();
            if (!Sleep(err == ECONNREFUSED ? 3000 : kRetryDelayMs)) break;
            continue;
        }

        everConnected = true;
        {
            std::lock_guard<std::mutex> lock(fdMutex_);
            fd_ = fd;
        }
        receiver_.SetConnected(true);
        Logf(LogLevel::Info, "已连接 %s:%u", host_.c_str(), unsigned(port_));
        receiver_.Status(L("已连接，在游戏机上打开一款游戏…", "已連線，在遊戲機上打開一款遊戲…",
                           "Connected. Open a game on the console…"));
        receiver_.BeginConnection();
        TcpChannel channel(fd, quickAck_);
        const std::string why = receiver_.Run(channel);

        {
            std::lock_guard<std::mutex> lock(fdMutex_);
            fd_ = -1;
        }
        close(fd);
        receiver_.SetConnected(false);
        if (stop_) break;
        receiver_.AddReconnect();
        Logf(LogLevel::Warn, "连接断开：%s", why.c_str());
        receiver_.Status(Format(L("%s，正在重连…", "%s，正在重新連線…", "%s. Reconnecting…"), why.c_str()));
        if (!Sleep(800)) break;
    }
}

// ---------------------------------------------------------------------------
// SftDiscovery

SftDiscovery::~SftDiscovery() { Stop(); }

bool SftDiscovery::Start(uint16_t port) {
    if (thread_.joinable()) return true;

    fd_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) {
        Logf(LogLevel::Error, "创建 UDP socket 失败：%s", std::strerror(errno));
        return false;
    }
    SetInt(fd_, SOL_SOCKET, SO_REUSEADDR, 1);
#ifdef SO_REUSEPORT
    SetInt(fd_, SOL_SOCKET, SO_REUSEPORT, 1);
#endif
    SetInt(fd_, SOL_SOCKET, SO_BROADCAST, 1);

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        Logf(LogLevel::Error, "绑定 UDP %u 失败：%s", unsigned(port), std::strerror(errno));
        close(fd_);
        fd_ = -1;
        return false;
    }
    SetRecvTimeout(fd_, 300);

    stop_ = false;
    thread_ = std::thread(&SftDiscovery::Run, this);
    return true;
}

void SftDiscovery::Stop() {
    stop_ = true;
    if (thread_.joinable()) thread_.join();
    if (fd_ >= 0) {
        close(fd_);
        fd_ = -1;
    }
}

std::vector<SftDiscovery::Device> SftDiscovery::Devices() const {
    std::vector<Device> out;
    const int64_t now = NowMs();
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& e : devices_)
        if (now - e.lastSeenMs < 5000) out.push_back(e.device);
    return out;
}

void SftDiscovery::Run() {
    uint8_t buf[512];
    while (!stop_) {
        sockaddr_in from{};
        socklen_t fromLen = sizeof(from);
        const ssize_t r = recvfrom(fd_, buf, sizeof(buf), 0, reinterpret_cast<sockaddr*>(&from), &fromLen);
        if (r <= 0) continue;

        sft::Beacon beacon;
        if (!sft::ParseBeacon(buf, size_t(r), &beacon)) continue;
        char ip[INET_ADDRSTRLEN] = {};
        inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));

        Device d;
        d.ip = ip;  // 以来源地址为准：游戏机广播里写的地址在多网卡、热点下不一定对
        d.port = beacon.port;
        d.name = beacon.name;
        const int64_t now = NowMs();
        std::lock_guard<std::mutex> lock(mutex_);
        bool found = false;
        for (auto& e : devices_) {
            if (e.device.ip == d.ip) {
                e.device = d;
                e.lastSeenMs = now;
                found = true;
            }
        }
        if (!found) devices_.push_back({d, now});
    }
}

}  // namespace nssft
