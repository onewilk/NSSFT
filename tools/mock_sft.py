#!/usr/bin/env python3
"""模拟 SFT 游戏机端：UDP 9951 广播 + TCP 9950 推 SFTR v2 流，没有游戏机也能测客户端。

只用 Python 标准库。H.264 来自 Annex-B 文件（tools/make_test_h264.swift 生成），循环播放。

  python3 tools/mock_sft.py --h264 build/test1080p60.h264 [--fps 60] [--audio] [--drop-every 300]
  python3 tools/mock_sft.py --h264 ... --once --seconds 5     # 测试用：服务一个客户端若干秒后退出

客户端发来的 "SFTK" 会让下一帧换成文件里的下一个关键帧（模拟游戏机马上补一个关键帧）。
--drop-every N 每 N 帧跳过一个序号（模拟游戏机网络忙时跳帧），用来测客户端的定格和关键帧请求。
--status 在开始推流前先发几个“没有画面的原因”状态包。
--resize-at N 第 N 帧起把包头里的尺寸改成 1280x720（只改包头，不改码流，测客户端的尺寸变化处理）。
"""
import argparse
import math
import re
import socket
import struct
import sys
import threading
import time

HEADER = struct.Struct("<IHHIIIIII")
MAGIC = 0x52544653
VIDEO, KEY, AUDIO, STATUS, INPUT = 2, 4, 8, 16, 128
START = re.compile(b"\x00\x00\x00\x01|\x00\x00\x01")


def access_units(data):
    """把 Annex-B 字节流切成访问单元：SPS/PPS 跟着后面的 IDR 一起，每个分片一帧。"""
    starts = [m.start() for m in START.finditer(data)]
    nals = []
    for i, s in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(data)
        nal = data[s:end]
        body = nal[3:] if nal[2] == 1 else nal[4:]
        if body:
            nals.append((body[0] & 0x1F, nal))
    units, pending = [], b""
    for kind, nal in nals:
        pending += nal
        if kind in (1, 5):
            units.append((kind == 5, pending))
            pending = b""
    return units


def local_ip():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        try:
            probe.connect(("192.0.2.1", 9))  # 只选路由，不发包
            return probe.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def beacon(stop, connected, ip, port, beacon_port):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        while not stop.wait(1):
            if connected.is_set():
                continue  # 和真游戏机一样：有客户端连着就不广播
            for target in ("255.255.255.255", "127.0.0.1"):
                try:
                    sock.sendto(f"SFTAP1 {ip} {port} mock console".encode(), (target, beacon_port))
                except OSError:
                    pass


def status_packet(reason, head, detail, seq):
    body = struct.pack("<II", 1, reason) + head.encode()[:63].ljust(64, b"\0") + detail.encode()[:119].ljust(120, b"\0")
    return HEADER.pack(MAGIC, 2, AUDIO | STATUS, 0, 0, 0, len(body), 0, seq) + body


def serve_client(client, units, args, log):
    key_requested = threading.Event()
    gone = threading.Event()
    requests = {"SFTK": 0, "other": 0}

    def reader():
        buf = b""
        try:
            while not gone.is_set():
                chunk = client.recv(64)
                if not chunk:
                    break
                buf += chunk
                while len(buf) >= 4:
                    word, buf = buf[:4].decode("ascii", "replace"), buf[4:]
                    if word == "SFTK":
                        requests["SFTK"] += 1
                        key_requested.set()
                    else:
                        requests["other"] += 1
        except OSError:
            pass
        gone.set()

    threading.Thread(target=reader, daemon=True).start()
    seq = audio_seq = sent = 0
    index = 0
    interval = 1.0 / args.fps
    audio_chunk = 1024  # 每包 1024 个采样点（约 21 ms），和游戏机的录像块差不多
    audio_period = audio_chunk / 48000
    audio_phase = 0.0
    pcm_data = open(args.pcm, "rb").read() if args.pcm else b""
    pcm_data = pcm_data[:len(pcm_data) // 4 * 4]
    pcm_pos = 0
    next_audio = time.monotonic()
    started = time.monotonic()
    deadline = started + args.seconds if args.seconds else None
    if args.status:
        for i in range(3):
            client.sendall(status_packet(3, "No game on screen", "Start a game to stream it", i))
            time.sleep(0.3)
        client.sendall(status_packet(0, "", "", 3))
    next_frame = time.monotonic()
    while not gone.is_set():
        now = time.monotonic()
        if deadline and now >= deadline:
            break
        if (args.audio or args.pcm) and now >= next_audio:
            if pcm_data:
                n = audio_chunk * 4
                pcm = bytearray(pcm_data[pcm_pos:pcm_pos + n])
                pcm_pos = (pcm_pos + n) % len(pcm_data)
                if len(pcm) < n:  # 文件末尾接回开头
                    pcm += pcm_data[:n - len(pcm)]
            else:
                pcm = bytearray()
                for _ in range(audio_chunk):
                    v = int(6000 * math.sin(audio_phase))
                    audio_phase += 2 * math.pi * 440 / 48000
                    pcm += struct.pack("<hh", v, v)
            client.sendall(HEADER.pack(MAGIC, 2, AUDIO, 48000, 2, 0, len(pcm), 0, audio_seq) + pcm)
            audio_seq += 1
            next_audio += audio_period
        if now < next_frame:
            time.sleep(min(next_frame - now, 0.002))
            continue
        next_frame += interval
        if key_requested.is_set():
            key_requested.clear()
            # 跳到下一个关键帧（文件里没有就回到开头）
            nxt = next((j for j in range(index, len(units)) if units[j][0]), 0)
            index = nxt
        is_key, payload = units[index]
        index = (index + 1) % len(units)
        if args.drop_every and sent > 0 and sent % args.drop_every == 0:
            seq += 1  # 跳过一个序号
        w, h = (1280, 720) if args.resize_at and sent >= args.resize_at else (args.width, args.height)
        flags = VIDEO | (KEY if is_key else 0) | (INPUT if args.input else 0)
        try:
            client.sendall(HEADER.pack(MAGIC, 2, flags, w, h, 20000, len(payload), 0, seq & 0xFFFFFFFF) + payload)
        except OSError:
            break
        seq += 1
        sent += 1
    gone.set()
    log(f"client done: {sent} frames, {audio_seq} audio packets, requests {requests}")
    return requests


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--h264", required=True)
    p.add_argument("--fps", type=float, default=60)
    p.add_argument("--width", type=int, default=1920)
    p.add_argument("--height", type=int, default=1080)
    p.add_argument("--port", type=int, default=9950)
    p.add_argument("--beacon-port", type=int, default=9951)
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--no-beacon", action="store_true")
    p.add_argument("--audio", action="store_true")
    p.add_argument("--pcm", help="循环播放这个 48 kHz 立体声 16 位 PCM 文件（不给时 --audio 发 440 Hz 单音）；隐含 --audio")
    p.add_argument("--status", action="store_true")
    p.add_argument("--input", action="store_true", help="包头带“接受手柄输入”标志")
    p.add_argument("--drop-every", type=int, default=0)
    p.add_argument("--resize-at", type=int, default=0)
    p.add_argument("--seconds", type=float, default=0, help="每个客户端推流多久后断开（0 = 一直推）")
    p.add_argument("--once", action="store_true", help="服务完一个客户端就退出")
    args = p.parse_args()

    with open(args.h264, "rb") as f:
        units = access_units(f.read())
    keys = sum(1 for k, _ in units if k)
    if not units or not keys:
        sys.exit("H.264 文件里没有帧或没有关键帧")
    log = lambda m: print(f"[mock_sft] {m}", flush=True)
    stop, connected = threading.Event(), threading.Event()
    ip = local_ip()
    if not args.no_beacon:
        threading.Thread(target=beacon, args=(stop, connected, ip, args.port, args.beacon_port), daemon=True).start()
    log(f"{len(units)} frames ({keys} keyframes) at {args.fps:g} fps · TCP {args.port} · beacon {ip}")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((args.bind, args.port))
        server.listen(1)
        try:
            while True:
                client, address = server.accept()
                connected.set()
                log(f"client {address[0]}:{address[1]}")
                with client:
                    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    try:
                        serve_client(client, units, args, log)
                    except OSError as e:
                        log(f"client error: {e}")
                connected.clear()
                if args.once:
                    break
        except KeyboardInterrupt:
            pass
    stop.set()


if __name__ == "__main__":
    main()
