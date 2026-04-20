#!/usr/bin/env bash
(
set -euo pipefail

# ==========================================
# 权限检查
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo "❌ 错误: 请使用 root 用户运行此脚本 (可以先执行 sudo -i)！"
    exit 1
fi

echo "================================================="
echo " 🚀 云服务器流量防扣费（终极版 v2.1）"
echo "================================================="
echo
echo " 功能特性:"
echo "   ✅ 多云支持       ✅ 阈值自定义"
echo "   ✅ 汇报间隔可配   ✅ 推送失败重试"
echo "   ✅ 出站/入站/双向  ✅ 多网卡自动汇总"
echo "   ✅ 日志自动轮转    ✅ 月初自动重置"
echo "   ✅ 一键卸载"
echo
echo "================================================="
echo

SCRIPT_PATH="/root/traffic_monitor_pro.sh"
LOG_PATH="/var/log/traffic-monitor.log"

# ==========================================
# 第1步：自动识别网卡（傻瓜模式）
# ==========================================
echo "▶️ 正在检测网卡..."
ALL_IFACES="$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v '^lo$' | tr '\n' ' ' | sed 's/ *$//')"

if [ -z "$ALL_IFACES" ]; then
    echo "❌ 未检测到任何网卡，退出"
    exit 1
fi

IFACE_COUNT="$(echo "$ALL_IFACES" | wc -w)"
echo "   检测到 ${IFACE_COUNT} 张网卡: $ALL_IFACES"

if [ "$IFACE_COUNT" -eq 1 ]; then
    SELECTED_IFACES="$ALL_IFACES"
    echo "   ✅ 只有一张网卡，自动选择: $SELECTED_IFACES"
else
    echo
    echo "   多张网卡检测到，可选策略："
    echo "   [1] 全部汇总（推荐，最准确，覆盖所有计费流量）"
    echo "   [2] 仅默认网卡（只监控出口主网卡）"
    echo "   [3] 手动指定（适合高级用户）"
    echo
    read -r -p "   👉 请选择 [1/2/3，默认1]: " IFACE_CHOICE
    IFACE_CHOICE="${IFACE_CHOICE:-1}"

    case "$IFACE_CHOICE" in
        1)
            SELECTED_IFACES="$ALL_IFACES"
            echo "   ✅ 已选择汇总所有网卡: $SELECTED_IFACES"
            ;;
        2)
            SELECTED_IFACES="$(ip -o -4 route show to default | awk '{print $5}' | head -n 1)"
            if [ -z "$SELECTED_IFACES" ]; then
                echo "   ⚠️ 无法识别默认网卡，回退为全部汇总"
                SELECTED_IFACES="$ALL_IFACES"
            fi
            echo "   ✅ 已选择默认网卡: $SELECTED_IFACES"
            ;;
        3)
            read -r -p "   👉 请输入网卡名（多张用空格隔开）: " SELECTED_IFACES
            if [ -z "$SELECTED_IFACES" ]; then
                SELECTED_IFACES="$ALL_IFACES"
                echo "   ⚠️ 未输入，自动使用全部: $SELECTED_IFACES"
            else
                echo "   ✅ 已选择: $SELECTED_IFACES"
            fi
            ;;
        *)
            SELECTED_IFACES="$ALL_IFACES"
            echo "   ✅ 无效选择，默认汇总所有: $SELECTED_IFACES"
            ;;
    esac
fi

# ==========================================
# 第2步：读取旧配置（如存在）
# ==========================================
OLD_SERVERCHAN=""
OLD_TG_BOT=""
OLD_TG_CHAT=""
OLD_REPORT_DAYS=""
OLD_WARN_GB=""
OLD_LIMIT_GB=""
OLD_TRAFFIC_DIR=""
OLD_SERVER_NAME=""
OLD_BILLING_TZ=""

if [ -f "$SCRIPT_PATH" ]; then
    OLD_SERVERCHAN="$(grep '^SERVERCHAN_KEY=' "$SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
    OLD_TG_BOT="$(grep '^TG_BOT_TOKEN=' "$SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
    OLD_TG_CHAT="$(grep '^TG_CHAT_ID=' "$SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
    OLD_REPORT_DAYS="$(grep '^REPORT_DAYS=' "$SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
    OLD_WARN_GB="$(grep '^WARN_GB=' "$SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
    OLD_LIMIT_GB="$(grep '^LIMIT_GB=' "$SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
    OLD_TRAFFIC_DIR="$(grep '^TRAFFIC_DIR=' "$SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
    OLD_SERVER_NAME="$(grep '^SERVER_NAME=' "$SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
    OLD_BILLING_TZ="$(grep '^BILLING_TZ=' "$SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
fi

# ==========================================
# 第2.5步：自动清理旧版本（静默，无需确认）
# ==========================================
echo "▶️ 自动清理旧版本残留..."
rm -f /etc/cron.d/traffic-monitor 2>/dev/null || true
rm -f /etc/logrotate.d/traffic-monitor 2>/dev/null || true
rm -f /root/.traffic_warn_flag 2>/dev/null || true
rm -f /root/.traffic_shutdown_pending 2>/dev/null || true
rm -f /root/.traffic_last_report_date 2>/dev/null || true
rm -f /root/.traffic_month_marker 2>/dev/null || true
rm -f /root/.traffic_150g_warned 2>/dev/null || true
OLD_CRON_CHECK="$(crontab -l 2>/dev/null || true)"
if echo "$OLD_CRON_CHECK" | grep -q 'traffic_monitor_pro.sh'; then
    CLEAN_CRON="$(echo "$OLD_CRON_CHECK" | grep -v 'traffic_monitor_pro.sh' | grep -v '^CRON_TZ=Asia/Shanghai$' || true)"
    printf '%s\n' "$CLEAN_CRON" | crontab - 2>/dev/null || true
fi
rm -f /root/traffic_monitor_pro.sh 2>/dev/null || true
echo "   ✅ 旧版本已清理（旧配置已保留供复用）"

echo
echo "═══════════════════════════════════════"
echo " 🏷️  服务器标识"
echo "═══════════════════════════════════════"
echo "   [1] 谷歌云"
echo "   [2] 腾讯云"
echo "   [3] 阿里云"
echo "   [0] 自定义名称 (如打不出中文可复制粘贴)"
DEFAULT_NAME="${OLD_SERVER_NAME:-谷歌云}"
read -r -p " 👉 请选择序号或直接输入 [1/2/3/0，当前默认: ${DEFAULT_NAME}]: " INPUT_SERVER_NAME

case "${INPUT_SERVER_NAME}" in
    1) SERVER_NAME="谷歌云" ;;
    2) SERVER_NAME="腾讯云" ;;
    3) SERVER_NAME="阿里云" ;;
    0) 
       read -r -p " 👉 请输入新名字: " SERVER_NAME 
       if [ -z "${SERVER_NAME}" ]; then SERVER_NAME="${DEFAULT_NAME}"; fi
       ;;
    "") SERVER_NAME="${DEFAULT_NAME}" ;;
    *) SERVER_NAME="${INPUT_SERVER_NAME}" ;; # 允许用户直接敲英文或直接在此处粘贴
esac

echo
echo "═══════════════════════════════════════"
echo " 🕐 计费周期时区"
echo "═══════════════════════════════════════"
echo "   [1] 太平洋时间（谷歌云 GCP）"
echo "   [2] 北京时间（腾讯云/阿里云/华为云）"
# 根据服务器名自动推荐默认值
DEFAULT_TZ_CHOICE="1"
OLD_TZ_DISPLAY="太平洋时间"
if [ -n "$OLD_BILLING_TZ" ]; then
    if [ "$OLD_BILLING_TZ" == "Asia/Shanghai" ]; then
        DEFAULT_TZ_CHOICE="2"
        OLD_TZ_DISPLAY="北京时间"
    fi
elif echo "$SERVER_NAME" | grep -qE '腾讯|阿里|华为|百度|京东|火山'; then
    DEFAULT_TZ_CHOICE="2"
    OLD_TZ_DISPLAY="北京时间(自动识别)"
fi
read -r -p " 👉 请选择 [1/2，当前: ${OLD_TZ_DISPLAY}]: " INPUT_TZ_CHOICE
TZ_CHOICE="${INPUT_TZ_CHOICE:-$DEFAULT_TZ_CHOICE}"
case "$TZ_CHOICE" in
    2) BILLING_TZ="Asia/Shanghai" ;;
    *) BILLING_TZ="America/Los_Angeles" ;;
esac

echo
echo "═══════════════════════════════════════"
echo " 📋 推送配置"
echo "═══════════════════════════════════════"
read -r -p " 👉 Server酱 SendKey [当前: ${OLD_SERVERCHAN:-无}]: " INPUT_SERVERCHAN
SERVERCHAN_KEY="${INPUT_SERVERCHAN:-$OLD_SERVERCHAN}"

read -r -p " 👉 Telegram Bot Token [当前: ${OLD_TG_BOT:-无}]: " INPUT_TG_BOT
TG_BOT_TOKEN="${INPUT_TG_BOT:-$OLD_TG_BOT}"

read -r -p " 👉 Telegram Chat ID [当前: ${OLD_TG_CHAT:-无}]: " INPUT_TG_CHAT
TG_CHAT_ID="${INPUT_TG_CHAT:-$OLD_TG_CHAT}"

echo
echo "═══════════════════════════════════════"
echo " ⚙️  阈值与汇报配置"
echo "═══════════════════════════════════════"
read -r -p " 👉 预警阈值 GB [当前: ${OLD_WARN_GB:-150}]: " INPUT_WARN_GB
WARN_GB="${INPUT_WARN_GB:-${OLD_WARN_GB:-150}}"

read -r -p " 👉 关机阈值 GB [当前: ${OLD_LIMIT_GB:-180}]: " INPUT_LIMIT_GB
LIMIT_GB="${INPUT_LIMIT_GB:-${OLD_LIMIT_GB:-180}}"

read -r -p " 👉 汇报间隔天数 (1=每天, 7=每周, 10=每10天) [当前: ${OLD_REPORT_DAYS:-1}]: " INPUT_REPORT_DAYS
REPORT_DAYS="${INPUT_REPORT_DAYS:-${OLD_REPORT_DAYS:-1}}"

echo
echo "═══════════════════════════════════════"
echo " 📡 流量统计方向"
echo "═══════════════════════════════════════"
echo "   [1] 仅出站 tx（谷歌云标准计费，推荐）"
echo "   [2] 仅入站 rx"
echo "   [3] 双向 tx+rx（入站也计费的场景）"
CURRENT_DIR_DISPLAY="仅出站"
if [ "$OLD_TRAFFIC_DIR" == "rx" ]; then CURRENT_DIR_DISPLAY="仅入站"; fi
if [ "$OLD_TRAFFIC_DIR" == "both" ]; then CURRENT_DIR_DISPLAY="双向"; fi
read -r -p " 👉 请选择 [1/2/3，当前: ${CURRENT_DIR_DISPLAY}]: " INPUT_TRAFFIC_DIR
case "${INPUT_TRAFFIC_DIR:-}" in
    2) TRAFFIC_DIR="rx" ;;
    3) TRAFFIC_DIR="both" ;;
    *) TRAFFIC_DIR="${OLD_TRAFFIC_DIR:-tx}" ;;
esac

# 输入校验
if ! [[ "$WARN_GB" =~ ^[0-9]+$ ]] || [ "$WARN_GB" -le 0 ]; then
    echo "⚠️ 预警阈值无效，已自动设置为 150 GB"
    WARN_GB=150
fi
if ! [[ "$LIMIT_GB" =~ ^[0-9]+$ ]] || [ "$LIMIT_GB" -le 0 ]; then
    echo "⚠️ 关机阈值无效，已自动设置为 180 GB"
    LIMIT_GB=180
fi
if [ "$WARN_GB" -ge "$LIMIT_GB" ]; then
    echo "⚠️ 预警阈值(${WARN_GB})必须小于关机阈值(${LIMIT_GB})，已自动调整"
    WARN_GB=$(( LIMIT_GB - 20 ))
    if [ "$WARN_GB" -le 0 ]; then WARN_GB=1; fi
    echo "   预警阈值已调整为: ${WARN_GB} GB"
fi
if ! [[ "$REPORT_DAYS" =~ ^[1-9][0-9]*$ ]]; then
    echo "⚠️ 汇报间隔无效，已自动设置为 1 天"
    REPORT_DAYS=1
fi

# 转字节
WARN_BYTES=$(( WARN_GB * 1073741824 ))
LIMIT_BYTES=$(( LIMIT_GB * 1073741824 ))

# 时区显示名
BILLING_TZ_DISPLAY="太平洋时间"
if [ "$BILLING_TZ" == "Asia/Shanghai" ]; then BILLING_TZ_DISPLAY="北京时间"; fi

echo
echo "═══════════════════════════════════════"
echo " 📋 配置确认"
echo "═══════════════════════════════════════"
echo "   服务器:     ${SERVER_NAME}"
echo "   计费时区:   ${BILLING_TZ_DISPLAY}"
echo "   网卡:       $SELECTED_IFACES"
echo "   预警阈值:   ${WARN_GB} GB"
echo "   关机阈值:   ${LIMIT_GB} GB（双重确认）"
echo "   汇报间隔:   每 ${REPORT_DAYS} 天"
echo "   流量方向:   ${TRAFFIC_DIR}"
echo "   Server酱:   ${SERVERCHAN_KEY:-未配置}"
echo "   Telegram:   ${TG_BOT_TOKEN:+已配置}${TG_BOT_TOKEN:-未配置}"
echo "═══════════════════════════════════════"
echo

# 推送渠道空检查
if [ -z "${SERVERCHAN_KEY}" ] && [ -z "${TG_BOT_TOKEN}" ]; then
    echo "⚠️  警告: Server酱和Telegram均未配置，脚本将无法发送任何通知！"
    echo "   流量监控仍然有效（超标仍会关机），但你不会收到提醒。"
    echo
fi

# 部署确认
read -r -p "👉 确认以上配置并开始部署? (回车确认 / n取消): " DEPLOY_CONFIRM
if [ "${DEPLOY_CONFIRM:-}" == "n" ] || [ "${DEPLOY_CONFIRM:-}" == "N" ]; then
    echo "❌ 已取消部署"
    exit 0
fi
echo

# ==========================================
# 第3步：安装依赖
# ==========================================
echo "▶️ 安装必备组件 (vnstat, curl, jq, cron, logrotate)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get install -y -q vnstat curl jq cron logrotate

# ==========================================
# 第4步：为 vnstat 注入计费时区
# ==========================================
echo "▶️ 为 vnstat 注入计费时区: ${BILLING_TZ}（不影响系统时间）..."
mkdir -p /etc/systemd/system/vnstat.service.d
cat > /etc/systemd/system/vnstat.service.d/override.conf << SYS_EOF
[Service]
Environment="TZ=${BILLING_TZ}"
SYS_EOF

systemctl daemon-reload >/dev/null 2>&1
systemctl enable vnstat >/dev/null 2>&1 || true
systemctl restart vnstat >/dev/null 2>&1 || true
systemctl enable cron >/dev/null 2>&1 || true
systemctl restart cron >/dev/null 2>&1 || true

echo "▶️ 等待 vnstat 初始化数据库..."
sleep 3

# ==========================================
# 第5步：配置日志轮转
# ==========================================
echo "▶️ 配置日志自动轮转..."
cat > /etc/logrotate.d/traffic-monitor << 'LOGROTATE_EOF'
/var/log/traffic-monitor.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    maxsize 5M
}
LOGROTATE_EOF

# ==========================================
# 第6步：生成核心脚本
# ==========================================
echo "▶️ 正在生成核心防护脚本..."

# 将网卡列表转成脚本内的数组格式
IFACES_ARRAY=""
for iface in $SELECTED_IFACES; do
    IFACES_ARRAY="${IFACES_ARRAY} \"${iface}\""
done

cat > "$SCRIPT_PATH" <<INNER_EOF
#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ====== 一键卸载模式 ======
if [ "\${1:-}" == "uninstall" ]; then
    echo "================================================="
    echo " 🗑️  流量监控 - 一键卸载"
    echo "================================================="
    echo
    read -r -p "⚠️  确认要完全卸载流量监控吗？(输入 yes 确认): " CONFIRM
    if [ "\$CONFIRM" != "yes" ]; then
        echo "❌ 已取消卸载"
        exit 0
    fi
    echo "▶️ 正在清理..."
    rm -f /etc/cron.d/traffic-monitor
    rm -f /etc/logrotate.d/traffic-monitor
    rm -f /root/.traffic_warn_flag
    rm -f /root/.traffic_shutdown_pending
    rm -f /root/.traffic_last_report_date
    rm -f /root/.traffic_month_marker
    rm -f /var/log/traffic-monitor.log
    rm -f /var/log/traffic-monitor.log.*
    rm -f /etc/systemd/system/vnstat.service.d/override.conf 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart vnstat >/dev/null 2>&1 || true
    OLD_CRON="\$(crontab -l 2>/dev/null || true)"
    CLEAN_CRON="\$(echo "\$OLD_CRON" | grep -v 'traffic_monitor_pro.sh' || true)"
    printf '%s\n' "\$CLEAN_CRON" | crontab - 2>/dev/null || true
    systemctl restart cron >/dev/null 2>&1 || true
    echo
    echo "✅ 卸载完成！以下内容已清理："
    echo "   - /etc/cron.d/traffic-monitor"
    echo "   - /etc/logrotate.d/traffic-monitor"
    echo "   - vnstat 时区覆盖"
    echo "   - 所有标记文件和日志"
    echo "   - crontab 残留条目"
    echo "   - vnstat/curl/jq/cron 已保留（可手动 apt remove）"
    echo
    echo "▶️ 最后删除脚本自身..."
    rm -f /root/traffic_monitor_pro.sh
    echo "✅ 彻底清理完毕！"
    exit 0
fi

INTERFACES=(${IFACES_ARRAY})
SERVER_NAME="${SERVER_NAME}"
BILLING_TZ="${BILLING_TZ}"
SERVERCHAN_KEY="${SERVERCHAN_KEY}"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
REPORT_DAYS="${REPORT_DAYS}"
WARN_GB="${WARN_GB}"
LIMIT_GB="${LIMIT_GB}"
TRAFFIC_DIR="${TRAFFIC_DIR}"

WARN_BYTES=${WARN_BYTES}
LIMIT_BYTES=${LIMIT_BYTES}
FLAG_FILE="/root/.traffic_warn_flag"
PENDING_SHUTDOWN_FILE="/root/.traffic_shutdown_pending"
LAST_REPORT_FILE="/root/.traffic_last_report_date"
MONTH_RESET_FILE="/root/.traffic_month_marker"

# 获取公网 IP（缓存，避免每次调用外部接口）
SERVER_IP="\$(curl -sS --connect-timeout 3 -m 5 https://ifconfig.me 2>/dev/null || curl -sS --connect-timeout 3 -m 5 https://ip.sb 2>/dev/null || echo '未知')"

# ====== 推送函数（带重试）======
send_notify() {
    local title="\$1"
    local msg="\$2"
    local retry_max=2

    if [ -n "\$SERVERCHAN_KEY" ]; then
        local attempt=0
        while [ \$attempt -lt \$retry_max ]; do
            if curl -sS --connect-timeout 5 -m 10 \
                -X POST "https://sctapi.ftqq.com/\$SERVERCHAN_KEY.send" \
                -d "title=\$title" \
                --data-urlencode "desp=\$msg" >/dev/null 2>&1; then
                break
            fi
            attempt=\$((attempt + 1))
            if [ \$attempt -lt \$retry_max ]; then
                echo "\$(date '+%Y-%m-%d %H:%M:%S') [WARN] Server酱推送失败，10秒后重试 (\$attempt/\$retry_max)..."
                sleep 10
            else
                echo "\$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Server酱推送彻底失败，已跳过"
            fi
        done
    fi

    if [ -n "\$TG_BOT_TOKEN" ] && [ -n "\$TG_CHAT_ID" ]; then
        local attempt=0
        while [ \$attempt -lt \$retry_max ]; do
            if curl -sS --connect-timeout 5 -m 10 \
                -X POST "https://api.telegram.org/bot\$TG_BOT_TOKEN/sendMessage" \
                -d "chat_id=\$TG_CHAT_ID" \
                --data-urlencode "text=\$title
\$msg" >/dev/null 2>&1; then
                break
            fi
            attempt=\$((attempt + 1))
            if [ \$attempt -lt \$retry_max ]; then
                echo "\$(date '+%Y-%m-%d %H:%M:%S') [WARN] Telegram推送失败，10秒后重试 (\$attempt/\$retry_max)..."
                sleep 10
            else
                echo "\$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Telegram推送彻底失败，已跳过"
            fi
        done
    fi
}

# ====== 多网卡流量汇总 ======
TOTAL_BYTES=0
for IFACE in "\${INTERFACES[@]}"; do
    case "\$TRAFFIC_DIR" in
        rx)
            BYTES="\$(vnstat --json m 2>/dev/null | jq -r --arg IFACE "\$IFACE" '.interfaces[] | select(.name == \$IFACE) | .traffic.month[-1].rx // 0')"
            ;;
        both)
            JSON_DATA="\$(vnstat --json m 2>/dev/null)"
            TX="\$(echo "\$JSON_DATA" | jq -r --arg IFACE "\$IFACE" '.interfaces[] | select(.name == \$IFACE) | .traffic.month[-1].tx // 0')"
            RX="\$(echo "\$JSON_DATA" | jq -r --arg IFACE "\$IFACE" '.interfaces[] | select(.name == \$IFACE) | .traffic.month[-1].rx // 0')"
            TX="\${TX:-0}"; RX="\${RX:-0}"
            [[ "\$TX" =~ ^[0-9]+\$ ]] || TX=0
            [[ "\$RX" =~ ^[0-9]+\$ ]] || RX=0
            BYTES=\$((TX + RX))
            ;;
        *)
            BYTES="\$(vnstat --json m 2>/dev/null | jq -r --arg IFACE "\$IFACE" '.interfaces[] | select(.name == \$IFACE) | .traffic.month[-1].tx // 0')"
            ;;
    esac
    BYTES="\${BYTES:-0}"
    [[ "\$BYTES" =~ ^[0-9]+\$ ]] || BYTES=0
    TOTAL_BYTES=\$((TOTAL_BYTES + BYTES))
done

TX_BYTES="\$TOTAL_BYTES"

if [ "\$TX_BYTES" -eq 0 ] && [ "\${1:-}" != "test" ] && [ "\${1:-}" != "boot" ] && [ "\${1:-}" != "report" ]; then
    exit 0
fi

DIR_LABEL="出站"
if [ "\$TRAFFIC_DIR" == "rx" ]; then DIR_LABEL="入站"; fi
if [ "\$TRAFFIC_DIR" == "both" ]; then DIR_LABEL="双向"; fi

TX_GB="\$(awk "BEGIN {printf \"%.2f\", \$TX_BYTES/1073741824}")"
REMAIN_GB="\$(awk "BEGIN {printf \"%.2f\", (\$LIMIT_BYTES - \$TX_BYTES)/1073741824}")"

# ====== 月初自动重置标记（使用计费时区）======
CURRENT_MONTH="\$(TZ="\$BILLING_TZ" date +%Y-%m)"
if [ -f "\$MONTH_RESET_FILE" ]; then
    STORED_MONTH="\$(cat "\$MONTH_RESET_FILE" 2>/dev/null || echo "")"
    if [ "\$CURRENT_MONTH" != "\$STORED_MONTH" ]; then
        rm -f "\$FLAG_FILE"
        rm -f "\$PENDING_SHUTDOWN_FILE"
        rm -f "\$LAST_REPORT_FILE"
        echo "\$CURRENT_MONTH" > "\$MONTH_RESET_FILE"
    fi
else
    echo "\$CURRENT_MONTH" > "\$MONTH_RESET_FILE"
fi

# ====== test 模式 ======
if [ "\${1:-}" == "test" ]; then
    send_notify "\${SERVER_NAME} ✅已用\${TX_GB}G/余\${REMAIN_GB}G" \
        "终极版 v2.1 部署完成！
- 服务器: \${SERVER_NAME} (\${SERVER_IP})
- 网卡: \${INTERFACES[*]}
- 流量方向: \${DIR_LABEL}
- 当前流量: \${TX_GB} GB
- 剩余: \${REMAIN_GB} GB
- 预警线: \${WARN_GB} GB
- 关机线: \${LIMIT_GB} GB
- 汇报间隔: 每 \${REPORT_DAYS} 天"
    exit 0
fi

# ====== report 模式（带间隔控制）======
if [ "\${1:-}" == "report" ]; then
    TODAY="\$(date +%Y-%m-%d)"
    SHOULD_REPORT=0

    if [ ! -f "\$LAST_REPORT_FILE" ]; then
        SHOULD_REPORT=1
    else
        LAST_DATE="\$(cat "\$LAST_REPORT_FILE" 2>/dev/null || echo "")"
        if [ -z "\$LAST_DATE" ]; then
            SHOULD_REPORT=1
        else
            LAST_EPOCH="\$(date -d "\$LAST_DATE" +%s 2>/dev/null || echo 0)"
            TODAY_EPOCH="\$(date -d "\$TODAY" +%s)"
            DIFF_DAYS="\$(( (TODAY_EPOCH - LAST_EPOCH) / 86400 ))"
            if [ "\$DIFF_DAYS" -ge "\$REPORT_DAYS" ]; then
                SHOULD_REPORT=1
            fi
        fi
    fi

    if [ "\$SHOULD_REPORT" -eq 1 ]; then
        send_notify "\${SERVER_NAME} 📊已用\${TX_GB}G/余\${REMAIN_GB}G" \
            "\${DIR_LABEL}已用: \${TX_GB} GB，距断电线还剩: \${REMAIN_GB} GB。预警线: \${WARN_GB} GB，关机线: \${LIMIT_GB} GB。安全守护中！"
        echo "\$TODAY" > "\$LAST_REPORT_FILE"
    fi
    exit 0
fi

# ====== boot 模式 ======
if [ "\${1:-}" == "boot" ]; then
    send_notify "\${SERVER_NAME} 🚀开机 已用\${TX_GB}G" \
        "\${SERVER_NAME}(\${SERVER_IP}) 开机！本月\${DIR_LABEL}已用: \${TX_GB} GB，剩余: \${REMAIN_GB} GB。"
    exit 0
fi

# ====== 超标检测与断电逻辑 ======
if [ "\$TX_BYTES" -ge "\$LIMIT_BYTES" ]; then
    if [ -f "\$PENDING_SHUTDOWN_FILE" ]; then
        send_notify "\${SERVER_NAME} ☠️已达\${TX_GB}G 断电!" \
            "连续两次检测超标 (\${DIR_LABEL}已达 \${TX_GB} GB，关机线 \${LIMIT_GB} GB)，防误判结束，切断电源！"
        rm -f "\$PENDING_SHUTDOWN_FILE"
        sleep 5
        /sbin/shutdown -h now
    else
        send_notify "\${SERVER_NAME} ⚠️已达\${TX_GB}G 观察中" \
            "\${DIR_LABEL}流量已达 \${TX_GB} GB（关机线 \${LIMIT_GB} GB），进入 5 分钟观察期！下次仍超标将断电！"
        touch "\$PENDING_SHUTDOWN_FILE"
    fi
elif [ "\$TX_BYTES" -ge "\$WARN_BYTES" ]; then
    rm -f "\$PENDING_SHUTDOWN_FILE"
    if [ ! -f "\$FLAG_FILE" ]; then
        send_notify "\${SERVER_NAME} ⚠️预警 已用\${TX_GB}G/余\${REMAIN_GB}G" \
            "\${DIR_LABEL}已达 \${TX_GB} GB！距离关机线(\${LIMIT_GB}GB)仅剩 \${REMAIN_GB} GB。"
        touch "\$FLAG_FILE"
    fi
else
    rm -f "\$PENDING_SHUTDOWN_FILE"
fi
INNER_EOF

chmod +x "$SCRIPT_PATH"

# ==========================================
# 第7步：写入 /etc/cron.d 独立任务
# ==========================================
echo "▶️ 正在写入定时任务..."
cat > /etc/cron.d/traffic-monitor <<CRON_EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=Asia/Shanghai
*/5 * * * * root $SCRIPT_PATH >> $LOG_PATH 2>&1
@reboot root sleep 30 && $SCRIPT_PATH boot >> $LOG_PATH 2>&1
0 9 * * * root $SCRIPT_PATH report >> $LOG_PATH 2>&1
CRON_EOF
chmod 644 /etc/cron.d/traffic-monitor
systemctl restart cron >/dev/null 2>&1 || true

# ==========================================
# 第8步：发送测试通知
# ==========================================
echo "▶️ 发送测试通知..."
"$SCRIPT_PATH" test

echo
echo "================================================="
echo "🎉 终极版 v2.1 部署完成！"
echo "================================================="
echo "脚本路径:  $SCRIPT_PATH"
echo "日志路径:  $LOG_PATH（自动轮转，最多保留4周）"
echo "定时任务:  /etc/cron.d/traffic-monitor"
echo "─────────────────────────────────────────────"
echo "服务器名:  $SERVER_NAME"
echo "计费时区:  $BILLING_TZ_DISPLAY ($BILLING_TZ)"
echo "监控网卡:  $SELECTED_IFACES"
echo "流量方向:  $TRAFFIC_DIR"
echo "预警阈值:  ${WARN_GB} GB"
echo "关机阈值:  ${LIMIT_GB} GB（双重确认）"
echo "巡检频率:  每 5 分钟"
echo "汇报间隔:  每 ${REPORT_DAYS} 天（北京时间 09:00 检查）"
echo "─────────────────────────────────────────────"
echo "一键卸载:  /root/traffic_monitor_pro.sh uninstall"
echo "================================================="
)
