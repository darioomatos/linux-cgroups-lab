#!/usr/bin/env bash
# =============================================================================
#  cglab — Cgroup Lab Profile Manager
#  Uso: source cglab.sh <comando> [perfil]
#
#  Comandos:
#    enter  [perfil]   →  move shell atual para o cgroup do perfil
#    status            →  mostra limites e uso atual
#    events            →  mostra eventos (oom, throttle, fork bombs)
#    stop              →  freeze + kill + remove o cgroup
#    list              →  lista perfis disponíveis
#
#  Perfis:
#    safe      →  estudo geral, contenção básica (padrão)
#    strict    →  testes de malware, fork bomb, payloads
#    paranoid  →  análise de amostra crítica, máxima contenção
# =============================================================================

CGROOT="/sys/fs/cgroup"
CGLAB="${CGROOT}/lab"

# -----------------------------------------------------------------------------
# Definição dos perfis
# -----------------------------------------------------------------------------
_cg_profile_safe() {
    # Estudo geral — proteção sem restringir demais
    # Fork bomb: contida em 256 tasks
    # RAM: 4GB — confortável para compilar, rodar VMs leves, ferramentas pesadas
    # Edit: 7GB para o perfil safe.
    echo "250000 1000000" | sudo tee "${CGLAB}/cpu.max"        > /dev/null  # ~25% CPU (250ms/1s)
    echo 7G             | sudo tee "${CGLAB}/memory.max"        > /dev/null
    echo 6G             | sudo tee "${CGLAB}/memory.high"       > /dev/null
    echo 2G             | sudo tee "${CGLAB}/memory.swap.max"   > /dev/null
    echo 256            | sudo tee "${CGLAB}/pids.max"          > /dev/null
}

_cg_profile_strict() {
    # Testes de payloads, fork bomb, scripts desconhecidos
    # Limites mais agressivos — ainda usável para trabalho moderado
    echo "100000 1000000" | sudo tee "${CGLAB}/cpu.max"         > /dev/null  # ~10% CPU
    echo 1G               | sudo tee "${CGLAB}/memory.max"      > /dev/null
    echo 950M             | sudo tee "${CGLAB}/memory.high"     > /dev/null
    echo 512M             | sudo tee "${CGLAB}/memory.swap.max" > /dev/null
    echo 128              | sudo tee "${CGLAB}/pids.max"        > /dev/null
}

_cg_profile_paranoid() {
    # Análise de malware, amostras desconhecidas, máxima contenção
    # CPU mínima — implant/beacon não vai causar spike detectável
    echo "20000 1000000"  | sudo tee "${CGLAB}/cpu.max"         > /dev/null  # ~2% CPU
    echo 512M             | sudo tee "${CGLAB}/memory.max"      > /dev/null
    echo 450M             | sudo tee "${CGLAB}/memory.high"     > /dev/null
    echo 128M             | sudo tee "${CGLAB}/memory.swap.max" > /dev/null
    echo 64               | sudo tee "${CGLAB}/pids.max"        > /dev/null
}

# -----------------------------------------------------------------------------
# Funções principais
# -----------------------------------------------------------------------------
_cg_setup() {
    local profile="${1:-safe}"

    # Criar cgroup se não existir
    if [[ ! -d "${CGLAB}" ]]; then
        sudo mkdir -p "${CGLAB}"
    fi

    # Habilitar controllers no pai (necessário para subgrupos funcionarem)
    echo "+memory +cpu +pids" | sudo tee "${CGROOT}/cgroup.subtree_control" > /dev/null

    # Aplicar perfil
    case "${profile}" in
        safe)     _cg_profile_safe     ;;
        strict)   _cg_profile_strict   ;;
        paranoid) _cg_profile_paranoid ;;
        *)
            echo "[cglab] Perfil desconhecido: '${profile}'"
            echo "[cglab] Disponíveis: safe | strict | paranoid"
            return 1
            ;;
    esac

    echo "[cglab] Perfil '${profile}' aplicado em ${CGLAB}"
}

cg_enter() {
    local profile="${1:-safe}"

    _cg_setup "${profile}" || return 1

    # Mover shell atual para o cgroup
    # Todos os processos filhos (comandos digitados) herdam automaticamente
    echo $$ | sudo tee "${CGLAB}/cgroup.procs" > /dev/null

    echo "[cglab] Shell (PID $$) movido para ${CGLAB}"
    echo "[cglab] Processos filhos herdam este cgroup automaticamente."
    echo ""
    cg_status
}

cg_status() {
    if [[ ! -d "${CGLAB}" ]]; then
        echo "[cglab] Lab não existe. Use: cg_enter [perfil]"
        return 1
    fi

    local mem_cur mem_max mem_high pids_cur pids_max cpu_max

    mem_cur=$(cat "${CGLAB}/memory.current"  2>/dev/null || echo 0)
    mem_max=$(cat "${CGLAB}/memory.max"      2>/dev/null || echo "∞")
    mem_high=$(cat "${CGLAB}/memory.high"    2>/dev/null || echo "∞")
    pids_cur=$(cat "${CGLAB}/pids.current"   2>/dev/null || echo 0)
    pids_max=$(cat "${CGLAB}/pids.max"       2>/dev/null || echo "∞")
    cpu_max=$(cat "${CGLAB}/cpu.max"         2>/dev/null || echo "max")

    # Converter bytes para MB/GB legível (awk — compatível com bash e zsh)
    _fmt_bytes() {
        local b="$1"
        if [[ "$b" =~ ^[0-9]+$ ]]; then
            awk -v n="$b" 'BEGIN {
                if      (n >= 1073741824) printf "%.1fG", n/1073741824
                else if (n >= 1048576)   printf "%.0fM", n/1048576
                else if (n >= 1024)      printf "%.0fK", n/1024
                else                     printf "%dB",   n
            }'
        else
            echo "$b"
        fi
    }

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " cglab — status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf " %-12s %s / %s  (high: %s)\n" \
        "Memória:"  "$(_fmt_bytes "$mem_cur")" "$(_fmt_bytes "$mem_max")" "$(_fmt_bytes "$mem_high")"
    printf " %-12s %s / %s\n" \
        "Processos:" "${pids_cur}" "${pids_max}"
    printf " %-12s %s\n" \
        "CPU quota:" "${cpu_max}"

    # Verificar se a shell atual está no cgroup
    # grep -q — sem aritmética, compatível com zsh
    # grep -c retorna 0 (não encontrado) ou N (encontrado) — sem aritmética, compatível com zsh
    if grep -q "^$$\$" "${CGLAB}/cgroup.procs" 2>/dev/null; then
        printf " %-12s PID %s está no lab ✓\n" "Shell:" "$$"
    else
        printf " %-12s PID %s NÃO está no lab\n" "Shell:" "$$"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

cg_events() {
    if [[ ! -d "${CGLAB}" ]]; then
        echo "[cglab] Lab não existe."
        return 1
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Memory events:"
    cat "${CGLAB}/memory.events" 2>/dev/null
    echo ""
    echo " PID events:"
    cat "${CGLAB}/pids.events"   2>/dev/null
    echo ""
    echo " CPU stats:"
    cat "${CGLAB}/cpu.stat"      2>/dev/null | grep -E "nr_throttled|throttled_usec"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

cg_stop() {
    if [[ ! -d "${CGLAB}" ]]; then
        echo "[cglab] Lab não existe."
        return 0
    fi

    # Segurança: não matar o shell atual se ele estiver no cgroup
    local my_cg
    my_cg=$(cat /proc/$$/cgroup 2>/dev/null | grep -o 'lab$' || true)
    if [[ "${my_cg}" == "lab" ]]; then
        echo "[cglab] AVISO: seu shell (PID $$) está dentro do lab."
        echo "[cglab] Mova-o primeiro: echo \$\$ | sudo tee /sys/fs/cgroup/cgroup.procs"
        return 1
    fi

    echo "[cglab] Congelando processos..."
    echo 1 | sudo tee "${CGLAB}/cgroup.freeze" > /dev/null

    local procs
    procs=$(cat "${CGLAB}/cgroup.procs" 2>/dev/null)

    if [[ -n "${procs}" ]]; then
        echo "[cglab] Matando: $(echo "$procs" | tr '\n' ' ')"
        echo "${procs}" | xargs -r sudo kill -9 2>/dev/null
        sleep 0.3
    fi

    echo 0 | sudo tee "${CGLAB}/cgroup.freeze" > /dev/null

    # Tentar remover (falha se ainda houver processos)
    if sudo rmdir "${CGLAB}" 2>/dev/null; then
        echo "[cglab] Lab removido."
    else
        echo "[cglab] Aviso: ainda há processos no cgroup. Tente novamente."
        echo "Processos restantes:"
        cat "${CGLAB}/cgroup.procs" | xargs -I{} ps -p {} -o pid,comm 2>/dev/null
    fi
}

cg_list() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf " %-12s  %-8s  %-8s  %-8s  %-8s  %s\n" "Perfil" "CPU" "RAM" "high" "Swap" "PIDs"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf " %-12s  %-8s  %-8s  %-8s  %-8s  %s\n" "safe"     "~25%"  "4G"   "3G"   "2G"   "256"
    printf " %-12s  %-8s  %-8s  %-8s  %-8s  %s\n" "strict"   "~10%"  "1G"   "768M" "512M" "128"
    printf " %-12s  %-8s  %-8s  %-8s  %-8s  %s\n" "paranoid" "~2%"   "256M" "192M" "128M" "64"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo " safe     — estudo geral, compilação, ferramentas comuns"
    echo " strict   — payloads, scripts desconhecidos, fork bomb tests"
    echo " paranoid — análise de malware, amostras críticas, red team OPSEC"
}

# -----------------------------------------------------------------------------
# Dispatcher (quando chamado diretamente: source cglab.sh <cmd> [perfil])
# -----------------------------------------------------------------------------
_cglab_dispatch() {
    case "$1" in
        enter)   cg_enter  "${2}"  ;;
        status)  cg_status         ;;
        events)  cg_events         ;;
        stop)    cg_stop           ;;
        list)    cg_list           ;;
        *)
            echo "Uso: source cglab.sh <comando> [perfil]"
            echo ""
            echo "Comandos:"
            echo "  enter  [perfil]   move shell atual para o cgroup"
            echo "  status            limites e uso atual"
            echo "  events            OOM, throttle, fork bomb counters"
            echo "  stop              freeze + kill + remove"
            echo "  list              perfis disponíveis"
            echo ""
            echo "Perfis: safe | strict | paranoid"
            ;;
    esac
}

# Só executa o dispatcher se foi chamado com argumento
# (permite 'source cglab.sh' apenas para carregar as funções)
if [[ -n "$1" ]]; then
    _cglab_dispatch "$@"
fi
