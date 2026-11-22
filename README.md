# KDE Connect para Noctalia Shell

Plugin para o **Noctalia Shell (v5+)** que integra o **KDE Connect** via D-Bus (`org.kde.kdeconnect`), com widget na barra, painel interativo e configurações integradas.

## Recursos

- **Widget na barra**: ícone do celular com nível de bateria, ícone dinâmico de carregamento (`battery-charging`), estado (conectado, desconectado, não pareado, daemon offline) e opção de ocultar quando desconectado.
- **Painel principal**:
  - Lista de dispositivos com seleção do dispositivo ativo.
  - Ações rápidas: enviar ping, tocar celular (*Find My Phone*), enviar arquivo (`zenity`), enviar texto/URL e enviar área de transferência.
  - Pareamento e despareamento com confirmação.
  - Controle de mídia do celular (MPRIS).
  - Notificações espelhadas com opção de dispensar e responder inline.
- **Configurações**: dispositivo padrão, ações/seções visíveis no painel e comportamento do widget na barra.

## Dependências

- **Noctalia Shell** (`>= 5.x`, `plugin_api >= 29`)
- **KDE Connect** (`kdeconnectd` ativo na sessão D-Bus)
- **`busctl`** (`systemd`) e **`gdbus`** (`glib2`) para chamadas e monitoramento de sinais D-Bus
- **`zenity`** para o seletor de arquivos

## Instalação

Crie um symlink do repositório dentro do diretório local de plugins do Noctalia:

```bash
mkdir -p ~/.local/share/noctalia/plugins
ln -sfn "$(pwd)" ~/.local/share/noctalia/plugins/kdeconnect
```

Habilite o plugin:

```bash
noctalia msg plugins enable vimi/kdeconnect
```

Depois, adicione o widget **KDE Connect** (`vimi/kdeconnect:widget`) à sua barra em **Settings → Bar → Widgets**.

## Como testar e recarregar

Validar manifesto e scripts:

```bash
noctalia plugins lint .
```

Recarregar o plugin após alterações no `plugin.toml`:

```bash
noctalia msg plugins disable vimi/kdeconnect
noctalia msg plugins enable vimi/kdeconnect
```

Comandos úteis via IPC:

```bash
noctalia msg panel-toggle vimi/kdeconnect:panel
noctalia msg plugin vimi/kdeconnect:service all refresh
noctalia msg settings-open-plugin vimi/kdeconnect
```
