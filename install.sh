#!/usr/bin/env bash
# ==============================================================================
# 项目名称: VPS-Proxy (海外 VPS 极速代理一键部署与管理脚本)
# 支持内核: sing-box 最新版
# 包含协议: 
#   1. Hysteria 2 (UDP 8443 / 自定义) - 极速主力、低延迟防抖抗丢包
#   2. VLESS + REALITY (TCP 443 / 自定义) - 伪装苹果 iCloud，隐蔽抗封
#   3. VLESS + WS + TLS (TCP 2053 / 自定义) - Cloudflare CDN 橙色小云朵兜底
# 系统支持: Ubuntu 20.04+, Debian 11+, CentOS 8+, Rocky Linux, AlmaLinux
# 项目开源: https://github.com/callac/vps-proxy
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
META_FILE="${CONFIG_DIR}/vps-proxy.meta"
BIN_FILE="/usr/bin/sing-box"
MGR_SCRIPT="/usr/local/bin/vps-proxy"
SHORTCUT="/usr/local/bin/sb"

# ----------------- 基础函数 -----------------

print_banner() {
    clear
    echo -e "${SKYBLUE}==================================================================${PLAIN}"
    echo -e "${GREEN}      🚀 VPS-Proxy: 海外 VPS 极速全自动代理部署与管理脚本          ${PLAIN}"
    echo -e "${SKYBLUE}==================================================================${PLAIN}"
    echo -e "  * 内核架构: sing-box 官方最新核心"
    echo -e "  * 包含协议: Hysteria 2 + VLESS-REALITY + Cloudflare CDN 兜底"
    echo -e "  * 网络优化: 原生 BBR + FQ 拥塞控制网络加速"
    echo -e "  * 证书支持: Let's Encrypt 官方证书自动化申请与自动续期"
    echo -e "  * 便捷命令: 部署后随时在终端输入 ${YELLOW}sb${PLAIN} 或 ${YELLOW}vps-proxy${PLAIN} 进行管理"
    echo -e "${SKYBLUE}==================================================================${PLAIN}\n"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误] 必须使用 root 用户执行此脚本！${PLAIN}"
        exit 1
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -s4 -m 5 https://api.ipify.org 2>/dev/null || curl -s4 -m 5 https://ifconfig.me 2>/dev/null || curl -s4 -m 5 https://icanhazip.com 2>/dev/null || echo "")
    echo "$ip"
}

resolve_ip() {
    local domain="$1"
    local ip=""
    ip=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s -m 5 "https://1.1.1.1/dns-query?name=${domain}&type=A" -H "accept: application/dns-json" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n 1 || echo "")
    fi
    echo "$ip"
}

# ----------------- 安装依赖 -----------------

install_dependencies() {
    echo -e "${YELLOW}[1/6] 正在安装系统基础依赖组件...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar jq certbot ufw qrencode openssl dnsutils socat >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf makecache -y >/dev/null 2>&1
        dnf install -y curl wget tar jq certbot epel-release qrencode openssl bind-utils socat >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum makecache -y >/dev/null 2>&1
        yum install -y curl wget tar jq certbot epel-release qrencode openssl bind-utils socat >/dev/null 2>&1
    fi
    echo -e "${GREEN}✓ 系统基础依赖安装完成！${PLAIN}"
}

# ----------------- 开启 BBR -----------------

enable_bbr() {
    echo -e "\n${YELLOW}[2/6] 配置并激活 Linux 原生 BBR + FQ 加速...${PLAIN}"
    modprobe tcp_bbr 2>/dev/null || true
    cat << 'EOF' > /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1
    local current_cc
    current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$current_cc" == "bbr" ]]; then
        echo -e "${GREEN}✓ BBR 拥塞控制加速已成功开启并生效！${PLAIN}"
    else
        echo -e "${YELLOW}! 当前拥塞控制算法为: ${current_cc:-未检测到}${PLAIN}"
    fi
}

# ----------------- 域名输入与 DNS 强校验 -----------------

input_and_verify_domains() {
    echo -e "\n${YELLOW}[3/6] 配置域名与 DNS 解析有效性校验...${PLAIN}"
    SERVER_IP=$(get_public_ip)
    if [[ -z "$SERVER_IP" ]]; then
        echo -e "${YELLOW}[提示] 未能自动探测到公网 IPv4，请手动确认服务器 IP。${PLAIN}"
    else
        echo -e "本机公网 IPv4 地址: ${GREEN}${SERVER_IP}${PLAIN}"
    fi

    # 1. 校验直连域名
    while true; do
        read -rp "请输入直连域名 (用于 Hysteria2，请提前解析到本机公网 IP): " DIRECT_DOMAIN
        DIRECT_DOMAIN=$(echo "$DIRECT_DOMAIN" | tr -d '[:space:]')
        if [[ -z "$DIRECT_DOMAIN" ]]; then
            echo -e "${RED}[错误] 直连域名不能为空，请重新输入！${PLAIN}"
            continue
        fi

        echo -e "正在检测 ${DIRECT_DOMAIN} 的 DNS 解析状态..."
        RESOLVED_IP=$(resolve_ip "$DIRECT_DOMAIN")

        if [[ -z "$RESOLVED_IP" ]]; then
            echo -e "${RED}[错误] 域名 ${DIRECT_DOMAIN} 未能查询到任何 A 记录！${PLAIN}"
            echo -e "${YELLOW}请确认域名是否已在 DNS 服务商处添加解析，且全球生效。${PLAIN}"
            read -rp "是否重新输入域名？[Y/n (回车默认Y, 输入n强制继续)]: " RETRY
            RETRY=${RETRY:-Y}
            if [[ "$RETRY" =~ ^[Yy]$ ]]; then
                continue
            else
                break
            fi
        fi

        if [[ -n "$SERVER_IP" && "$RESOLVED_IP" != "$SERVER_IP" ]]; then
            echo -e "${RED}[严重警告] 域名 ${DIRECT_DOMAIN} 当前解析 IP [${RESOLVED_IP}] 与本机公网 IP [${SERVER_IP}] 不匹配！${PLAIN}"
            echo -e "${YELLOW}如果解析错误或尚未生效，申请 Let's Encrypt 官方 SSL 证书必然会报错失败！${PLAIN}"
            read -rp "是否重新输入域名？[Y/n (回车默认Y, 输入n忽略警告继续)]: " RETRY
            RETRY=${RETRY:-Y}
            if [[ "$RETRY" =~ ^[Yy]$ ]]; then
                continue
            else
                break
            fi
        else
            echo -e "${GREEN}✓ 直连域名解析校验通过：${DIRECT_DOMAIN} ➔ ${RESOLVED_IP}${PLAIN}"
            break
        fi
    done

    # 2. 校验 Cloudflare 代理域名
    while true; do
        read -rp "请输入 Cloudflare 域名 (已开启橙色小云朵 CDN，直接回车则与直连域名同二级): " CF_DOMAIN
        CF_DOMAIN=$(echo "$CF_DOMAIN" | tr -d '[:space:]')
        if [[ -z "$CF_DOMAIN" ]]; then
            CF_DOMAIN="$DIRECT_DOMAIN"
        fi

        echo -e "正在检测 ${CF_DOMAIN} 的解析状态..."
        CF_RESOLVED_IP=$(resolve_ip "$CF_DOMAIN")
        if [[ -z "$CF_RESOLVED_IP" ]]; then
            echo -e "${YELLOW}[警告] 域名 ${CF_DOMAIN} 未能查询到解析记录，请确认 Cloudflare 上是否已添加该解析。${PLAIN}"
        else
            echo -e "${GREEN}✓ Cloudflare 域名解析已就绪：${CF_DOMAIN} ➔ ${CF_RESOLVED_IP}${PLAIN}"
        fi
        break
    done
}

# ----------------- 端口配置 -----------------

configure_ports() {
    read -rp "请输入 Hysteria 2 监听端口 [默认 8443]: " PORT_HY2
    PORT_HY2=${PORT_HY2:-8443}

    read -rp "请输入 VLESS-REALITY 监听端口 [默认 443]: " PORT_REALITY
    PORT_REALITY=${PORT_REALITY:-443}

    read -rp "请输入 Cloudflare CDN 节点监听端口 [推荐 2053 / 8443 / 2083，默认 2053]: " PORT_CF
    PORT_CF=${PORT_CF:-2053}

    echo -e "${GREEN}端口规划: Hysteria2=${PORT_HY2}, REALITY=${PORT_REALITY}, Cloudflare=${PORT_CF}${PLAIN}"
}

# ----------------- 安装 sing-box -----------------

install_singbox() {
    echo -e "\n${YELLOW}[4/6] 正在下载并安装 sing-box 最新版...${PLAIN}"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) SB_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64" ;;
        *) echo -e "${RED}[错误] 暂不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    LATEST_TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name 2>/dev/null || echo "")
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        LATEST_TAG="v1.11.4"
    fi
    local sb_ver="${LATEST_TAG#v}"

    local download_url="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${sb_ver}-linux-${SB_ARCH}.tar.gz"
    echo -e "正在拉取 sing-box ${GREEN}${LATEST_TAG}${PLAIN} (${SB_ARCH})..."
    wget -qO /tmp/sing-box.tar.gz "$download_url"
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/
    install -m 755 /tmp/sing-box-${sb_ver}-linux-${SB_ARCH}/sing-box "$BIN_FILE"
    rm -rf /tmp/sing-box*
    echo -e "${GREEN}✓ sing-box 内核安装成功：$($BIN_FILE version | head -n 1)${PLAIN}"
}

# ----------------- 申请 SSL 证书 -----------------

issue_certificates() {
    echo -e "\n${YELLOW}[5/6] 正在申请 Let's Encrypt 官方 SSL 证书...${PLAIN}"
    systemctl stop sing-box 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true

    local cert_cmd="certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email"
    if [[ "$DIRECT_DOMAIN" == "$CF_DOMAIN" ]]; then
        $cert_cmd -d "$DIRECT_DOMAIN" || true
    else
        $cert_cmd -d "$DIRECT_DOMAIN" 2>/dev/null || true
        $cert_cmd -d "$CF_DOMAIN" 2>/dev/null || true
    fi

    # 验证证书是否存在
    if [[ ! -f "/etc/letsencrypt/live/${DIRECT_DOMAIN}/fullchain.pem" ]]; then
        echo -e "${YELLOW}[警告] Let's Encrypt 申请直连域名证书未成功，将尝试生成高强度自签名证书作为备用保证服务启动...${PLAIN}"
        mkdir -p "/etc/letsencrypt/live/${DIRECT_DOMAIN}"
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "/etc/letsencrypt/live/${DIRECT_DOMAIN}/privkey.pem" \
            -out "/etc/letsencrypt/live/${DIRECT_DOMAIN}/fullchain.pem" \
            -days 3650 -subj "/CN=${DIRECT_DOMAIN}" >/dev/null 2>&1
    fi

    # CF 域名证书校验
    if [[ ! -f "/etc/letsencrypt/live/${CF_DOMAIN}/fullchain.pem" ]]; then
        mkdir -p "/etc/letsencrypt/live/${CF_DOMAIN}"
        cp "/etc/letsencrypt/live/${DIRECT_DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${CF_DOMAIN}/fullchain.pem"
        cp "/etc/letsencrypt/live/${DIRECT_DOMAIN}/privkey.pem" "/etc/letsencrypt/live/${CF_DOMAIN}/privkey.pem"
    fi

    echo -e "${GREEN}✓ SSL 证书准备就绪！${PLAIN}"
}

# ----------------- 生成配置与服务 -----------------

generate_config_and_service() {
    echo -e "\n${YELLOW}[6/6] 生成配置文件与管理程序...${PLAIN}"
    mkdir -p "$CONFIG_DIR" /var/lib/sing-box

    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
    local reality_keypair
    reality_keypair=$($BIN_FILE generate reality-keypair)
    REALITY_PRV=$(echo "$reality_keypair" | grep "PrivateKey" | awk '{print $2}')
    REALITY_PUB=$(echo "$reality_keypair" | grep "PublicKey" | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 8)

    # 写入元数据存储
    cat << EOF > "$META_FILE"
{
  "direct_domain": "${DIRECT_DOMAIN}",
  "cf_domain": "${CF_DOMAIN}",
  "port_hy2": ${PORT_HY2},
  "port_reality": ${PORT_REALITY},
  "port_cf": ${PORT_CF},
  "uuid": "${UUID}",
  "hy2_pass": "${HY2_PASS}",
  "reality_prv": "${REALITY_PRV}",
  "reality_pub": "${REALITY_PUB}",
  "short_id": "${SHORT_ID}"
}
EOF

    # 写入 sing-box 配置文件
    cat << EOF > "$CONFIG_FILE"
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${PORT_REALITY},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "gateway.icloud.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "gateway.icloud.com",
            "server_port": 443
          },
          "private_key": "${REALITY_PRV}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT_HY2},
      "users": [
        {
          "password": "${HY2_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DIRECT_DOMAIN}",
        "certificate_path": "/etc/letsencrypt/live/${DIRECT_DOMAIN}/fullchain.pem",
        "key_path": "/etc/letsencrypt/live/${DIRECT_DOMAIN}/privkey.pem"
      }
    },
    {
      "type": "vless",
      "tag": "vless-cf-in",
      "listen": "::",
      "listen_port": ${PORT_CF},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${CF_DOMAIN}",
        "certificate_path": "/etc/letsencrypt/live/${CF_DOMAIN}/fullchain.pem",
        "key_path": "/etc/letsencrypt/live/${CF_DOMAIN}/privkey.pem"
      },
      "transport": {
        "type": "ws",
        "path": "/cf-vless"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    # 写入 systemd 服务
    cat << 'EOF' > /lib/systemd/system/sing-box.service
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box >/dev/null 2>&1
    systemctl restart sing-box

    # 防火墙端口放行
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${PORT_REALITY}/tcp" >/dev/null 2>&1
        ufw allow "${PORT_HY2}/udp" >/dev/null 2>&1
        ufw allow "${PORT_CF}/tcp" >/dev/null 2>&1
    fi
}

# ----------------- 生成管理脚本 -----------------

install_management_tool() {
    cat << 'EOF' > "$MGR_SCRIPT"
#!/usr/bin/env bash
# ==============================================================================
# VPS-Proxy 管理工具
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
META_FILE="${CONFIG_DIR}/vps-proxy.meta"
BIN_FILE="/usr/bin/sing-box"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[错误] 请使用 root 用户运行此命令！${PLAIN}"
    exit 1
fi

if [[ ! -f "$META_FILE" || ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}[错误] 未检测到配置文件，请先运行安装程序！${PLAIN}"
    exit 1
fi

load_meta() {
    DIRECT_DOMAIN=$(jq -r .direct_domain "$META_FILE")
    CF_DOMAIN=$(jq -r .cf_domain "$META_FILE")
    PORT_HY2=$(jq -r .port_hy2 "$META_FILE")
    PORT_REALITY=$(jq -r .port_reality "$META_FILE")
    PORT_CF=$(jq -r .port_cf "$META_FILE")
    UUID=$(jq -r .uuid "$META_FILE")
    HY2_PASS=$(jq -r .hy2_pass "$META_FILE")
    REALITY_PRV=$(jq -r .reality_prv "$META_FILE")
    REALITY_PUB=$(jq -r .reality_pub "$META_FILE")
    SHORT_ID=$(jq -r .short_id "$META_FILE")

    HY2_URL="hysteria2://${HY2_PASS}@${DIRECT_DOMAIN}:${PORT_HY2}?insecure=0&sni=${DIRECT_DOMAIN}#%E4%B8%BB%E5%8A%9B-Hysteria2"
    VLESS_REALITY_URL="vless://${UUID}@${DIRECT_DOMAIN}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=gateway.icloud.com&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp#%E5%A4%87%E7%94%A8-VLESS-REALITY"
    CF_VLESS_URL="vless://${UUID}@${CF_DOMAIN}:${PORT_CF}?encryption=none&security=tls&sni=${CF_DOMAIN}&type=ws&host=${CF_DOMAIN}&path=%2Fcf-vless#%E5%85%9C%E5%BA%95-Cloudflare-CDN"
}

show_info() {
    load_meta
    local s_status
    if systemctl is-active --quiet sing-box; then
        s_status="${GREEN}运行中 (Active)${PLAIN}"
    else
        s_status="${RED}已停止 (Inactive)${PLAIN}"
    fi

    local bbr_status
    bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')

    echo -e "\n${SKYBLUE}==================================================================${PLAIN}"
    echo -e "${GREEN}                 📊 sing-box 当前运行与配置状态                   ${PLAIN}"
    echo -e "${SKYBLUE}==================================================================${PLAIN}"
    echo -e "服务状态:  ${s_status}"
    echo -e "BBR 加速:  ${GREEN}${bbr_status:-未知}${PLAIN}"
    echo -e "直连域名:  ${GREEN}${DIRECT_DOMAIN}${PLAIN}"
    echo -e "CF 域名:   ${GREEN}${CF_DOMAIN}${PLAIN}"

    echo -e "\n${YELLOW}【节点 1 · 主力】Hysteria 2 (UDP 端口: ${PORT_HY2}):${PLAIN}"
    echo -e "${GREEN}${HY2_URL}${PLAIN}"

    echo -e "\n${YELLOW}【节点 2 · 备用】VLESS + REALITY (TCP 端口: ${PORT_REALITY}):${PLAIN}"
    echo -e "${GREEN}${VLESS_REALITY_URL}${PLAIN}"

    echo -e "\n${YELLOW}【节点 3 · 兜底】VLESS + WS + TLS (Cloudflare CDN 端口: ${PORT_CF}):${PLAIN}"
    echo -e "${GREEN}${CF_VLESS_URL}${PLAIN}"
    echo -e "${SKYBLUE}==================================================================${PLAIN}"
}

show_qr() {
    load_meta
    echo -e "\n${SKYBLUE}请选择要展示二维码的节点:${PLAIN}"
    echo -e " 1. Hysteria 2 主力节点"
    echo -e " 2. VLESS + REALITY 节点"
    echo -e " 3. Cloudflare CDN 兜底节点"
    read -rp "请选择 [1-3]: " qr_c
    case "$qr_c" in
        1) qrencode -t ANSIUTF8 "$HY2_URL" ;;
        2) qrencode -t ANSIUTF8 "$VLESS_REALITY_URL" ;;
        3) qrencode -t ANSIUTF8 "$CF_VLESS_URL" ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac
}

change_ports() {
    load_meta
    echo -e "\n${SKYBLUE}==================== 修改服务监听端口 ====================${PLAIN}"
    echo -e "当前端口配置:"
    echo -e "  1. Hysteria 2 端口:    ${GREEN}${PORT_HY2}${PLAIN} (UDP)"
    echo -e "  2. VLESS-REALITY 端口: ${GREEN}${PORT_REALITY}${PLAIN} (TCP)"
    echo -e "  3. Cloudflare 节点端口: ${GREEN}${PORT_CF}${PLAIN} (TCP)"
    echo -e "  4. 一次性修改全部端口"
    echo -e "  0. 返回主菜单"
    read -rp "请选择要修改的项目 [0-4]: " p_choice

    case "$p_choice" in
        1)
            read -rp "请输入新的 Hysteria 2 端口: " NEW_HY2
            NEW_HY2=${NEW_HY2:-$PORT_HY2}
            PORT_HY2=$NEW_HY2
            ;;
        2)
            read -rp "请输入新的 VLESS-REALITY 端口: " NEW_REALITY
            NEW_REALITY=${NEW_REALITY:-$PORT_REALITY}
            PORT_REALITY=$NEW_REALITY
            ;;
        3)
            read -rp "请输入新的 Cloudflare 端口 (支持 2053, 8443, 2083 等): " NEW_CF
            NEW_CF=${NEW_CF:-$PORT_CF}
            PORT_CF=$NEW_CF
            ;;
        4)
            read -rp "请输入新的 Hysteria 2 端口 [当前 ${PORT_HY2}]: " NEW_HY2
            read -rp "请输入新的 VLESS-REALITY 端口 [当前 ${PORT_REALITY}]: " NEW_REALITY
            read -rp "请输入新的 Cloudflare 端口 [当前 ${PORT_CF}]: " NEW_CF
            PORT_HY2=${NEW_HY2:-$PORT_HY2}
            PORT_REALITY=${NEW_REALITY:-$PORT_REALITY}
            PORT_CF=${NEW_CF:-$PORT_CF}
            ;;
        0) return ;;
        *) echo -e "${RED}输入有误！${PLAIN}"; return ;;
    esac

    echo -e "正在更新配置文件与防火墙..."
    # 更新 meta
    jq ".port_hy2 = ${PORT_HY2} | .port_reality = ${PORT_REALITY} | .port_cf = ${PORT_CF}" "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"

    # 更新 config.json
    jq "(.inbounds[] | select(.tag == \"hy2-in\") | .listen_port) = ${PORT_HY2} |
        (.inbounds[] | select(.tag == \"vless-reality-in\") | .listen_port) = ${PORT_REALITY} |
        (.inbounds[] | select(.tag == \"vless-cf-in\") | .listen_port) = ${PORT_CF}" "$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "$CONFIG_FILE"

    # 防火墙放行
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${PORT_REALITY}/tcp" >/dev/null 2>&1
        ufw allow "${PORT_HY2}/udp" >/dev/null 2>&1
        ufw allow "${PORT_CF}/tcp" >/dev/null 2>&1
    fi

    systemctl restart sing-box
    echo -e "${GREEN}✓ 端口修改成功，sing-box 已平滑重启！${PLAIN}"
    show_info
}

renew_cert() {
    load_meta
    echo -e "\n${YELLOW}正在手动申请 / 续期 SSL 证书...${PLAIN}"
    systemctl stop sing-box 2>/dev/null || true
    certbot certonly --standalone --force-renewal --agree-tos --register-unsafely-without-email -d "$DIRECT_DOMAIN"
    if [[ "$CF_DOMAIN" != "$DIRECT_DOMAIN" ]]; then
        certbot certonly --standalone --force-renewal --agree-tos --register-unsafely-without-email -d "$CF_DOMAIN" || true
    fi
    systemctl restart sing-box
    echo -e "${GREEN}✓ 证书续签完毕！${PLAIN}"
}

toggle_bbr() {
    echo -e "\n${SKYBLUE}正在重新配置与激活 BBR 加速...${PLAIN}"
    modprobe tcp_bbr 2>/dev/null || true
    cat << 'BBREOF' > /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBREOF
    sysctl --system >/dev/null 2>&1
    local current_cc
    current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    echo -e "${GREEN}✓ BBR 配置已刷新，当前拥塞控制算法为: ${current_cc}${PLAIN}"
}

view_logs() {
    echo -e "${SKYBLUE}正在查看实时日志 (按 Ctrl+C 退出)...${PLAIN}"
    journalctl -u sing-box -f -n 30
}

uninstall_proxy() {
    read -rp "确定要彻底卸载 sing-box 代理服务吗？[y/N]: " un_c
    if [[ "$un_c" =~ ^[Yy]$ ]]; then
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /lib/systemd/system/sing-box.service
        systemctl daemon-reload
        rm -rf "$CONFIG_DIR" /var/lib/sing-box "$BIN_FILE" "$MGR_SCRIPT" "$SHORTCUT"
        echo -e "${GREEN}✓ 代理服务与管理程序已彻底清除！${PLAIN}"
        exit 0
    else
        echo -e "已取消卸载。"
    fi
}

menu() {
    while true; do
        load_meta
        echo -e "\n${SKYBLUE}==================================================================${PLAIN}"
        echo -e "${GREEN}                 sing-box 代理多功能管理面板                      ${PLAIN}"
        echo -e "${SKYBLUE}==================================================================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 查看当前节点配置与连接链接"
        echo -e "  ${GREEN}2.${PLAIN} 查看节点二维码 (手机扫码)"
        echo -e "  ${GREEN}3.${PLAIN} 修改监听端口 (Hy2 / REALITY / Cloudflare)"
        echo -e "  ${GREEN}4.${PLAIN} 查看实时运行日志"
        echo -e "  ${GREEN}5.${PLAIN} 重启 sing-box 服务"
        echo -e "  ${GREEN}6.${PLAIN} 停止 / 启动 sing-box 服务"
        echo -e "  ${GREEN}7.${PLAIN} 手动续签 SSL 证书"
        echo -e "  ${GREEN}8.${PLAIN} 检查 / 重新启用 BBR 加速"
        echo -e "  ${GREEN}9.${PLAIN} 彻底卸载服务"
        echo -e "  ${GREEN}0.${PLAIN} 退出管理菜单"
        echo -e "${SKYBLUE}==================================================================${PLAIN}"
        read -rp "请输入选项 [0-9]: " opt

        case "$opt" in
            1) show_info ;;
            2) show_qr ;;
            3) change_ports ;;
            4) view_logs ;;
            5) systemctl restart sing-box && echo -e "${GREEN}服务已重启！${PLAIN}" ;;
            6)
                if systemctl is-active --quiet sing-box; then
                    systemctl stop sing-box && echo -e "${YELLOW}服务已停止。${PLAIN}"
                else
                    systemctl start sing-box && echo -e "${GREEN}服务已启动！${PLAIN}"
                fi
                ;;
            7) renew_cert ;;
            8) toggle_bbr ;;
            9) uninstall_proxy ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入无效，请重新输入！${PLAIN}" ;;
        esac
    done
}

show_help() {
    echo -e "${SKYBLUE}==================================================================${PLAIN}"
    echo -e "${GREEN}             VPS-Proxy (sing-box) 命令行帮助指南                  ${PLAIN}"
    echo -e "${SKYBLUE}==================================================================${PLAIN}"
    echo -e "用法: ${YELLOW}sb [命令]${PLAIN} 或 ${YELLOW}vps-proxy [命令]${PLAIN}\n"
    echo -e "可用指令:"
    echo -e "  ${GREEN}(无参数)${PLAIN}       唤出可视化交互多功能管理面板"
    echo -e "  ${GREEN}h, -h, help${PLAIN}    查看本帮助信息"
    echo -e "  ${GREEN}status, info${PLAIN}   查看当前节点配置参数、运行状态及分享链接"
    echo -e "  ${GREEN}qr${PLAIN}             在终端中生成并打印节点的二维码 (手机小火箭扫码)"
    echo -e "  ${GREEN}port${PLAIN}           快捷修改监听端口 (Hy2 / REALITY / Cloudflare)"
    echo -e "  ${GREEN}log, logs${PLAIN}      查看 sing-box 实时网络连接日志"
    echo -e "  ${GREEN}restart${PLAIN}        重启 sing-box 代理服务"
    echo -e "  ${GREEN}start${PLAIN}          启动 sing-box 代理服务"
    echo -e "  ${GREEN}stop${PLAIN}           停止 sing-box 代理服务"
    echo -e "  ${GREEN}cert${PLAIN}           手动重新申请 / 续期 Let's Encrypt SSL 证书"
    echo -e "  ${GREEN}bbr${PLAIN}            检查并重新激活 Linux 原生 BBR 拥塞控制"
    echo -e "  ${GREEN}uninstall${PLAIN}      彻底卸载代理服务与相关配置"
    echo -e "${SKYBLUE}==================================================================${PLAIN}"
}

case "$1" in
    h|-h|--help|help) show_help ;;
    status|info) show_info ;;
    qr) show_qr ;;
    port) change_ports ;;
    log|logs) view_logs ;;
    restart) systemctl restart sing-box && echo -e "${GREEN}服务已重启！${PLAIN}" ;;
    stop) systemctl stop sing-box && echo -e "${YELLOW}服务已停止。${PLAIN}" ;;
    start) systemctl start sing-box && echo -e "${GREEN}服务已启动！${PLAIN}" ;;
    cert) renew_cert ;;
    bbr) toggle_bbr ;;
    uninstall) uninstall_proxy ;;
    *) menu ;;
esac
EOF
    chmod +x "$MGR_SCRIPT"
    ln -sf "$MGR_SCRIPT" "$SHORTCUT"
    echo -e "${GREEN}✓ 快捷管理命令已注册：在终端随时输入 ${YELLOW}sb${GREEN} 或 ${YELLOW}vps-proxy${GREEN} 即可唤出管理菜单！${PLAIN}"
}

# ----------------- 主流程 -----------------

main() {
    print_banner
    check_root
    install_dependencies
    enable_bbr
    input_and_verify_domains
    configure_ports
    install_singbox
    issue_certificates
    generate_config_and_service
    install_management_tool

    # 展示信息
    "$MGR_SCRIPT" info
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
