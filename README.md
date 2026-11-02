# AutoABarz

Скрипт автобазара для Arizona RP. Цены за 30 дней, новые лоты в чате, сделки, техпаспорт, логотип и обновление с GitHub.

## Установка

1. Положить `autoabarz.lua` в папку `moonloader`.
2. Зайти в игру и перезагрузить скрипты.

Скрипт сам скачает в `moonloader\lib\arizona-events` библиотеку из этого репозитория и логотип в `moonloader\images`. Если `core.lua` или `bitstream.lua` без защиты от падения, они будут заменены и скрипт перезапустится.

Нужны MoonLoader, mimgui и effil.

## Команды

- `/abarz` — меню
- `/abscan` — скан средних цен
- `/abprice` — средняя цена по названию
- `/abchat` — чат скрипта
- `/abupdate` — проверка обновления

## Файлы

- `autoabarz.lua` — скрипт
- `version.json` — номер версии для автообновления
- `images/abarz-logo.png` — логотип в левом верхнем углу меню
- `arizona-events/` — разбор пакетов интерфейса Arizona

В `core.lua` и `bitstream.lua` длина строки ограничена остатком пакета, а битый пакет пропускается. Из-за этого `bad allocation` больше не роняет скрипт.

Тема на Blast: https://www.blast.hk/threads/257682/
