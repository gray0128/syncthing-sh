#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
BASE_DIR="/var/lib/syncthing-server"
META_FILE="/etc/syncthing-server-install.env"

SERVICE_RELAY="strelaysrv.service"
SERVICE_DISCO="stdiscosrv.service"
SERVICE_SYNCTHING="syncthing-server.service"

DEFAULT_RELAY_PORT="22067"
DEFAULT_RELAY_STATUS_PORT="22070"
DEFAULT_DISCO_PORT="8443"
DEFAULT_GUI_ADDR="0.0.0.0:8384"

COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RESET="\033[0m"

log() { echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
err() { echo -e "${COLOR_RED}[ERR ]${COLOR_RESET} $*" >&2; }

die() {
  err "$*"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 运行（例如：curl -fsSL <URL> | sudo bash -s -- install，或先下载后 sudo bash install.sh）"
  fi
}

check_ubuntu_version() {
  [[ -f /etc/os-release ]] || die "未检测到 /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "仅支持 Ubuntu，当前系统: ${ID:-unknown}"
  local version_id="${VERSION_ID:-0}"
  local major="${version_id%%.*}"
  [[ "${major}" =~ ^[0-9]+$ ]] || die "无法解析 Ubuntu 版本: ${version_id}"
  (( major >= 20 )) || die "仅支持 Ubuntu 20.04+，当前版本: ${version_id}"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

ensure_dependencies() {
  local missing=()
  for cmd in curl tar grep sed awk systemctl id getent; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log "安装依赖: ${missing[*]}"
    apt-get update -y
    apt-get install -y curl tar grep sed gawk systemd coreutils
  fi
}

detect_arch() {
  local raw_arch
  raw_arch="$(uname -m)"
  case "${raw_arch}" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "不支持的架构: ${raw_arch}（仅支持 amd64 / arm64）" ;;
  esac
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local input
  read -r -p "${prompt} [默认: ${default}]: " input < "$(stdin_for_prompt)" || true
  if [[ -z "${input}" ]]; then
    echo "${default}"
  else
    echo "${input}"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local input
  local default_hint
  if [[ "${default}" == "Y" ]]; then
    default_hint="Y/n"
  else
    default_hint="y/N"
  fi

  while true; do
    read -r -p "${prompt} [${default_hint}]: " input < "$(stdin_for_prompt)" || true
    input="${input:-$default}"
    case "${input}" in
      Y|y|yes|YES) echo "yes"; return 0 ;;
      N|n|no|NO) echo "no"; return 0 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

random_password() {
  local raw
  raw="$(tr -d '-' </proc/sys/kernel/random/uuid)$(tr -d '-' </proc/sys/kernel/random/uuid)"
  echo "${raw:0:20}"
}

stdin_for_prompt() {
  if [[ -r /dev/tty ]]; then
    echo "/dev/tty"
  else
    echo "/dev/stdin"
  fi
}

github_latest_tag() {
  local repo="$1"
  local tag
  tag="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | awk -F'"' '/"tag_name":/{print $4; exit}')"
  [[ -n "${tag}" ]] || die "无法获取 ${repo} 最新版本号"
  echo "${tag}"
}

download_and_install_binary() {
  local repo="$1"
  local binary="$2"
  local arch="$3"
  local version="$4"
  local tarball="${binary}-linux-${arch}-${version}.tar.gz"
  local url="https://github.com/${repo}/releases/download/${version}/${tarball}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir:-}"' RETURN

  log "下载 ${binary}: ${url}"
  curl -fL "${url}" -o "${tmpdir}/${tarball}"
  tar -xzf "${tmpdir}/${tarball}" -C "${tmpdir}"

  local src_bin
  src_bin="$(find "${tmpdir}" -type f -name "${binary}" | head -n 1)"
  [[ -n "${src_bin}" ]] || die "未在压缩包中找到二进制: ${binary}"

  install -m 0755 "${src_bin}" "${BIN_DIR}/${binary}"
  log "已安装 ${binary} -> ${BIN_DIR}/${binary}"
  rm -rf "${tmpdir}"
  trap - RETURN
}

create_systemd_unit_relay() {
  local run_user="$1"
  local run_group="$2"
  local workdir="$3"
  local relay_port="$4"
  local status_port="$5"
  local relay_token="$6"

  local extra_args="-pools="
  if [[ -n "${relay_token}" ]]; then
    extra_args="-token=${relay_token}"
  fi

  cat >"${SYSTEMD_DIR}/${SERVICE_RELAY}" <<EOF
[Unit]
Description=Syncthing Relay Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
Group=${run_group}
WorkingDirectory=${workdir}
ExecStart=${BIN_DIR}/strelaysrv -listen=:${relay_port} -status-srv=:${status_port} ${extra_args} -keys=${workdir}/keys
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadWritePaths=${workdir}

[Install]
WantedBy=multi-user.target
EOF
}

create_systemd_unit_disco() {
  local run_user="$1"
  local run_group="$2"
  local workdir="$3"
  local disco_port="$4"

  cat >"${SYSTEMD_DIR}/${SERVICE_DISCO}" <<EOF
[Unit]
Description=Syncthing Discovery Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
Group=${run_group}
WorkingDirectory=${workdir}
ExecStart=${BIN_DIR}/stdiscosrv --listen=:${disco_port} --db-dir=${workdir}/db
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadWritePaths=${workdir}

[Install]
WantedBy=multi-user.target
EOF
}

create_systemd_unit_syncthing() {
  local run_user="$1"
  local run_group="$2"
  local run_home="$3"
  local gui_addr="$4"

  cat >"${SYSTEMD_DIR}/${SERVICE_SYNCTHING}" <<EOF
[Unit]
Description=Syncthing Core Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
Group=${run_group}
Environment=HOME=${run_home}
Environment=STNOUPGRADE=1
WorkingDirectory=${run_home}
ExecStart=${BIN_DIR}/syncthing serve --no-browser --no-restart --no-upgrade --gui-address=${gui_addr}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadWritePaths=${run_home}/.local/state/syncthing

[Install]
WantedBy=multi-user.target
EOF
}

configure_gui_auth() {
  local run_user="$1"
  local run_home="$2"
  local gui_user="$3"
  local gui_password="$4"

  log "配置 Syncthing GUI 认证（自动哈希存储）"
  runuser -u "${run_user}" -- env HOME="${run_home}" "${BIN_DIR}/syncthing" generate \
    --gui-user="${gui_user}" \
    --gui-password="${gui_password}" \
    --no-port-probing >/dev/null
}

enable_start_service() {
  local svc="$1"
  systemctl daemon-reload
  systemctl enable "${svc}" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "${svc}"; then
    systemctl restart "${svc}"
  else
    systemctl start "${svc}"
  fi
}

open_firewall_rule() {
  local proto="$1"
  local port="$2"
  local source_cidr="$3"

  if ! command -v ufw >/dev/null 2>&1; then
    warn "未检测到 ufw，跳过防火墙开放（请自行放行端口）"
    return 0
  fi

  if [[ "${source_cidr}" == "any" ]]; then
    ufw allow "${port}/${proto}" >/dev/null || true
  else
    ufw allow from "${source_cidr}" to any port "${port}" proto "${proto}" >/dev/null || true
  fi
}

get_relay_device_id() {
  local relay_keys_dir="$1"
  local output relay_id
  output="$(
    timeout 4s "${BIN_DIR}/strelaysrv" \
      -keys="${relay_keys_dir}" \
      -listen=127.0.0.1:0 \
      -status-srv= \
      -pools= 2>&1 || true
  )"
  relay_id="$(printf '%s\n' "${output}" | sed -n 's/.*[?&]id=\([A-Z0-9-]\+\).*/\1/p' | head -n 1)"
  [[ -n "${relay_id}" ]] || return 1
  echo "${relay_id}"
}

get_disco_device_id() {
  local cert_file="$1"
  local key_file="$2"
  local db_dir="$3"
  local output disco_id
  mkdir -p "${db_dir}"
  output="$(
    timeout 4s "${BIN_DIR}/stdiscosrv" \
      --cert="${cert_file}" \
      --key="${key_file}" \
      --db-dir="${db_dir}" \
      --listen=127.0.0.1:0 2>&1 || true
  )"
  disco_id="$(printf '%s\n' "${output}" | sed -n 's/.*deviceId=\([A-Z0-9-]\+\).*/\1/p' | head -n 1)"
  [[ -n "${disco_id}" ]] || return 1
  echo "${disco_id}"
}

is_tcp_port_listening() {
  local port="$1"
  ss -lnt | awk '{print $4}' | grep -qE "(^|.*:|\])${port}$"
}

print_service_debug_info() {
  echo
  warn "当前监听端口："
  ss -lntp || true
  echo
  warn "最近的 relay 日志："
  journalctl -u "${SERVICE_RELAY}" -n 40 --no-pager || true
  echo
  warn "最近的 discovery 日志："
  journalctl -u "${SERVICE_DISCO}" -n 40 --no-pager || true
}

assert_service_configuration() {
  local relay_port="$1"
  local relay_status_port="$2"
  local relay_token="$3"
  local disco_port="$4"

  systemctl is-active --quiet "${SERVICE_RELAY}" || die "${SERVICE_RELAY} 未运行"
  systemctl is-active --quiet "${SERVICE_DISCO}" || die "${SERVICE_DISCO} 未运行"

  local relay_exec disco_exec
  relay_exec="$(systemctl show -p ExecStart "${SERVICE_RELAY}" | sed 's/^ExecStart=//')"
  disco_exec="$(systemctl show -p ExecStart "${SERVICE_DISCO}" | sed 's/^ExecStart=//')"

  [[ "${relay_exec}" == *"-listen=:${relay_port}"* ]] || die "强校验失败：relay 监听端口未生效（期望 ${relay_port}）"
  [[ "${relay_exec}" == *"-status-srv=:${relay_status_port}"* ]] || die "强校验失败：relay 状态端口未生效（期望 ${relay_status_port}）"
  [[ "${disco_exec}" == *"--listen=:${disco_port}"* ]] || die "强校验失败：discovery 端口未生效（期望 ${disco_port}）"
  if [[ -n "${relay_token}" ]]; then
    [[ "${relay_exec}" == *"-token=${relay_token}"* ]] || die "强校验失败：relay token 未生效"
  fi

  local _try
  for _try in 1 2 3 4 5; do
    if is_tcp_port_listening "${relay_port}" && is_tcp_port_listening "${disco_port}"; then
      return 0
    fi
    sleep 1
  done

  print_service_debug_info
  is_tcp_port_listening "${relay_port}" || die "强校验失败：relay 端口 ${relay_port} 未监听"
  is_tcp_port_listening "${disco_port}" || die "强校验失败：discovery 端口 ${disco_port} 未监听"
}

print_client_config() {
  [[ -f "${META_FILE}" ]] || die "未找到安装元数据，请先执行 install"
  # shellcheck disable=SC1090
  source "${META_FILE}"

  local relay_port="${RELAY_PORT:-}"
  local disco_port="${DISCO_PORT:-}"
  local relay_token="${RELAY_TOKEN:-}"
  local public_host="${PUBLIC_HOST:-}"
  local include_default="${INCLUDE_DEFAULT_DISCOVERY:-yes}"

  [[ -n "${relay_port}" && -n "${disco_port}" ]] || die "元数据不完整（缺少端口信息）"
  [[ -n "${public_host}" ]] || public_host="<your-domain>"

  local relay_id disco_id
  relay_id="$(get_relay_device_id "${BASE_DIR}/relay/keys" || true)"
  disco_id="$(get_disco_device_id "${BASE_DIR}/discovery/cert.pem" "${BASE_DIR}/discovery/key.pem" "${BASE_DIR}/discovery/db" || true)"
  [[ -n "${relay_id}" ]] || die "无法获取 relay device ID，请检查 ${SERVICE_RELAY} 与 keys 目录"
  [[ -n "${disco_id}" ]] || die "无法获取 discovery device ID，请检查 ${SERVICE_DISCO} 与证书目录"

  local relay_url="relay://${public_host}:${relay_port}/?id=${relay_id}"
  if [[ -n "${relay_token}" ]]; then
    relay_url="${relay_url}&token=${relay_token}"
  fi
  local listen_addrs="tcp://0.0.0.0:22000,quic://0.0.0.0:22000,${relay_url}"
  local discovery_url="https://${public_host}:${disco_port}/?id=${disco_id}"
  local discovery_line="${discovery_url}"
  if [[ "${include_default}" == "yes" ]]; then
    discovery_line="default, ${discovery_url}"
  fi

  cat <<EOF

================= 客户端配置（自签名证书） =================
同步协议监听地址:
${listen_addrs}

全局发现服务器:
${discovery_line}
============================================================
EOF
}

install_flow() {
  check_ubuntu_version
  ensure_dependencies
  need_cmd systemctl
  need_cmd curl
  need_cmd tar

  local arch
  arch="$(detect_arch)"
  log "检测到架构: ${arch}"
  if [[ ! -r /dev/tty ]]; then
    warn "未检测到可交互终端，将使用默认值执行安装。"
  fi

  local default_user="${SUDO_USER:-$(id -un)}"
  local run_user
  run_user="$(prompt_default "请输入服务运行用户（必须是现有用户）" "${default_user}")"
  id "${run_user}" >/dev/null 2>&1 || die "用户不存在: ${run_user}"
  local run_group
  run_group="$(id -gn "${run_user}")"
  local run_home
  run_home="$(getent passwd "${run_user}" | cut -d: -f6)"
  [[ -d "${run_home}" ]] || die "无法识别用户家目录: ${run_home}"

  local relay_port disco_port relay_status_port gui_addr
  relay_port="$(prompt_default "中继服务端口 (strelaysrv -listen)" "${DEFAULT_RELAY_PORT}")"
  relay_status_port="$(prompt_default "中继状态端口 (strelaysrv -status-srv)" "${DEFAULT_RELAY_STATUS_PORT}")"
  disco_port="$(prompt_default "发现服务端口 (stdiscosrv --listen)" "${DEFAULT_DISCO_PORT}")"
  gui_addr="$(prompt_default "Syncthing GUI 监听地址" "${DEFAULT_GUI_ADDR}")"

  local relay_token_default relay_token
  relay_token_default="$(random_password)"
  relay_token="$(prompt_default "中继访问 Token（默认自动生成；输入 none 可禁用）" "${relay_token_default}")"
  if [[ "${relay_token}" == "none" ]]; then
    relay_token=""
  fi
  [[ "${relay_token}" =~ [[:space:]] ]] && die "Token 不能包含空白字符"

  local enable_syncthing
  enable_syncthing="$(prompt_yes_no "是否部署 syncthing 核心服务（含 GUI）?" "N")"

  local source_cidr
  source_cidr="$(prompt_default "防火墙允许来源 CIDR（any 表示全网）" "any")"
  local public_host
  public_host="$(prompt_default "客户端访问本服务使用的公网域名（或IP）" "arm1-osaka.bobocai.win")"
  local include_default_discovery
  include_default_discovery="$(prompt_yes_no "全局发现服务器是否保留 default?" "Y")"

  local syncthing_tag relaysrv_tag discosrv_tag
  syncthing_tag="$(github_latest_tag "syncthing/syncthing")"
  relaysrv_tag="$(github_latest_tag "syncthing/relaysrv")"
  discosrv_tag="$(github_latest_tag "syncthing/discosrv")"

  log "版本将使用: syncthing=${syncthing_tag}, relaysrv=${relaysrv_tag}, discosrv=${discosrv_tag}"

  mkdir -p "${BASE_DIR}/relay/keys" "${BASE_DIR}/discovery/db"
  chown -R "${run_user}:${run_group}" "${BASE_DIR}"

  download_and_install_binary "syncthing/relaysrv" "strelaysrv" "${arch}" "${relaysrv_tag}"
  download_and_install_binary "syncthing/discosrv" "stdiscosrv" "${arch}" "${discosrv_tag}"

  create_systemd_unit_relay "${run_user}" "${run_group}" "${BASE_DIR}/relay" "${relay_port}" "${relay_status_port}" "${relay_token}"
  create_systemd_unit_disco "${run_user}" "${run_group}" "${BASE_DIR}/discovery" "${disco_port}"

  enable_start_service "${SERVICE_RELAY}"
  enable_start_service "${SERVICE_DISCO}"

  # 服务端常用端口（按你的要求）
  open_firewall_rule "tcp" "22000" "${source_cidr}"
  open_firewall_rule "udp" "22000" "${source_cidr}"
  open_firewall_rule "udp" "21027" "${source_cidr}"
  # 中继/发现端口
  open_firewall_rule "tcp" "${relay_port}" "${source_cidr}"
  open_firewall_rule "tcp" "${relay_status_port}" "${source_cidr}"
  open_firewall_rule "tcp" "${disco_port}" "${source_cidr}"

  local gui_user="" gui_password=""
  if [[ "${enable_syncthing}" == "yes" ]]; then
    download_and_install_binary "syncthing/syncthing" "syncthing" "${arch}" "${syncthing_tag}"

    gui_user="$(prompt_default "GUI 管理员用户名" "admin")"
    read -r -s -p "GUI 管理员密码（留空自动生成）: " gui_password < "$(stdin_for_prompt)" || true
    echo
    if [[ -z "${gui_password}" ]]; then
      gui_password="$(random_password)"
      warn "已自动生成 GUI 密码: ${gui_password}"
    fi

    configure_gui_auth "${run_user}" "${run_home}" "${gui_user}" "${gui_password}"
    create_systemd_unit_syncthing "${run_user}" "${run_group}" "${run_home}" "${gui_addr}"
    enable_start_service "${SERVICE_SYNCTHING}"

    local gui_port="${gui_addr##*:}"
    if [[ "${gui_port}" =~ ^[0-9]+$ ]]; then
      open_firewall_rule "tcp" "${gui_port}" "${source_cidr}"
    fi
  fi

  assert_service_configuration "${relay_port}" "${relay_status_port}" "${relay_token}" "${disco_port}"

  cat >"${META_FILE}" <<EOF
RUN_USER=${run_user}
RUN_HOME=${run_home}
ENABLE_SYNCTHING=${enable_syncthing}
RELAY_PORT=${relay_port}
RELAY_STATUS_PORT=${relay_status_port}
DISCO_PORT=${disco_port}
RELAY_TOKEN=${relay_token}
PUBLIC_HOST=${public_host}
INCLUDE_DEFAULT_DISCOVERY=${include_default_discovery}
EOF
  chmod 0600 "${META_FILE}"

  log "安装完成。服务状态："
  log "当前生效 ExecStart："
  systemctl show -p ExecStart "${SERVICE_RELAY}" | sed 's/^ExecStart=//'
  systemctl show -p ExecStart "${SERVICE_DISCO}" | sed 's/^ExecStart=//'
  if [[ "${enable_syncthing}" == "yes" ]]; then
    systemctl show -p ExecStart "${SERVICE_SYNCTHING}" | sed 's/^ExecStart=//'
  fi
  systemctl --no-pager --full status "${SERVICE_RELAY}" | sed -n '1,8p' || true
  systemctl --no-pager --full status "${SERVICE_DISCO}" | sed -n '1,8p' || true
  if [[ "${enable_syncthing}" == "yes" ]]; then
    systemctl --no-pager --full status "${SERVICE_SYNCTHING}" | sed -n '1,8p' || true
  fi

  cat <<EOF

========================================================
部署完成（Ubuntu 20.04+ / ${arch}）
--------------------------------------------------------
中继服务:    ${SERVICE_RELAY} (端口 ${relay_port}/tcp)
中继状态:    端口 ${relay_status_port}/tcp
发现服务:    ${SERVICE_DISCO} (端口 ${disco_port}/tcp)
防火墙来源:  ${source_cidr}
私有中继:    $( [[ -n "${relay_token}" ]] && echo "已启用 Token" || echo "未启用 Token（建议启用）" )
--------------------------------------------------------
EOF
  if [[ "${enable_syncthing}" == "yes" ]]; then
    cat <<EOF
Syncthing GUI: ${gui_addr}
GUI 用户名:   ${gui_user}
GUI 密码:     ${gui_password}
自动升级:     已关闭（--no-upgrade + STNOUPGRADE=1）
EOF
  else
    cat <<EOF
Syncthing 核心服务: 未部署（仅中继 + 发现）
EOF
  fi

  cat <<'EOF'
--------------------------------------------------------
卸载命令:
  sudo bash install.sh uninstall
========================================================
EOF

  print_client_config
}

disable_stop_if_exists() {
  local svc="$1"
  if systemctl list-unit-files | grep -q "^${svc}"; then
    systemctl disable --now "${svc}" >/dev/null 2>&1 || true
  fi
}

uninstall_flow() {
  require_root
  local remove_all
  remove_all="$(prompt_yes_no "是否执行完整卸载（删除配置和数据）?" "N")"

  disable_stop_if_exists "${SERVICE_SYNCTHING}"
  disable_stop_if_exists "${SERVICE_DISCO}"
  disable_stop_if_exists "${SERVICE_RELAY}"

  rm -f \
    "${SYSTEMD_DIR}/${SERVICE_SYNCTHING}" \
    "${SYSTEMD_DIR}/${SERVICE_DISCO}" \
    "${SYSTEMD_DIR}/${SERVICE_RELAY}"

  rm -f \
    "${BIN_DIR}/syncthing" \
    "${BIN_DIR}/stdiscosrv" \
    "${BIN_DIR}/strelaysrv"

  systemctl daemon-reload

  if [[ "${remove_all}" == "yes" ]]; then
    rm -rf "${BASE_DIR}"
    warn "已删除 ${BASE_DIR}"

    # 尝试删除可能存在的 Syncthing 默认状态目录（不强行失败）
    local candidate_homes=()
    if [[ -f "${META_FILE}" ]]; then
      # shellcheck disable=SC1090
      source "${META_FILE}" || true
      if [[ -n "${RUN_HOME:-}" ]]; then
        candidate_homes+=("${RUN_HOME}")
      fi
    fi
    if [[ -n "${SUDO_USER:-}" ]] && getent passwd "${SUDO_USER}" >/dev/null 2>&1; then
      candidate_homes+=("$(getent passwd "${SUDO_USER}" | cut -d: -f6)")
    fi
    candidate_homes+=("/root")
    for h in "${candidate_homes[@]}"; do
      [[ -n "${h}" ]] || continue
      rm -rf "${h}/.local/state/syncthing" 2>/dev/null || true
    done
  else
    log "已保留配置与数据目录: ${BASE_DIR}"
  fi

  rm -f "${META_FILE}"

  log "卸载完成。"
}

main() {
  require_root
  local mode="${1:-}"

  if [[ -z "${mode}" ]]; then
    cat <<'EOF'
请选择操作:
  1) install 安装/更新
  2) uninstall 卸载
  3) show-client-config 打印客户端配置
EOF
    local pick
    pick="$(prompt_default "请输入序号" "1")"
    case "${pick}" in
      1) mode="install" ;;
      2) mode="uninstall" ;;
      3) mode="show-client-config" ;;
      *) die "无效序号: ${pick}" ;;
    esac
  fi

  case "${mode}" in
    install) install_flow ;;
    uninstall) uninstall_flow ;;
    show-client-config) print_client_config ;;
    -h|--help|help)
      cat <<EOF
用法:
  sudo bash ${SCRIPT_NAME} install
  sudo bash ${SCRIPT_NAME} uninstall
  sudo bash ${SCRIPT_NAME} show-client-config

说明:
  - 适配 Ubuntu 20.04+
  - 适配 amd64 / arm64
  - 默认部署 strelaysrv + stdiscosrv
  - 可选部署 syncthing（含 GUI 认证）
  - install 结束后执行强校验
EOF
      ;;
    *)
      die "未知模式: ${mode}（可用: install / uninstall）"
      ;;
  esac
}

main "${1:-}"
