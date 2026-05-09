# Cgroups v2 — Isolamento de Recursos no Linux

Estudo prático sobre cgroups v2: do conceito à aplicação real em hardening de sistema e laboratório de segurança.

---

## O que são Cgroups?

Cgroups (Control Groups) é um mecanismo do kernel Linux para **limitar, monitorar e isolar** o uso de recursos por processos — CPU, RAM, swap, I/O e número de processos.

São a base de Docker, Kubernetes, systemd e qualquer sandbox moderna.

```
Namespaces  →  "o que o processo enxerga"
Cgroups     →  "quanto o processo pode consumir"
Seccomp     →  "o que o processo pode fazer"
```

---

## Hardening do Sistema com systemd

A forma correta de aplicar limites permanentes é via **systemd**, não manipulando `/sys/fs/cgroup` diretamente. O systemd gerencia a hierarquia de cgroups e persiste entre reboots.

Por padrão, todos os limites são `infinity` — sem nenhuma proteção.

### Configurando o user.slice

```bash
sudo mkdir -p /etc/systemd/system/user.slice.d/

sudo tee /etc/systemd/system/user.slice.d/limits.conf << 'EOF'
[Slice]
TasksMax=2048
MemoryHigh=9G
MemoryMax=10G
MemorySwapMax=6G
EOF

sudo systemctl daemon-reload
```

`MemoryHigh` é o mais importante: aciona reclaim de memória antes do limite hard, trocando travamento total por degradação gradual e recuperável.

### Verificar limites ativos

```bash
systemctl show user.slice | grep -E "MemoryHigh|MemoryMax|MemorySwap|TasksMax"
```

---

## Lab Manual — Ciclo de Vida

Para testar payloads, fork bombs e scripts desconhecidos sem arriscar o sistema.

```bash
# Criar e configurar
sudo mkdir /sys/fs/cgroup/lab
echo "+memory +cpu +pids" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
echo 1G              | sudo tee /sys/fs/cgroup/lab/memory.max
echo "100000 1000000" | sudo tee /sys/fs/cgroup/lab/cpu.max   # 10% CPU
echo 128             | sudo tee /sys/fs/cgroup/lab/pids.max

# Entrar (shell atual + todos os filhos herdam)
echo $$ | sudo tee /sys/fs/cgroup/lab/cgroup.procs

# Destruir com segurança
echo 1 | sudo tee /sys/fs/cgroup/lab/cgroup.freeze   # congelar
cat /sys/fs/cgroup/lab/cgroup.procs | xargs -r sudo kill -9
echo 0 | sudo tee /sys/fs/cgroup/lab/cgroup.freeze   # descongelar
sudo rmdir /sys/fs/cgroup/lab
```

> O freeze antes do kill é essencial contra fork bombs — impede que novos processos sejam criados durante a limpeza.

---

## cglab — Script de Gerenciamento

Para facilitar o ciclo enter → testar → destruir, desenvolvi um script com perfis pré-configurados:

```bash
source cglab.sh enter            # perfil safe (padrão)
source cglab.sh enter strict     # payloads, fork bomb
source cglab.sh enter paranoid   # malware, red team OPSEC

source cglab.sh status           # limites e uso atual
source cglab.sh events           # OOM, throttle, fork bomb counters
source cglab.sh stop             # freeze + kill + remove
```

### Perfis

| Perfil | CPU | RAM | PIDs | Uso |
|---|---|---|---|---|
| `safe` | ~25% | 7G | 256 | Estudo geral, compilação |
| `strict` | ~10% | 2G | 128 | Payloads, scripts desconhecidos |
| `paranoid` | ~2% | 512M | 64 | Malware, análise crítica |

O uso de `source` (não execução direta) é necessário para mover o shell atual para o cgroup — execução em subshell moveria o processo filho, não o terminal.

---

## Observabilidade

```bash
systemd-cgls          # árvore de cgroups com processos
systemd-cgtop         # monitor em tempo real (top-like)

# Eventos do lab (OOM, throttle, fork bomb)
cat /sys/fs/cgroup/lab/memory.events
cat /sys/fs/cgroup/lab/pids.events
cat /sys/fs/cgroup/lab/cpu.stat

# PSI — pressão de recursos (detecta cryptominer, malware I/O intenso)
cat /proc/pressure/cpu
cat /proc/pressure/memory
```

---

## Aprendizados

- Cgroups v2 é hierárquico — controllers precisam ser habilitados em cada nível antes de funcionar nos filhos
- `cpu.max` usa microssegundos (`250000 1000000` = 25%), não notação de memória
- `rmdir` falha se ainda há processos no grupo — freeze + kill primeiro
- `(( aritmética ))` em zsh tem comportamento diferente do bash — preferir `awk` ou `grep -q`
- O `MemoryHigh` (soft limit) é mais útil no dia a dia que o `MemoryMax` (hard limit) — ele degrada antes de matar

---

## Próximos estudos

- **Namespaces** — isolamento de visão (PID, NET, MNT, USER)
- **Seccomp** — filtragem de syscalls
- **Capabilities** — granularização de privilégios root
- **eBPF** — observabilidade avançada, base dos EDRs modernos

---

## Referências

- [Kernel docs — cgroup-v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [systemd.resource-control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html)
- [Brendan Gregg — Linux Performance](https://www.brendangregg.com/linuxperf.html)
