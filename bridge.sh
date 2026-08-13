#!/bin/bash
clear

# Цвета и шрифты
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${CYAN}${BOLD}"
echo "============================================================"
echo "      🚀 МАСТЕР НАСТРОЙКИ УДАЛЕННОГО ДОСТУПА 🚀"
echo "============================================================"
echo -e "${NC}"

# ============================================================
# ⚠️ БАННЕР БЕЗОПАСНОСТИ И ЯВНОГО СОГЛАСИЯ ПОЛЬЗОВАТЕЛЯ (SECURITY AUDIT COMPLIANT)
# ============================================================
echo -e "${RED}${BOLD}"
echo "================================================================================"
echo "  ⚠️  ВНИМАНИЕ! ВЫ ВКЛЮЧАЕТЕ ВРЕМЕННЫЙ УДАЛЕННЫЙ ДОСТУП К УСТРОЙСТВУ  ⚠️"
echo "================================================================================"
echo -e "${NC}"
echo -e "${YELLOW}${BOLD}Данный скрипт выполняет следующие действия:${NC}"
echo -e " 1. Включает службу удалённого входа (SSH / Remote Management) на macOS."
echo -e " 2. Создаёт защищённый временный туннель для подключения оператора."
echo -e " 3. Предоставляет доступ к управлению Терминалом и Рабочим Столом устройства."
echo ""
echo -e "${BOLD}Информация о безопасности:${NC}"
echo -e " • Подключение требует пароля от учетной записи этого компьютера."
echo -e " • Вы можете в любой момент остановить доступ командой: ${CYAN}pkill -f pinggy${NC}"
echo -e "${RED}${BOLD}================================================================================"
echo "  🔑 ВВЕДИТЕ ПАРОЛЬ АДМИНИСТРАТОРА (ПАРОЛЬ ВХОДА В MACOS) ДЛЯ ПРОДОЛЖЕНИЯ"
echo "================================================================================"
echo -e "${NC}"

if [ -t 0 ]; then
    read -p "$(echo -e ${BOLD}"Вы согласны предоставить удалённый доступ? Нажмите [ENTER] для продолжения или [Ctrl+C] для отмены: "${NC})"
fi

echo ""
# 1. Проверяем, включен ли SSH (Remote Login)
echo -e "${BOLD}[1/3] Проверка службы SSH на ноутбуке...${NC}"

if nc -z localhost 22 2>/dev/null; then
    echo -e "${GREEN}✓ SSH-доступ уже включен и работает!${NC}\n"
else
    echo -e "${YELLOW}⚠️ Включение службы удалённого входа (запрос прав sudo)...${NC}"
    
    sudo systemsetup -setremotelogin on
    
    if nc -z localhost 22 2>/dev/null; then
        echo -e "${GREEN}✓ SSH успешно включен!${NC}\n"
    else
        echo -e "${RED}❌ Не удалось включить SSH. Проверьте правильность пароля.${NC}"
        exit 1
    fi
fi

# 2. Запускаем фоновый туннель Pinggy
echo -e "${BOLD}[2/3] Запуск защищенного фонового туннеля...${NC}"

pkill -f pinggy >/dev/null 2>&1
LOGFILE=$(mktemp /tmp/pinggy_XXXXXX.log)

# Запуск в фоне
ssh -p 443 -o StrictHostKeyChecking=no -R 0:localhost:22 a.pinggy.io > "$LOGFILE" 2>&1 &

sleep 4

USER_NAME=$(whoami)
HOST="a.pinggy.io"

# Извлекаем порт из вывода Pinggy
PORT=$(grep -oE "Allocated port [0-9]+" "$LOGFILE" | head -n 1 | awk '{print $3}')

if [ -z "$PORT" ]; then
    PINGGY_LINE=$(grep -oE "ssh -p [0-9]+ [^ ]+" "$LOGFILE" | head -n 1)
    PORT=$(echo "$PINGGY_LINE" | awk '{print $3}')
    EXT_HOST=$(echo "$PINGGY_LINE" | awk '{print $4}' | cut -d'@' -f2)
    if [ -n "$EXT_HOST" ]; then
        HOST="$EXT_HOST"
    fi
fi

if [ -n "$PORT" ]; then
    echo -e "${GREEN}✓ Сессия удалённого доступа успешно создана!${NC}"
    echo -e "${GREEN}✓ Окно Терминала можно закрывать. Для отмены выполните: pkill -f pinggy${NC}\n"
    
    echo -e "${GREEN}${BOLD}"
    echo "============================================================"
    echo "          🎉 ВСЁ ГОТОВО! ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ: 🎉"
    echo "============================================================"
    echo -e "${NC}"
    echo -e "Имя пользователя:          ${CYAN}${BOLD}${USER_NAME}${NC}"
    echo -e "Порт подключения:          ${CYAN}${BOLD}${PORT}${NC}"
    echo -e "Хост:                      ${CYAN}${BOLD}${HOST}${NC}"
    echo ""
    echo -e "${BOLD}1. Команда для подключения в Терминале (SSH):${NC}"
    echo -e "${YELLOW}ssh -p ${PORT} ${USER_NAME}@${HOST}${NC}"
    echo ""
    echo -e "${BOLD}2. Команда для подключения к Рабочему Столу (VNC / Экран):${NC}"
    echo -e "${YELLOW}ssh -L 5900:localhost:5900 -p ${PORT} ${USER_NAME}@${HOST}${NC}"
    echo -e "   Затем в Finder нажмите Cmd+K и введите: ${CYAN}vnc://localhost:5900${NC}"
    echo -e "${GREEN}${BOLD}============================================================${NC}\n"
else
    echo -e "${RED}❌ Не удалось запустить туннель. Проверьте интернет-соединение.${NC}"
    cat "$LOGFILE"
    rm -f "$LOGFILE"
    exit 1
fi

rm -f "$LOGFILE"
