# VPS-Proxy (海外 VPS 极速代理一键部署与管理脚本)

[![sing-box](https://img.shields.io/badge/core-sing--box-blue)](https://github.com/SagerNet/sing-box)
[![BBR](https://img.shields.io/badge/network-BBR%20Accelerated-green)](#)
[![License](https://img.shields.io/badge/license-MIT-purple)](#)

海外 VPS 极速三合一代理全自动部署与管理脚本。原生启用 Linux 内核 BBR + FQ 拥塞控制算法，自动申请并续期 Let's Encrypt 官方 SSL 证书，一次性部署三大经典梯队协议：**Hysteria 2（极速主力） + VLESS-REALITY（隐蔽抗封） + Cloudflare CDN（终极兜底）**。

---

## 🌟 核心特性

- **三层冗余梯队架构**：
  1. 🏎️ **Hysteria 2 (UDP 8443)**：基于 QUIC 协议，极速低延迟，对抗网络抖动与丢包，看 4K/8K 视频首选。
  2. 🛡️ **VLESS + REALITY (TCP 443)**：伪装为苹果官方网关（`gateway.icloud.com`），无证书指纹特征，隐蔽抗探测。
  3. ☁️ **VLESS + WS + TLS (TCP 2053)**：配合 Cloudflare CDN（橙色小云朵），真实 VPS IP 彻底隐藏在 Anycast 边缘网络后，终极防封。
- **DNS 解析强校验**：交互输入域名时自动查询全球与本机 DNS，若域名解析 IP 与 VPS 不匹配会发出醒目拦截警告，避免后续证书申请报错。
- **全自动 BBR 拥塞控制加速**：自动加载 `tcp_bbr` 内核模块并设置 `fq` 队列，跑满服务器峰值带宽。
- **官方 SSL 证书自动续期**：集成 Let's Encrypt Certbot 自动静默申请与续期。
- **多功能命令行管理面板**：随时输入 `sb` 或 `vps-proxy` 即可唤出管理面板，支持**查询节点**、**显示二维码**、**在线修改端口**、**实时日志**、**证书续签**等。

---

## 🚀 一键部署

在任意全新的海外 VPS（推荐系统：Ubuntu 20.04/22.04/24.04、Debian 11/12）上，以 `root` 用户执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/callac/vps-proxy/main/install.sh)
```

或使用 `wget`：

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/callac/vps-proxy/main/install.sh && bash install.sh
```

---

## ⚙️ 部署交互说明

执行脚本后，只需跟随向导输入以下参数：

1. **直连域名 (Direct Domain)**：
   - 例如：`direct.example.com`
   - *用途*：用于 Hysteria 2 节点，必须提前解析到本 VPS 的公网 IP。脚本会自动检测解析，校验一致后才会继续。
2. **Cloudflare 域名 (CF Domain)**：
   - 例如：`cf.example.com`
   - *用途*：在 Cloudflare DNS 中开启了**橙色小云朵 (Proxied / 已代理)** 的子域名，用于 CDN 兜底节点。直接回车则默认使用直连域名的配置。
3. **端口自定义**：
   - Hysteria 2 端口（默认 `8443`）
   - VLESS-REALITY 端口（默认 `443`）
   - Cloudflare CDN 端口（默认 `2053`，支持 2053、8443、2083、2087、2096 等 CF 兼容端口）

---

## 🛠️ 管理与日常维护

部署完成后，在 VPS 终端的任意位置随时运行以下快捷命令：

```bash
sb
```
或：
```bash
vps-proxy
```

### 交互菜单功能：
```text
==================================================================
                 sing-box 代理多功能管理面板                      
==================================================================
  1. 查看当前节点配置与连接链接
  2. 查看节点二维码 (手机扫码)
  3. 修改监听端口 (Hy2 / REALITY / Cloudflare)
  4. 查看实时运行日志
  5. 重启 sing-box 服务
  6. 停止 / 启动 sing-box 服务
  7. 手动续签 SSL 证书
  8. 检查 / 重新启用 BBR 加速
  9. 彻底卸载服务
  0. 退出管理菜单
==================================================================
```

### 快捷子命令：
- `sb info` 或 `sb status`：直接查看当前所有节点的详细连接参数与标准导入链接。
- `sb qr`：在终端直接打印小火箭扫码专用的二维码。
- `sb port`：快捷修改服务端口并自动重载防火墙与服务。
- `sb log`：查看 sing-box 实时网络连接日志。
- `sb restart`：重启代理服务。

---

## 📱 客户端配置与导入

### 1. OpenWrt (PassWall)
- 进入 **【服务】 ➔ 【PassWall】 ➔ 【节点列表】**。
- 将终端输出的 `hysteria2://...` 或 `vless://...` 复制到页面底部的**【从节点链接导入】**中，点击导入即可。

### 2. 手机端 (Shadowrocket / 小火箭)
- 在 VPS 上运行 `sb qr`，选择对应节点，使用小火箭扫描终端打印的二维码即可完成配置。

---

## 📄 开源许可

本项目遵循 [MIT License](LICENSE)。
