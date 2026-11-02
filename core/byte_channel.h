// 一条能读写字节的连接：TCP socket、USB bulk 端点都实现它，SFTR 的解析（SftReceiver）不关心底下是哪种
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace nssft {

class ByteChannel {
public:
    virtual ~ByteChannel() = default;
    // 读：返回读到的字节数；0 表示 timeoutMs 内没有数据；<0 表示连接已断开或出错
    virtual int Read(uint8_t* buf, size_t capacity, int timeoutMs) = 0;
    // 写：返回写入的字节数；<0 表示出错（USB 上游戏机当时没在收请求也会失败，可以过一会再试）
    virtual int Write(const uint8_t* buf, size_t length, int timeoutMs) = 0;
    // 最近一次出错的原因（给用户看），没有就返回空串
    virtual std::string LastError() const { return {}; }
};

}  // namespace nssft
