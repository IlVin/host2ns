# host2ns — публикация имён хостов в NSD по SSH.
#
# Реестр у разработчика: ~/.host2ns/config и ~/.host2ns/hosts.
# В репозитории только примеры.

# все скрипты — bash; рецепты тоже, чтобы set -o pipefail работал везде
SHELL := /bin/bash

NAME         ?= host2ns
BASE         ?= iv77msk.ru
HOST2NS_HOME ?= $(HOME)/.$(NAME)

.PHONY: help host2ns status check bootstrap-nsd bootstrap-host restore authorize prune

help:
	@echo "make host2ns          применить реестр: установить/обновить на всех хостах"
	@echo "make status           состояние: зоны, имена, свежесть публикаций"
	@echo "make check            локальная проверка генерации зон"
	@echo "make bootstrap-host HOST=x  подготовить хост: скрипты + NOPASSWD"
	@echo "make authorize HOST=x разрешить ключ хоста на NS (после bootstrap-host)"
	@echo "make bootstrap-nsd    установить NSD на этом хосте (HOST не используется)"
	@echo "make restore          перегенерировать зоны из состояния"
	@echo "make prune            удалить имена хостов, убранных из реестра"
	@echo ""
	@echo "реестр: $(HOST2NS_HOME)/config и $(HOST2NS_HOME)/hosts"

host2ns:
	@set -o pipefail; NAME=$(NAME) BASE=$(BASE) HOST2NS_HOME=$(HOST2NS_HOME) ./scripts/publish.sh 2>&1 | cat

status:
	@NAME=$(NAME) BASE=$(BASE) HOST2NS_HOME=$(HOST2NS_HOME) ./scripts/status.sh

bootstrap-host:
	@test -n "$(HOST)" || { echo "нужен HOST=<алиас>" >&2; exit 2; }
	@tar -czf /tmp/$(NAME)-boot.tgz -C scripts .
	@scp -q /tmp/$(NAME)-boot.tgz "$(HOST):/tmp/$(NAME)-boot.tgz"
	@ssh -tt "$(HOST)" "rm -rf /tmp/$(NAME)-boot && mkdir -p /tmp/$(NAME)-boot && tar -xzf /tmp/$(NAME)-boot.tgz -C /tmp/$(NAME)-boot && sudo NAME=$(NAME) bash /tmp/$(NAME)-boot/bootstrap-host.sh" 2>&1 | cat
	@rm -f /tmp/$(NAME)-boot.tgz

prune:
	@NAME=$(NAME) BASE=$(BASE) HOST2NS_HOME=$(HOST2NS_HOME) ./scripts/prune.sh

authorize:
	@test -n "$(HOST)" || { echo "нужен HOST=<алиас>" >&2; exit 2; }
	@. $(HOST2NS_HOME)/config; \
	pub="$$(ssh -n $(HOST) 'cat /etc/$(NAME)/key.pub' 2>/dev/null)" || { \
	    echo "нет /etc/$(NAME)/key.pub на $(HOST): сначала make bootstrap-host и make host2ns" >&2; exit 2; }; \
	NAME=$(NAME) ./scripts/authorize.sh "$$NS" "$$pub"

restore:
	@. $(HOST2NS_HOME)/config; \
	ssh -t "$$NS" "sudo sh -c 'systemctl restart $(NAME)-zones.service && nsd-control reconfig && nsd-control reload' && systemctl is-active nsd"

bootstrap-nsd:
	@test -z "$(HOST)" || { \
	    echo "bootstrap-nsd ставит NSD на ТЕКУЩЕМ хосте; HOST не используется." >&2; \
	    echo "Запустите на NS, например:" >&2; \
	    echo "  scp scripts/bootstrap-nsd.sh $(HOST):/tmp/" >&2; \
	    echo "  ssh -t $(HOST) 'sudo NAME=$(NAME) BASE=$(BASE) bash /tmp/bootstrap-nsd.sh'" >&2; \
	    exit 2; }
	@sudo NAME=$(NAME) BASE=$(BASE) ./scripts/bootstrap-nsd.sh

check:
	@bash scripts/check.sh
