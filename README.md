# syncthing-sh

Ubuntu 20.04+ 一键部署 Syncthing 服务端脚本（`amd64` / `arm64`）。

默认部署：
- `strelaysrv`（私有中继，默认不加入公共池）
- `stdiscosrv`（私有发现服务）

可选部署：
- `syncthing` 核心服务（含 Web GUI，默认 **不部署**）

脚本特性：
- 交互式输入，尽量提供默认值
- 从 GitHub Release 拉取官方二进制
- 非 root 运行服务
- systemd 沙箱加固
- 自动升级关闭（`--no-upgrade` + `STNOUPGRADE=1`）
- 自动配置防火墙端口（检测到 `ufw` 时）
- 支持卸载（默认保留数据，可选完整删除）

## 快速开始

### 在线安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/gray0128/syncthing-sh/main/install.sh | sudo bash -s -- install
```

### 在线卸载

```bash
curl -fsSL https://raw.githubusercontent.com/gray0128/syncthing-sh/main/install.sh | sudo bash -s -- uninstall
```

### 下载后执行（最稳妥）

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/gray0128/syncthing-sh/main/install.sh
sudo bash install.sh install
```

## 交互项说明

- 服务运行用户：要求是现有用户
- 中继端口：默认 `22067`
- 中继状态端口：默认 `22070`
- 发现服务端口：默认 `8443`
- Syncthing GUI 监听：默认 `0.0.0.0:8384`（仅在启用核心服务时生效）
- 中继 Token：可选，建议启用
- 是否部署 syncthing 核心服务：默认 `N`
- 防火墙来源 CIDR：默认 `any`

## 防火墙端口

脚本会尝试放行：
- `22000/tcp`
- `22000/udp`
- `21027/udp`
- 中继端口（默认 `22067/tcp`）
- 中继状态端口（默认 `22070/tcp`）
- 发现服务端口（默认 `8443/tcp`）
- GUI 端口（仅启用核心服务且地址可解析端口时）

> 如果机器未安装 `ufw`，脚本会跳过防火墙配置并给出提示。

## 安全建议

- 生产环境请将防火墙来源从 `any` 改为可信网段
- 中继建议启用 `Token`，避免被任意客户端滥用
- 如启用 GUI，务必使用强密码并建议结合反向代理与 HTTPS
- 定期备份 `/var/lib/syncthing-server` 及相关配置目录

## 卸载策略

- 默认：仅移除服务和二进制，保留数据
- 可选：完整删除（包括脚本记录的服务端数据与状态目录）

## 免责声明

该脚本面向 Ubuntu 20.04+，并以官方发布资源为基础实现。请先在测试环境验证，再用于生产环境。
