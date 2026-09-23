PV-First V50.5 - interface reabrivel + agente persistente

# PV-First V50.4

Correção da troca de perfil na interface visual do PC. O perfil HPC - Extremo e os demais perfis podem ser aplicados sem tentar sobrescrever a variável interna `$PID` do PowerShell. Erros de evento não devem mais encerrar a janela.

PV-FIRST V50.2 - INTERFACE ESTÁVEL

# PV-First V50.1 — correção de inicialização

Esta versão mantém a arquitetura da V50 e corrige o fechamento inesperado da interface.

Correção principal: um PID antigo do agente nunca mais é encerrado apenas pelo número; o processo só é finalizado se for confirmado como `GITHUB_PAGES_COMMAND_AGENT.ps1`.

Se a interface falhar por outro motivo, o diagnóstico fica em `_interno/startup_error.log` e uma caixa de erro é exibida.

Use somente `PVFIRST.bat`.
