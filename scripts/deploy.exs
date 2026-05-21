#!/usr/bin/env elixir
# scripts/deploy.exs — 部署 auth2api_ex 到 VPS / Google Cloud VM
#
# 用法:
#   elixir scripts/deploy.exs                              # 完整部署
#   elixir scripts/deploy.exs --rollback                   # 回滚到上一版本
#   elixir scripts/deploy.exs --config scripts/deploy.toml # 指定配置文件
#
# 首次部署前(可选):
#   cp .env.prod.example .env.prod  # 如有需要,填入 AUTH2API_CONFIG 等环境变量
#
# 重要:
#   - ~/.auth2api_ex/ 目录(OAuth token + accounts)永久保留,部署不会清理。
#   - 历史版本仅保留 1 个;连续 --rollback 两次会报错。
#   - 启用 [caddy] 时会自动安装 Caddy 反代 + 自动签发 Let's Encrypt 证书。

Mix.install([{:toml, "~> 0.7"}, {:jason, "~> 1.4"}])

defmodule Deploy do
  @doc "运行 shell 命令,流式输出,失败则退出"
  def run!(desc, cmd) do
    IO.puts("\n▶ #{desc}")

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true, into: IO.stream(:stdio, :line)) do
      {_, 0} ->
        :ok

      {_, code} ->
        IO.puts("\n❌ 命令失败(退出码 #{code})")
        System.halt(1)
    end
  end

  @doc "上传本地文件到目标主机"
  def scp!(src, remote_dst, %{target: :ssh} = ctx) do
    %{ssh: ssh} = ctx
    key_part = if ssh.key && ssh.key != "", do: "-i #{ssh.key} ", else: ""
    port_part = "-P #{ssh.port} "

    run!(
      "[上传] #{Path.basename(src)} → #{ssh.user}@#{ssh.host}:#{remote_dst}",
      "scp #{port_part}#{key_part}#{src} #{ssh.user}@#{ssh.host}:#{remote_dst}"
    )
  end

  def scp!(src, remote_dst, %{target: :gcloud} = ctx) do
    %{gcloud: %{instance: inst, zone: zone, project: proj}} = ctx

    run!(
      "[上传] #{Path.basename(src)} → VM:#{remote_dst}",
      "gcloud compute scp #{src} #{inst}:#{remote_dst} --zone=#{zone} --project=#{proj}"
    )
  end

  @doc "把 bash 脚本写成临时文件 SCP 过去再执行,避免转义问题"
  def ssh!(desc, script, ctx) do
    tmp_local =
      Path.join(System.tmp_dir!(), "auth2api_ex-deploy-#{System.unique_integer([:positive])}.sh")

    tmp_remote = "/tmp/auth2api_ex-deploy-remote.sh"
    File.write!(tmp_local, script)
    scp!(tmp_local, tmp_remote, ctx)
    File.rm!(tmp_local)

    case ctx.target do
      :ssh ->
        %{ssh: ssh} = ctx
        key_part = if ssh.key && ssh.key != "", do: "-i #{ssh.key} ", else: ""
        port_part = "-p #{ssh.port} "

        run!(
          desc,
          "ssh #{port_part}#{key_part}#{ssh.user}@#{ssh.host} " <>
            "\"bash #{tmp_remote}; CODE=\\$?; rm -f #{tmp_remote}; exit \\$CODE\""
        )

      :gcloud ->
        %{gcloud: %{instance: inst, zone: zone, project: proj}} = ctx

        run!(
          desc,
          "gcloud compute ssh #{inst} --zone=#{zone} --project=#{proj}" <>
            " --command='bash #{tmp_remote}; CODE=$?; rm -f #{tmp_remote}; exit $CODE'"
        )
    end
  end
end

# ── 参数解析 ─────────────────────────────────────────────────────────────────
args = System.argv()
rollback = "--rollback" in args
force_config = "--force-config" in args

config_idx = Enum.find_index(args, &(&1 == "--config"))

toml_path =
  if config_idx do
    args |> Enum.at(config_idx + 1) |> Path.expand()
  else
    Path.join(__DIR__, "deploy.toml")
  end

# ── 加载配置 ──────────────────────────────────────────────────────────────────
root = __DIR__ |> Path.join("..") |> Path.expand()

unless File.exists?(toml_path) do
  IO.puts("❌ 找不到配置文件:#{toml_path}")
  System.halt(1)
end

cfg = toml_path |> File.read!() |> Toml.decode!()

target = (cfg["deploy"] || %{})["target"] || "ssh"

ctx =
  case target do
    "ssh" ->
      ssh = cfg["ssh"] || %{}

      %{
        target: :ssh,
        ssh: %{
          host: ssh["host"],
          port: ssh["port"] || 22,
          user: ssh["user"] || "root",
          key: ssh["key"] || ""
        }
      }

    "gcloud" ->
      g = cfg["gcloud"] || %{}

      %{
        target: :gcloud,
        gcloud: %{
          project: g["project"],
          zone: g["zone"],
          instance: g["instance"]
        }
      }

    other ->
      IO.puts("❌ 不支持的 deploy.target:#{inspect(other)}(只支持 \"ssh\" / \"gcloud\")")
      System.halt(1)
  end

app = cfg["app"] || %{}
svc = cfg["systemd"] || %{}
caddy = cfg["caddy"] || %{}

app_name = app["name"] || "auth2api_ex"
release_name = app["release"] || app_name
deploy_dir = app["deploy_dir"] || "/opt/#{app_name}"
env_local = Path.join(root, app["env_file"] || ".env.prod")
service_name = svc["service"] || "#{app_name}.service"

env_local_exists? = File.exists?(env_local)

caddy_enabled? = Map.get(caddy, "enabled", false) == true

IO.puts("""
🚀 auth2api_ex 部署
   target:     #{target}
   app:        #{app_name}
   deploy_dir: #{deploy_dir}
   service:    #{service_name}
   caddy:      #{if caddy_enabled?, do: "enabled (#{caddy["domain"]})", else: "disabled"}
   env file:   #{if env_local_exists?, do: env_local, else: "(无,使用默认环境变量)"}
   rollback:   #{rollback}
""")

# ── SSH 连接预检（提前发现密钥错误/网络问题）─────────────────────────────────
case ctx.target do
  :ssh ->
    %{ssh: ssh} = ctx
    key_part = if ssh.key && ssh.key != "", do: "-i #{ssh.key} ", else: ""
    port_part = "-p #{ssh.port} "

    Deploy.run!(
      "[验证] SSH 连接 → #{ssh.user}@#{ssh.host}:#{ssh.port}",
      "ssh -o ConnectTimeout=10 -o BatchMode=yes #{port_part}#{key_part}#{ssh.user}@#{ssh.host} \"echo 'SSH OK'\""
    )

  :gcloud ->
    %{gcloud: %{instance: inst, zone: zone, project: proj}} = ctx

    Deploy.run!(
      "[验证] SSH 连接 → #{inst}",
      "gcloud compute ssh #{inst} --zone=#{zone} --project=#{proj} --command=\"echo 'SSH OK'\""
    )
end

# ── 回滚分支 ─────────────────────────────────────────────────────────────────
if rollback do
  confirm =
    IO.gets("继续回滚?输入 yes 确认:")
    |> to_string()
    |> String.trim()

  unless confirm == "yes" do
    IO.puts("已取消回滚。")
    System.halt(1)
  end

  rollback_script = """
  #!/usr/bin/env bash
  set -euo pipefail

  if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

  DEPLOY_DIR="#{deploy_dir}"
  SERVICE_NAME="#{service_name}"
  PREVIOUS_DIR="${DEPLOY_DIR}/previous"

  if [ ! -d "${PREVIOUS_DIR}/bin" ] || [ ! -d "${PREVIOUS_DIR}/lib" ] || [ ! -d "${PREVIOUS_DIR}/releases" ]; then
    echo "❌ ${PREVIOUS_DIR} 不存在或不完整,无法回滚(仅保留 1 个历史版本)"
    exit 1
  fi

  echo "▶ 停止服务..."
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    $SUDO systemctl stop "${SERVICE_NAME}"
    sleep 2
  fi

  echo "▶ 交换 current ↔ previous..."
  ASIDE_DIR="${DEPLOY_DIR}/.rollback-aside"
  $SUDO rm -rf "${ASIDE_DIR}"
  $SUDO mkdir -p "${ASIDE_DIR}"

  for item in bin lib releases; do
    if [ -e "${DEPLOY_DIR}/${item}" ]; then
      $SUDO mv "${DEPLOY_DIR}/${item}" "${ASIDE_DIR}/${item}"
    fi
  done
  for ertsdir in "${DEPLOY_DIR}"/erts-*; do
    [ -e "${ertsdir}" ] && $SUDO mv "${ertsdir}" "${ASIDE_DIR}/"
  done

  for item in bin lib releases; do
    if [ -e "${PREVIOUS_DIR}/${item}" ]; then
      $SUDO mv "${PREVIOUS_DIR}/${item}" "${DEPLOY_DIR}/${item}"
    fi
  done
  for ertsdir in "${PREVIOUS_DIR}"/erts-*; do
    [ -e "${ertsdir}" ] && $SUDO mv "${ertsdir}" "${DEPLOY_DIR}/"
  done

  $SUDO rm -rf "${ASIDE_DIR}" "${PREVIOUS_DIR}"

  echo "▶ 启动服务..."
  $SUDO systemctl start "${SERVICE_NAME}"

  echo ""
  echo "✅ 回滚完成"
  echo "  状态: sudo systemctl status ${SERVICE_NAME}"
  echo "  日志: sudo journalctl -u ${SERVICE_NAME} -f"
  """

  Deploy.ssh!("[远端] 回滚中...", rollback_script, ctx)
  IO.puts("\n🎉 回滚流程结束")
  System.halt(0)
end

# ── 本地构建 ─────────────────────────────────────────────────────────────────
File.cd!(root)

# Write build-time version info
git_commit =
  case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
    {output, 0} -> String.trim(output)
    _ -> "unknown"
  end

build_time =
  case System.cmd("date", ["-u", "+%Y-%m-%dT%H:%M:%SZ"], stderr_to_stdout: true) do
    {output, 0} -> String.trim(output)
    _ -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

app_version =
  case Regex.run(~r/version:\s*"([^"]+)"/, File.read!(Path.join(root, "mix.exs"))) do
    [_, version] -> version
    _ -> "unknown"
  end

version_json =
  %{
    app: app_name,
    version: app_version,
    git_commit: git_commit,
    build_time: build_time
  }
  |> Jason.encode!()

version_path = Path.join(root, "priv/version.json")
File.mkdir_p!(Path.dirname(version_path))
File.write!(version_path, version_json)

IO.puts("  version.json → #{git_commit} @ #{build_time}")

# 根据操作系统类型决定构建方式
case :os.type() do
  {:unix, :darwin} ->
    IO.puts("🍎 macOS 检测，使用 Docker 持久容器进行 Linux 交叉编译...")

    container_name = "auth2api-builder"
    image = "docker.io/library/elixir:1.19.5-otp-28-slim"

    # 检查持久容器是否已存在
    container_exists? =
      case System.cmd("docker", ["container", "inspect", container_name],
             stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end

    if not container_exists? do
      # ── 首次：创建持久容器，挂载项目目录，安装编译工具链 ──────────
      IO.puts("  [首次] 创建持久编译容器（后续部署直接复用，无需重建镜像）")

      Deploy.run!("[Docker] 创建容器（挂载项目目录）",
        "docker create --name #{container_name} " <>
          "--platform linux/amd64 " <>
          "-v #{root}:/app -w /app -e MIX_ENV=prod " <>
          "-e ERL_FLAGS=\"+JMsingle true\" " <>
          "-e ELIXIR_ERL_OPTIONS=\"+JMsingle true\" " <>
          "#{image} tail -f /dev/null")

      Deploy.run!("[Docker] 启动容器", "docker start #{container_name}")

      Deploy.run!("[Docker] 安装编译工具链（仅首次）",
        "docker exec #{container_name} bash -c '" <>
          "apt-get update -qq && apt-get install -y -qq build-essential git curl " <>
          "&& apt-get clean && rm -rf /var/lib/apt/lists/*'")

      Deploy.run!("[Docker] 安装 hex + rebar（仅首次）",
        "docker exec -e ERL_FLAGS=\"+JMsingle true\" #{container_name} bash -c '" <>
          "mix local.hex --force && mix local.rebar --force'")
    else
      # ── 复用已有容器 ────────────────────────────────────────────
      running? =
        case System.cmd("docker", ["inspect", "-f", "{{.State.Running}}", container_name],
               stderr_to_stdout: true) do
          {output, 0} -> String.trim(output) == "true"
          _ -> false
        end

      if running? do
        IO.puts("  [复用] 持久编译容器已运行")
      else
        Deploy.run!("[Docker] 启动容器", "docker start #{container_name}")
      end
    end

    # ── 增量编译（_build/ 落在宿主机，Elixir 只编译改动文件）─────────
    Deploy.run!("[Docker] 同步依赖",
      "docker exec -e ERL_FLAGS=\"+JMsingle true\" #{container_name} mix deps.get --only prod")

    Deploy.run!("[Docker] 清理旧 release", "rm -rf _build/prod/rel")

    # ── 清除 stale NIF .so 和 C 编译产物，强制 Docker 重新编译 ──
    # 宿主机 macOS arm64 残留的 .o/.a/.so 在 Linux x86_64 容器里链接会报 "file format not recognized"
    Deploy.run!("[Docker] 清除 C/NIF 编译缓存（防止跨架构残留）",
      "rm -rf _build/prod/lib/ezstd-* _build/deps/zstd 2>/dev/null; " <>
      "rm -f deps/ezstd/c_src/*.o 2>/dev/null; true")

    Deploy.run!("[Docker] 增量编译",
      "docker exec -e ERL_FLAGS=\"+JMsingle true\" #{container_name} mix compile")

    Deploy.run!("[Docker] 构建 release",
      "docker exec -e ERL_FLAGS=\"+JMsingle true\" #{container_name} mix release --overwrite")

    # 产物已在宿主机 _build/prod/rel/ 下，无需 docker cp

  _ ->
    Deploy.run!("[本地] 清理旧 release", "rm -rf _build/prod/rel")
    Deploy.run!("[本地] 获取依赖", "MIX_ENV=prod mix deps.get --only prod")
    Deploy.run!("[本地] 编译", "MIX_ENV=prod mix compile")
    Deploy.run!("[本地] 构建 release", "MIX_ENV=prod mix release --overwrite")
end

# ── 打包 ─────────────────────────────────────────────────────────────────────
release_dir = Path.join([root, "_build", "prod", "rel", release_name])
tarball = Path.join(System.tmp_dir!(), "#{release_name}-release.tar.gz")

Deploy.run!("[本地] 打包", "tar -czf #{tarball} -C #{release_dir} .")

# ── 上传 ─────────────────────────────────────────────────────────────────────
Deploy.scp!(tarball, "/tmp/#{release_name}-release.tar.gz", ctx)

if env_local_exists? do
  Deploy.scp!(env_local, "/tmp/#{app_name}.env", ctx)
end

config_local = Path.join(root, "config.yaml")
config_release = Path.join(Path.join(root, "elixir"), "config.yaml")

if File.exists?(config_local) do
  Deploy.scp!(config_local, "/tmp/#{app_name}-config.yaml", ctx)
else
  if File.exists?(config_release) do
    Deploy.scp!(config_release, "/tmp/#{app_name}-config.yaml", ctx)
  end
end

# ── 远端部署脚本 ─────────────────────────────────────────────────────────────
caddy_block =
  if caddy_enabled? do
    """

    # ── Caddy 反向代理 + 自动 TLS(原生 apt 安装)─────────────────────────
    echo "  配置 Caddy 反代..."

    # 1. 安装 Caddy(仅在未安装时执行)
    if ! command -v caddy >/dev/null 2>&1; then
      echo "  Caddy 未安装,从官方源安装..."
      $SUDO apt-get update -y
      $SUDO apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \\
        | $SUDO gpg --dearmor --batch --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \\
        | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
      $SUDO apt-get update -y
      $SUDO apt-get install -y caddy
    else
      echo "  Caddy 已安装"
    fi

    # 2. 写 Caddyfile
    $SUDO tee /etc/caddy/Caddyfile > /dev/null <<CADDYEOF
    {
      #{if caddy["email"] && caddy["email"] != "", do: "email #{caddy["email"]}", else: ""}
    }

    #{caddy["domain"]} {
      encode gzip
      reverse_proxy 127.0.0.1:#{caddy["upstream_port"] || 8318}
    }
    CADDYEOF

    # 3. 校验配置并 reload
    $SUDO caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    $SUDO systemctl enable caddy
    if systemctl is-active --quiet caddy; then
      $SUDO systemctl reload caddy
    else
      $SUDO systemctl restart caddy
    fi

    echo "  Caddy 已就绪"
    """
  else
    "\n# (Caddy 未启用)\n"
  end

env_setup =
  if env_local_exists? do
    """
    mv "/tmp/#{app_name}.env" "${ENV_FILE}"
    """
  else
    """
    # 没有提供本地 .env.prod,使用默认配置
    if [ ! -f "${ENV_FILE}" ]; then
      cat > "${ENV_FILE}" <<'ENVEOF'
    AUTH2API_CONFIG=#{deploy_dir}/config.yaml
    ENVEOF
    fi
    """
  end

remote_script = """
#!/usr/bin/env bash
set -euo pipefail

# root 不需要 sudo
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

APP_NAME="#{app_name}"
RELEASE_NAME="#{release_name}"
DEPLOY_DIR="#{deploy_dir}"
SERVICE_NAME="#{service_name}"
ENV_FILE="${DEPLOY_DIR}/.env"
TARBALL="/tmp/${RELEASE_NAME}-release.tar.gz"
AUTH_DIR="${HOME}/.auth2api_ex"

# ── 目录 & 持久化数据 ────────────────────────────────────────────────────────
$SUDO mkdir -p "${DEPLOY_DIR}"
$SUDO chown "$(whoami):$(whoami)" "${DEPLOY_DIR}"

# 确保持久化 auth 目录存在(token + accounts 跨部署保留)
mkdir -p "${AUTH_DIR}"

#{env_setup}

# ── 配置文件(仅首次部署写入,后续保留远端已有配置;--force-config 可强制覆盖)─
FORCE_CONFIG="#{force_config}"
CONFIG_TMP="/tmp/#{app_name}-config.yaml"
if [ -f "${CONFIG_TMP}" ]; then
  if [ "${FORCE_CONFIG}" = "true" ]; then
    echo "  --force-config: 强制覆盖远端 config.yaml"
    mv "${CONFIG_TMP}" "${DEPLOY_DIR}/config.yaml"
  elif [ ! -f "${DEPLOY_DIR}/config.yaml" ]; then
    echo "  远端无配置文件,将上传 config.yaml"
    mv "${CONFIG_TMP}" "${DEPLOY_DIR}/config.yaml"
  else
    echo ""
    echo "  ⚠ 远端 ${DEPLOY_DIR}/config.yaml 已存在,本次不会覆盖"
    echo "    网页生成的 api-key 不会丢失"
    echo ""
  fi
fi

# ── 停止现有服务 ─────────────────────────────────────────────────────────────
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
  echo "  停止现有服务..."
  $SUDO systemctl stop "${SERVICE_NAME}"
  sleep 2
fi

# ── 把当前 release 移到 previous/(只保留 1 个历史版本)─────────────────────
echo "  归档当前 release → previous/..."
PREVIOUS_DIR="${DEPLOY_DIR}/previous"
$SUDO rm -rf "${PREVIOUS_DIR}"
$SUDO mkdir -p "${PREVIOUS_DIR}"
for item in bin lib releases; do
  if [ -e "${DEPLOY_DIR}/${item}" ]; then
    $SUDO mv "${DEPLOY_DIR}/${item}" "${PREVIOUS_DIR}/${item}"
  fi
done
for ertsdir in "${DEPLOY_DIR}"/erts-*; do
  [ -e "${ertsdir}" ] && $SUDO mv "${ertsdir}" "${PREVIOUS_DIR}/"
done

# ── 解压新版本 ───────────────────────────────────────────────────────────────
# ~/.auth2api_ex/ 不在 release 里,OAuth token + accounts 自然保留。
echo "  解压新 release..."
tar -xzf "${TARBALL}" -C "${DEPLOY_DIR}"
rm -f "${TARBALL}"

# ── systemd 服务 ─────────────────────────────────────────────────────────────
echo "  配置 systemd..."
$SUDO tee "/etc/systemd/system/${SERVICE_NAME}" > /dev/null <<SVCEOF
[Unit]
Description=auth2api_ex — multi-provider AI API gateway
After=network.target

[Service]
Type=exec
User=$(whoami)
Group=$(whoami)
WorkingDirectory=${DEPLOY_DIR}
EnvironmentFile=-${ENV_FILE}
Environment=LANG=en_US.UTF-8
Environment=HOME=${HOME}
ExecStart=${DEPLOY_DIR}/bin/${RELEASE_NAME} start
ExecStop=${DEPLOY_DIR}/bin/${RELEASE_NAME} stop
Restart=on-failure
RestartSec=5
SyslogIdentifier=${APP_NAME}

[Install]
WantedBy=multi-user.target
SVCEOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable "${SERVICE_NAME}"
$SUDO systemctl start "${SERVICE_NAME}"
#{caddy_block}
echo ""
echo "✅ 部署完成"
echo "  状态: sudo systemctl status ${SERVICE_NAME}"
echo "  日志: sudo journalctl -u ${SERVICE_NAME} -f"
echo "  数据: ${AUTH_DIR}/  (OAuth token + accounts,跨部署保留)"
"""

Deploy.ssh!("[远端] 部署中...", remote_script, ctx)

IO.puts("\n🎉 部署流程结束")

if caddy_enabled? && caddy["domain"] do
  IO.puts("""

  🌐 公网访问:https://#{caddy["domain"]}
     (Caddy 首次签发证书需要 DNS 已指向该 VM,且 80/443 已开放)
  """)
end
