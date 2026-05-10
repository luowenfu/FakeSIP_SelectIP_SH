#!/bin/sh
########## 可修改参数区域：后期加 IP 就改这里 ##########
# 需要启用 FakeSIP 的内网 IPv4 地址列表
# 格式：IP|备注(不要有空格)
# 后期如果要增加 IP，就按同样格式继续加，一行一个，不要加逗号
TARGET_IPS="
192.168.11.11|注释
192.168.11.12|注释
"

# fakesip接口名
IFACE="br-lan"

# 自动获取“脚本所在目录”
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# FakeSIP 程序路径（默认与脚本同目录）
BIN="$SCRIPT_DIR/fakesip"

# UDP 负载文件路径（默认与脚本同目录）
PAYLOAD="$SCRIPT_DIR/udp.payload.bin"

# 临时目录
TMP_DIR="/tmp"

TMP_FIFO="$TMP_DIR/fakesip-live.pipe.$$"
SAVE_LOG="$SCRIPT_DIR/fakesip_$(date +%Y%m%d_%H%M%S).log"
check_files() {
    if [ ! -x "$BIN" ]; then
        echo "错误：未找到可执行文件或没有执行权限：$BIN"
        exit 1
    fi

    if [ ! -f "$PAYLOAD" ]; then
        echo "错误：未找到 UDP 负载文件：$PAYLOAD"
        exit 1
    fi
}
# 先停止运行中的 FakeSIP
stop_fakesip() {
    "$BIN" -k >/dev/null 2>&1
    sleep 1
}

cleanup_and_stop() {
    echo
    echo "检测到退出信号，正在停止 FakeSIP..."
    "$BIN" -k >/dev/null 2>&1
    [ -p "$TMP_FIFO" ] && rm -f "$TMP_FIFO"
    exit 0
}

delete_old_ip_rules() {
    echo "$TARGET_IPS" | while IFS='|' read -r IP NOTE; do
        [ -z "$IP" ] && continue
        nft delete rule ip fakesip fs_prerouting iifname "$IFACE" ip daddr "$IP" jump fs_rules 2>/dev/null
        nft delete rule ip fakesip fs_postrouting oifname "$IFACE" ip saddr "$IP" jump fs_rules 2>/dev/null
    done
}

apply_rules() {
    H_PREROUTING=$(nft -a list chain ip fakesip fs_prerouting 2>/dev/null | \
    sed -n 's/.*iifname "'"$IFACE"'" jump fs_rules .*# handle \([0-9]\+\)$/\1/p')
    H_POSTROUTING=$(nft -a list chain ip fakesip fs_postrouting 2>/dev/null | \
    sed -n 's/.*oifname "'"$IFACE"'" jump fs_rules .*# handle \([0-9]\+\)$/\1/p')
    delete_old_ip_rules
    if [ -n "$H_PREROUTING" ]; then
        nft delete rule ip fakesip fs_prerouting handle "$H_PREROUTING" 2>/dev/null
    fi

    if [ -n "$H_POSTROUTING" ]; then
        nft delete rule ip fakesip fs_postrouting handle "$H_POSTROUTING" 2>/dev/null
    fi
    echo "$TARGET_IPS" | while IFS='|' read -r IP NOTE; do
        [ -z "$IP" ] && continue
        nft add rule ip fakesip fs_prerouting iifname "$IFACE" ip daddr "$IP" jump fs_rules
        nft add rule ip fakesip fs_postrouting oifname "$IFACE" ip saddr "$IP" jump fs_rules
    done
}
show_status() {
    echo "========== 当前 FakeSIP IPv4 规则 =========="
    nft list table ip fakesip 2>/dev/null || echo "当前未检测到 fakesip 规则表。"
    echo "==========================================="
    echo "FakeSIP 配置的目标 IP 列表："
    echo "$TARGET_IPS" | while IFS='|' read -r IP NOTE; do
        [ -z "$IP" ] && continue

        if [ -n "$NOTE" ]; then
            echo "  - $IP  #$NOTE"
        else
            echo "  - $IP"
        fi
    done
    echo "==========================================="
}

# 等待 FakeSIP 创建规则
wait_fakesip_ready() {
    i=0
    while [ $i -lt 10 ]; do
        nft list table ip fakesip >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done

    echo "错误：等待 FakeSIP 创建 nftables 规则超时。"
    return 1
}
run_mode_1() {
    trap cleanup_and_stop INT TERM
    echo "模式1：显示实时日志不保存（测试）"
    stop_fakesip
    rm -f "$TMP_FIFO"
    mkfifo "$TMP_FIFO"
    cat "$TMP_FIFO" &
    CAT_PID=$!
    "$BIN" -4 -b "$PAYLOAD" -i "$IFACE" >"$TMP_FIFO" 2>&1 &
    FS_PID=$!

    sleep 1

    if ! kill -0 "$FS_PID" 2>/dev/null; then
        echo "FakeSIP 启动失败。"
        kill "$CAT_PID" 2>/dev/null
        rm -f "$TMP_FIFO"
        exit 1
    fi

    wait_fakesip_ready || {
        kill "$CAT_PID" 2>/dev/null
        rm -f "$TMP_FIFO"
        exit 1
    }

    apply_rules
    show_status
    echo "下面开始实时显示 FakeSIP 输出（不保存日志）。"
    echo "按 Ctrl+C 会停止 FakeSIP 并退出脚本。"
    echo "==========================================="

    wait "$CAT_PID"
}

run_mode_2() {
    trap cleanup_and_stop INT TERM

    echo "模式2：显示实时日志并保存（测试）"
    echo "日志文件：$SAVE_LOG"

    stop_fakesip
    : > "$SAVE_LOG"

    "$BIN" -4 -b "$PAYLOAD" -i "$IFACE" >"$SAVE_LOG" 2>&1 &
    FS_PID=$!

    sleep 1

    if ! kill -0 "$FS_PID" 2>/dev/null; then
        echo "FakeSIP 启动失败。"
        cat "$SAVE_LOG"
        exit 1
    fi

    wait_fakesip_ready || exit 1

    apply_rules
    show_status
    echo "下面开始实时显示 FakeSIP 输出，并保存到："
    echo "$SAVE_LOG"
    echo "按 Ctrl+C 会停止 FakeSIP 并退出脚本。"
    echo "==========================================="

    tail -f "$SAVE_LOG"
}

run_mode_3() {
    echo "模式3：以守护进程方式运行（静默正式运行）"
    stop_fakesip
    "$BIN" -4 -b "$PAYLOAD" -i "$IFACE" -d -s

    sleep 1

    if ! wait_fakesip_ready; then
        echo "FakeSIP 启动失败：未检测到 fakesip 规则表。"
        exit 1
    fi

    apply_rules
    show_status

    echo "正在检查进程状态..."
    echo "==========================================="
    pgrep -fa fakesip || true
    echo "==========================================="

    if pgrep -fa fakesip >/dev/null 2>&1; then
        echo "FakeSIP 守护进程已运行成功。"
    else
        echo "FakeSIP 可能未成功运行，请检查。"
        exit 1
    fi
}

run_mode_4() {
    echo "模式4：停止 FakeSIP"
    stop_fakesip

    echo "正在检查进程状态..."
    echo "==========================================="
    pgrep -fa fakesip || true
    echo "==========================================="

    if pgrep -fa fakesip >/dev/null 2>&1; then
        echo "FakeSIP 可能仍在运行，请检查。"
        exit 1
    else
        echo "FakeSIP 已停止。"
    fi
}

show_menu() {
    echo "================ FakeSIP 菜单 ================"
    echo "1. 显示实时日志不保存（测试）"
    echo "2. 显示实时日志并保存（测试）"
    echo "3. 以守护进程方式运行（静默正式运行）"
    echo "4. 停止 FakeSIP"
    echo "0. 退出"
    echo "============================================="
    printf "请输入数字并回车："
}

main() {
    check_files
    if [ -n "$1" ]; then
        CHOICE="$1"
    else
        show_menu
        read -r CHOICE
    fi

    case "$CHOICE" in
        1)
            run_mode_1
            ;;
        2)
            run_mode_2
            ;;
        3)
            run_mode_3
            ;;
        4)
            run_mode_4
            ;;
        0)
            echo "已退出。"
            exit 0
            ;;
        *)
            echo "无效输入：$CHOICE"
            exit 1
            ;;
    esac
}

main "$@"
