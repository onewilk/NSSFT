#!/bin/sh
# 桌面测试：core/ 单元测试 + 用 tools/mock_sft.py 模拟游戏机的端到端测试（macOS / Linux）。
#
#   sh tools/test_host.sh
#
# 端到端测试需要 build/test.h264（没有就用 swift tools/make_test_h264.swift 生成；Linux 上请先自备一段
# 1080p60、无 B 帧的 Annex-B H.264 放到这个位置）。
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
CXX="${CXX:-c++}"
FLAGS="-std=c++17 -O1 -Wall -Wextra -pthread"
fail=0

unit() {
    name=$1
    shift
    "$CXX" $FLAGS "$@" -o "build/$name"
    if ! "build/$name"; then fail=1; fi
}

unit sft_protocol_test core/sft_protocol.cpp tools/sft_protocol_test.cpp
unit sft_receiver_test core/sft_receiver.cpp core/sft_usb_source.cpp core/sft_protocol.cpp core/i18n.cpp core/log.cpp \
    tools/sft_receiver_test.cpp
unit frame_loss_test core/frame_loss.cpp tools/frame_loss_test.cpp
unit gop_cache_test core/gop_cache.cpp core/h264.cpp tools/gop_cache_test.cpp
unit i18n_test core/i18n.cpp tools/i18n_test.cpp

"$CXX" $FLAGS core/sft_net_source.cpp core/sft_receiver.cpp core/sft_protocol.cpp core/h264.cpp core/log.cpp core/i18n.cpp \
    tools/sft_probe.cpp -o build/sft_probe

if [ ! -f build/test.h264 ]; then
    if command -v swift >/dev/null 2>&1; then
        swift tools/make_test_h264.swift build/test.h264 6
    else
        echo "没有 build/test.h264，跳过端到端测试"
        [ $fail -eq 0 ] && echo "单元测试全部通过" || echo "有单元测试失败"
        exit $fail
    fi
fi

# 端到端：每个场景起一个只服务一个客户端的模拟游戏机，用 sft_probe 收 N 秒，检查结果行
PORT=19950
BEACON=19951
run_case() {
    label=$1
    seconds=$2
    expect=$3
    shift 3
    python3 tools/mock_sft.py --h264 build/test.h264 --port $PORT --beacon-port $BEACON --no-beacon --once \
        --seconds "$seconds" "$@" >build/mock.log 2>&1 &
    mock=$!
    sleep 1
    out=$(SFT_PORT=$PORT build/sft_probe 127.0.0.1 "$((seconds + 1))" 2>&1 | tail -1)
    wait $mock || true
    if echo "$out" | grep -Eq "$expect"; then
        echo "  ✓ $label"
    else
        echo "  ✗ $label"
        echo "    结果：$out"
        echo "    期望：$expect"
        sed 's/^/    mock: /' build/mock.log
        fail=1
    fi
}

echo "端到端（mock_sft.py）"
run_case "正常收流：画面、声音、关键帧标志一致、没有断档" 3 \
    'frames=(1[5-9][0-9]|[2-9][0-9][0-9]) .*key_mismatch=0 audio_bytes=[1-9][0-9]* losses=0 .*gaps=0' --audio
run_case "序号断档：报丢失并请求关键帧" 4 \
    'losses=[1-9].* key_requests=[2-9].* gaps=[1-9]' --drop-every 50
run_case "状态包和尺寸变化不影响收流" 3 \
    'frames=[1-9][0-9]+ .*losses=0 .*resyncs=0' --status --resize-at 60

# 发现：模拟游戏机往 127.0.0.1 发广播
python3 tools/mock_sft.py --h264 build/test.h264 --port $PORT --beacon-port $BEACON --once --seconds 1 >build/mock.log 2>&1 &
mock=$!
if SFT_BEACON_PORT=$BEACON build/sft_probe --discover 3 | grep -q "mock console"; then
    echo "  ✓ 广播发现"
else
    echo "  ✗ 广播发现"
    fail=1
fi
kill $mock 2>/dev/null || true
wait $mock 2>/dev/null || true

[ $fail -eq 0 ] && echo "全部通过" || echo "有测试失败"
exit $fail
