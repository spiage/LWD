#!/usr/bin/env bash
set -euo pipefail

# Функция для очистки временных файлов
cleanup() {
    rm -f "$TEMP_USER_DATA" "$TEMP_META_DATA" "$TEMP_NETWORK_CONFIG" \
          "$TEMP_SYSTEMD_NETWORK" "$TEMP_DATASOURCE_CFG" "$TEMP_KEYS" \
          "$TEMP_GUESTFISH_CMD" 2>/dev/null || true
}

# Регистрация функции очистки на выходе
trap cleanup EXIT INT TERM

# ==============================
# ПРОВЕРКА АРГУМЕНТОВ
# ==============================
if [ $# -lt 1 ]; then
    echo "Использование: $0 <os_type> <os_version> <vm_name> <ssh_user> <memory_mb> <vcpus> <disk_gb> [network_interface] [mac_address] [disable_cloudinit]"
    echo "  os_type: ubuntu, debian, astra"
    echo "  os_version: версия ОС (24.04, 22.04 для ubuntu; 12, 13 для debian; 1.7, 1.8 для astra)"
    echo "  vm_name: имя виртуальной машины"
    echo "  ssh_user: имя пользователя для создания"
    echo "  memory_mb: память в МБ"
    echo "  vcpus: количество ядер CPU"
    echo "  disk_gb: размер диска в ГБ"
    echo "  network_interface: имя сети (по умолчанию bridged-network)"
    echo "  mac_address: MAC адрес (опционально)"
    echo "  disable_cloudinit: отключить cloud-init после первой загрузки (true/false, по умолчанию true)"
    exit 1
fi

# ==============================
# ПАРАМЕТРЫ
# ==============================
OS_TYPE="${1:-astra}"
OS_VERSION="${2:-1.7}"
VM_NAME="${3:-a17-test1}"
SSH_USER="${4:-spiage}"
MEMORY_MB="${5:-3072}"
VCPUS="${6:-2}"
DISK_GB="${7:-20}"
NETWORK_INTERFACE="${8:-bridged-network}"
MAC_ADDRESS="${9:-}"
DISABLE_CLOUDINIT="${10:-false}"

# Проверка числовых параметров
if ! [[ "$MEMORY_MB" =~ ^[0-9]+$ ]]; then
    echo "Ошибка: memory_mb должно быть числом"
    exit 1
fi
if ! [[ "$VCPUS" =~ ^[0-9]+$ ]]; then
    echo "Ошибка: vcpus должно быть числом"
    exit 1
fi
if ! [[ "$DISK_GB" =~ ^[0-9]+$ ]]; then
    echo "Ошибка: disk_gb должно быть числом"
    exit 1
fi

# ==============================
# ПРОВЕРКА СУЩЕСТВОВАНИЯ VM
# ==============================
if virsh list --all | grep -q " $VM_NAME "; then
    echo "Ошибка: VM с именем $VM_NAME уже существует"
    exit 1
fi

# ==============================
# ПРОВЕРКА СВОБОДНОГО МЕСТА
# ==============================
REQUIRED_SPACE=$((DISK_GB * 1024 * 1024 * 2))
AVAILABLE_SPACE=$(df -k --output=avail . | tail -1)
if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
    echo "Ошибка: недостаточно свободного места для создания диска"
    echo "Требуется: $((REQUIRED_SPACE / 1024 / 1024)) ГБ"
    echo "Доступно: $((AVAILABLE_SPACE / 1024 / 1024)) ГБ"
    exit 1
fi

# ==============================
# ПРОИЗВОДНЫЕ ПАРАМЕТРЫ
# ==============================
DISK_NAME="${VM_NAME}.qcow2"
HOSTNAME="$VM_NAME"
SSH_KEYS_DIR="/home/$SSH_USER/.ssh"
DISK_SIZE="${DISK_GB}G"

# Генерация MAC адреса если не указан
if [ -z "$MAC_ADDRESS" ]; then
    MAC_ADDRESS=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
fi

# ==============================
# УСТАНОВКА ПАРАМЕТРОВ ОС
# ==============================
if [ "$OS_TYPE" = "ubuntu" ]; then
    if [ "$OS_VERSION" = "24.04" ]; then
        OS_CODE="noble"
        OS_INFO="ubuntu24.04"
    elif [ "$OS_VERSION" = "22.04" ]; then
        OS_CODE="jammy"
        OS_INFO="ubuntu22.04"
    else
        echo "Ошибка: неизвестная версия Ubuntu: $OS_VERSION"
        exit 1
    fi
    CLOUD_IMAGE="${OS_CODE}-server-cloudimg-amd64.img"
    CLOUD_URL="https://cloud-images.ubuntu.com/${OS_CODE}/current/${CLOUD_IMAGE}"
    USE_UEFI=true
    ROOT_PARTITION="/dev/sda1"
elif [ "$OS_TYPE" = "debian" ]; then
    if [ "$OS_VERSION" = "12" ]; then
        OS_CODE="bookworm"
        OS_INFO="debian12"
    elif [ "$OS_VERSION" = "13" ]; then
        OS_CODE="trixie"
        OS_INFO="debian13"
    else
        echo "Ошибка: неизвестная версия Debian: $OS_VERSION"
        exit 1
    fi
    CLOUD_IMAGE="debian-${OS_VERSION}-genericcloud-amd64.qcow2"
    CLOUD_URL="https://cloud.debian.org/images/cloud/${OS_CODE}/latest/${CLOUD_IMAGE}"
    USE_UEFI=true
    ROOT_PARTITION="/dev/sda1"
elif [ "$OS_TYPE" = "astra" ]; then
    if [ "$OS_VERSION" = "1.7" ]; then
        OS_INFO="debian10"
        ROOT_PARTITION="/dev/sda1"
    elif [ "$OS_VERSION" = "1.8" ]; then
        OS_INFO="debian12"
        ROOT_PARTITION="/dev/sda2"
    else
        echo "Ошибка: неизвестная версия Astra: $OS_VERSION"
        exit 1
    fi
    CLOUD_IMAGE="alse-${OS_VERSION}-base-cloudinit-latest-amd64.qcow2"
    CLOUD_URL="https://registry.astralinux.ru/artifactory/mg-generic/alse/cloudinit/${CLOUD_IMAGE}"
    USE_UEFI=false
else
    echo "Ошибка: неизвестный тип ОС: $OS_TYPE"
    exit 1
fi

# ==============================
# ПРОВЕРКА СЕТИ
# ==============================
if ! virsh net-info "$NETWORK_INTERFACE" >/dev/null 2>&1; then
    echo "Ошибка: сеть '$NETWORK_INTERFACE' не найдена"
    echo "Доступные сети:"
    virsh net-list --all
    exit 1
fi

# ==============================
# СКАЧИВАНИЕ ОБРАЗА
# ==============================
if [ ! -f "$CLOUD_IMAGE" ]; then
    echo "Скачивание образа..."
    if ! wget -T 10 -N --continue "$CLOUD_URL"; then
        echo "Ошибка: не удалось скачать образ $CLOUD_URL"
        exit 1
    fi
fi

# ==============================
# СОЗДАНИЕ ДИСКА
# ==============================
echo "Копирование образа $CLOUD_IMAGE в $DISK_NAME..."
cp "$CLOUD_IMAGE" "$DISK_NAME"
qemu-img resize "$DISK_NAME" "$DISK_SIZE"
# ==============================
# СОЗДАНИЕ ВРЕМЕННЫХ ФАЙЛОВ
# ==============================
TEMP_USER_DATA=$(mktemp)
TEMP_META_DATA=$(mktemp)
TEMP_NETWORK_CONFIG=$(mktemp)
TEMP_SYSTEMD_NETWORK=$(mktemp)
TEMP_DATASOURCE_CFG=$(mktemp)
TEMP_KEYS=$(mktemp)
TEMP_GUESTFISH_CMD=$(mktemp)

# ==============================
# СБОР SSH КЛЮЧЕЙ
# ==============================
cat "$SSH_KEYS_DIR"/*.pub > "$TEMP_KEYS" 2>/dev/null || true

# Проверка наличия SSH ключей
if [ ! -s "$TEMP_KEYS" ]; then
    echo "Ошибка: не найдены SSH ключи в директории $SSH_KEYS_DIR"
    echo "Пожалуйста, добавьте хотя бы один публичный SSH ключ в директорию $SSH_KEYS_DIR"
    exit 1
fi

# ==============================
# КОНФИГУРАЦИЯ CLOUD-INIT
# ==============================
# Создание user-data (общая часть для всех ОС)
cat > "$TEMP_USER_DATA" <<EOF
#cloud-config
hostname: $HOSTNAME
manage_etc_hosts: true
users:
  - name: $SSH_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
EOF

# Добавляем SSH ключи
while IFS= read -r key; do
    if [ -n "$key" ]; then
        echo "    - $key" >> "$TEMP_USER_DATA"
    fi
done < "$TEMP_KEYS"

# Базовые настройки (общие для всех ОС)
cat >> "$TEMP_USER_DATA" <<EOF
ssh_pwauth: false
disable_root: true
ssh_deletekeys: false
package_update: true
package_upgrade: true
ssh:
  emit_keys_to_console: false
# Автоматическое расширение корневого раздела при увеличении размера диска
growpart:
  mode: auto
  devices: ["/"]
resize_rootfs: true
# Запуск команд при первой загрузке
runcmd:
  - systemctl restart ssh
  - ping _gateway -c 5
  - reboot
EOF

# Отключение cloud-init при необходимости
if [ "$DISABLE_CLOUDINIT" = true ]; then
    cat >> "$TEMP_USER_DATA" <<EOF
  - touch /etc/cloud/cloud-init.disabled
EOF
fi

# Специфичная сетевая конфигурация
if [ "$OS_TYPE" = "ubuntu" ]; then
    # Шаблон сетевой конфигурации для Ubuntu (netplan)
    cat > "$TEMP_NETWORK_CONFIG" <<EOF
network:
  version: 2
  ethernets:
    matched-interface:
      match:
        macaddress: "$MAC_ADDRESS"
      dhcp4: true
      dhcp6: false
      optional: true
      ignore-carrier: true
EOF
else
    # Шаблон сетевой конфигурации для systemd-networkd (Debian/Astra)
    cat > "$TEMP_SYSTEMD_NETWORK" <<EOF
[Match]
Name=enp1s0
[Network]
DHCP=yes
EOF
fi

# Meta-data (общая для всех ОС)
cat > "$TEMP_META_DATA" <<EOF
instance-id: $(uuidgen || echo iid-local01)
local-hostname: $HOSTNAME
EOF

# Конфигурация источника данных (общая для всех ОС)
cat > "$TEMP_DATASOURCE_CFG" <<EOF
datasource:
  NoCloud:
    seedfrom: /var/lib/cloud/seed/nocloud/
EOF

# ==============================
# НАСТРОЙКА ДИСКА ЧЕРЕЗ GUESTFISH
# ==============================
# Базовые команды guestfish (общие для всех ОС)
cat > "$TEMP_GUESTFISH_CMD" <<EOF
run
mount $ROOT_PARTITION /
mkdir-p /var/lib/cloud/seed/nocloud
upload $TEMP_USER_DATA /var/lib/cloud/seed/nocloud/user-data
chmod 0600 /var/lib/cloud/seed/nocloud/user-data
upload $TEMP_META_DATA /var/lib/cloud/seed/nocloud/meta-data
chmod 0600 /var/lib/cloud/seed/nocloud/meta-data
sh 'echo "127.0.0.1 localhost" > /etc/hosts'
sh 'echo "127.0.1.1 $HOSTNAME" >> /etc/hosts'
EOF

# Специфичные команды для Ubuntu
if [ "$OS_TYPE" = "ubuntu" ]; then
    cat >> "$TEMP_GUESTFISH_CMD" <<EOF
sh 'rm -f /etc/netplan/*.yaml'
upload $TEMP_NETWORK_CONFIG /etc/netplan/01-network-config.yaml
chmod 0600 /etc/netplan/01-network-config.yaml
EOF
fi

# Специфичные команды для Debian/Astra
if [ "$OS_TYPE" != "ubuntu" ]; then
    cat >> "$TEMP_GUESTFISH_CMD" <<EOF
sh 'mkdir -p /etc/systemd/network'
sh 'rm -f /etc/systemd/network/*.network'
upload $TEMP_SYSTEMD_NETWORK /etc/systemd/network/10-dhcp.network
chmod 0644 /etc/systemd/network/10-dhcp.network
EOF
fi

# Общие команды завершения
cat >> "$TEMP_GUESTFISH_CMD" <<EOF
upload $TEMP_DATASOURCE_CFG /etc/cloud/cloud.cfg.d/99-datasource.cfg
chmod 0600 /etc/cloud/cloud.cfg.d/99-datasource.cfg
umount /
exit
EOF

# Выполнение команд guestfish
echo "Настройка диска с помощью guestfish..."
guestfish -a "$DISK_NAME" -f "$TEMP_GUESTFISH_CMD"

# ==============================
# СОЗДАНИЕ ВИРТУАЛЬНОЙ МАШИНЫ
# ==============================
# Формирование команды virt-install
VIRT_INSTALL_CMD=(
    --name "$VM_NAME"
    --memory "$MEMORY_MB"
    --vcpus "$VCPUS"
    --disk path="$DISK_NAME"
    --network network="$NETWORK_INTERFACE",mac="$MAC_ADDRESS"
    --import
    --osinfo "$OS_INFO"
    --noautoconsole
)

# Добавляем параметры UEFI если нужно
if [ "$USE_UEFI" = true ]; then
    VIRT_INSTALL_CMD+=(--boot uefi)
    BOOT_MODE="UEFI"
else
    BOOT_MODE="Legacy BIOS"
fi

# Создание виртуальной машины
echo "Создание виртуальной машины $VM_NAME..."
virt-install "${VIRT_INSTALL_CMD[@]}"

# ==============================
# ВЫВОД ИНФОРМАЦИИ
# ==============================
echo "Готово! Виртуальная машина $VM_NAME создана и настроена"
echo ""
echo "Характеристики VM:"
echo "  ОС: $OS_TYPE $OS_VERSION (${OS_CODE:-})"
echo "  Память: ${MEMORY_MB} МБ"
echo "  CPU: $VCPUS ядер"
echo "  Диск: ${DISK_GB} ГБ"
echo "  Загрузка: $BOOT_MODE"
echo "  Корневой раздел: $ROOT_PARTITION"
echo "  Сеть libvirt: $NETWORK_INTERFACE"
echo "  Cloud-init: $([ "$DISABLE_CLOUDINIT" = true ] && echo "отключен" || echo "включен")"
echo ""
echo "Для получения IP-адреса:"
echo "1. Посмотрите вывод cloud-init при загрузке: virsh console $VM_NAME"
echo "2. Или используйте: ping -c 2 -b $(ip route | grep default | awk '{print $3}') >/dev/null 2>&1 || true && ip neigh show | grep -i '$MAC_ADDRESS'"
echo ""
echo "Для управления размером диска:"
echo "1. Увеличьте размер диска: qemu-img resize $DISK_NAME +10G"
echo "2. Перезагрузите VM - раздел автоматически расширится"
echo ""
echo "Для подключения после получения IP:"
echo "ssh $SSH_USER@<IP-адрес>"
