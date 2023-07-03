---
title: Дружим vscode с Ghidra и IDA
date: 2023-07-03 00:00:00 +03:00
image: /assets/img/posts/ghidra-ida-vscode/ghidra-logo.jpg
---

Оба инструмента представляют возможность редактирования скриптов, но из-за скудного встроенного редактора: отсутствие подсветки синтаксиса, автодополнения, автотабуляции, я сразу переключаюсь на альтернативы. В этой небольшой заметке я расскажу как удаленно запускать и отлаживать скрипты через vscode в Ghidra и IDA.

## IDA Python + Vscode

### Необходимые инструменты
- [https://github.com/ioncodes/idacode](https://github.com/ioncodes/idacode) - мост между IDA Pro и vscode.

### Установка idacode
- В `ida/idacode_utils/settings.py` необходимо правильно указать путь до интерпретатора питона;
- Содержимое папки `ida` необходимо скопировать в папку с плагинами IDA Pro;
- `idacode` дополнение необходимо установить в `vscode Extensions`;
- Запустить плагин `idacode`. В терминале должна появиться строка `IDACode listening on 127.0.0.1:7065`;

### Vscode
- Для автодополнения, в корне директории со скриптом нужно создать файл `.env` и указать путь до IDA Python:
`PYTHONPATH=F:\tools\IDA Pro 7.7\python\3`;
- `Ctrl+Shift+P -> IDACode: Connect to IDA`;
- `Ctrl+Shift+P -> IDACode: Execute script in IDA`;
- По умолчанию скрипт будет запускаться при каждом сохранении, что я нахожу это очень неудобным. Чтобы это отключить, в `.vscode/settings.json` нужно добавить строку `"IDACode.executeOnSave": false`.

## Ghidra Python + Vscode
### Необходимые инструменты
- [https://github.com/VDOO-Connected-Trust/ghidra-pyi-generator](https://github.com/VDOO-Connected-Trust/ghidra-pyi-generator) - Генератор `pyi` файлов для автодополнения;
- [https://github.com/justfoxing/ghidra_bridge](https://github.com/justfoxing/ghidra_bridge) - Библиотека для удаленного выполнения скриптов.

### Установка автодополнения
В соответствии с текущей версии Ghidra, нужно скачать  `ghidra-stubs-*.tar.gz` из ресурсов [https://github.com/VDOO-Connected-Trust/ghidra-pyi-generator/releases](https://github.com/VDOO-Connected-Trust/ghidra-pyi-generator/releases). Далее командой `python setup.py install` установить пакет.

### Установка Ghidra-bridge
В репозитории [ghidra_bridge](https://github.com/justfoxing/ghidra_bridge) подробно расписано как установить и настроить пакет. Если коротко, то нужно сделать 2 команды:
```
pip install ghidra_bridge
python -m ghidra_bridge.install_server C:\Users\USERNAME\ghidra_scripts\Bridge
```
Советую в папке `ghidra_scripts` создать папку `Bridge` и уже туда установить скрипты сервера. Так же, для удобства, можно вынести скрипты `ghidra_bridge_server_background.py` и `ghidra_bridge_server_shutdown.py` в контекстное меню `Tools -> Ghidra Bridge` (см. пункт 3 в репозитории). В `Script Manager` запустить скрипт `ghidra_bridge_server_background.py`.

### Vscode
В шапку скрипта необходимо добавить:
```python
import ghidra_bridge
import typing
if typing.TYPE_CHECKING:
    import ghidra
    from ghidra.ghidra_builtins import *
else:
    br = ghidra_bridge.GhidraBridge(namespace=globals())
```
