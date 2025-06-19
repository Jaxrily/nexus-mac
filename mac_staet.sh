#!/bin/bash
set -e

IMAGE_NAME="nexus-node:latest"
DEFAULT_LOG_DIR="$HOME/nexus_logs"

mkdir -p "$DEFAULT_LOG_DIR"

function check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "未检测到 Docker，请先安装 Docker Desktop：https://www.docker.com"
        exit 1
    fi
}

function build_image() {
    if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
        echo "首次构建镜像..."
        WORKDIR=$(mktemp -d)
        cd "$WORKDIR"

        cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PROVER_ID_FILE=/root/.nexus/node-id

RUN apt-get update && apt-get install -y \\
    curl \\
    screen \\
    bash \\
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://cli.nexus.xyz/ | sh && \\
    ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network && \\
    nexus-network version || (echo "nexus-network 安装失败" && exit 1)

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

        cat > entrypoint.sh <<EOF
#!/bin/bash
set -e
PROVER_ID_FILE="/root/.nexus/node-id"

echo "\$NODE_ID" > "\$PROVER_ID_FILE"
echo "使用的 node-id: \$NODE_ID"

if ! command -v nexus-network >/dev/null 2>&1; then
    echo "nexus-network 未安装或不可用"
    exit 1
fi

screen -S nexus -X quit >/dev/null 2>&1 || true
screen -dmS nexus bash -c "nexus-network start --node-id \$NODE_ID &>> /root/nexus.log"

sleep 3

if screen -list | grep -q "nexus"; then
    echo "节点已在后台启动"
else
    echo "节点启动失败，请检查日志：/root/nexus.log"
    cat /root/nexus.log
    exit 1
fi

tail -f /root/nexus.log
EOF

        docker build -t "$IMAGE_NAME" .
        cd -
        rm -rf "$WORKDIR"
    else
        echo "镜像已存在，跳过构建。"
    fi
}

function run_container() {
    read -rp "请输入您的 node-id: " NODE_ID
    if [[ -z "$NODE_ID" ]]; then
        echo "node-id 不能为空。"
        return
    fi

    read -rp "请输入容器名称（默认 nexus-$(date +%s)）: " input_name
    CONTAINER_NAME=${input_name:-nexus-$(date +%s)}

    if ! [[ "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "容器名不合法"
        return
    fi

    LOG_FILE="$DEFAULT_LOG_DIR/${CONTAINER_NAME}.log"
    touch "$LOG_FILE"

    echo "启动容器 $CONTAINER_NAME..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    docker run -d --name "$CONTAINER_NAME" \
        -e NODE_ID="$NODE_ID" \
        -v "$LOG_FILE":/root/nexus.log \
        "$IMAGE_NAME"

    sleep 2
    if docker ps --format '{{.Names}}' | grep -qw "$CONTAINER_NAME"; then
        echo "容器 $CONTAINER_NAME 启动成功，日志：$LOG_FILE"
    else
        echo "启动失败，请查看日志：$LOG_FILE"
        docker logs "$CONTAINER_NAME"
    fi
}

function show_node_id() {
    read -rp "请输入容器名称: " name
    if docker ps -a --format '{{.Names}}' | grep -qw "$name"; then
        docker exec "$name" cat /root/.nexus/node-id || echo "读取失败"
    else
        echo "容器不存在：$name"
    fi
}

function uninstall_node() {
    read -rp "请输入要卸载的容器名称: " name
    docker rm -f "$name" && echo "容器 $name 已删除"
    rm -f "$DEFAULT_LOG_DIR/$name.log"
}

function show_log() {
    read -rp "请输入要查看的容器名称: " name
    if docker ps -a --format '{{.Names}}' | grep -qw "$name"; then
        docker logs -f "$name"
    else
        echo "容器未运行或不存在：$name"
    fi
}

function main_menu() {
    check_docker
    build_image

    while true; do
        clear
        echo "========== Nexus 多节点管理 =========="
        echo "1. 安装并启动新节点"
        echo "2. 显示某节点的 node-id"
        echo "3. 卸载某个节点"
        echo "4. 查看节点日志"
        echo "5. 退出"
        echo "======================================"
        read -rp "请输入选项(1-5): " choice
        case "$choice" in
            1) run_container; read -p "按任意键返回菜单" ;;
            2) show_node_id; read -p "按任意键返回菜单" ;;
            3) uninstall_node; read -p "按任意键返回菜单" ;;
            4) show_log; read -p "按任意键返回菜单" ;;
            5) exit 0 ;;
            *) echo "无效选项"; read -p "按任意键返回菜单" ;;
        esac
    done
}

main_menu
