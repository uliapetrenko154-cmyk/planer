# Планер

Личный планер: неделя и дни, цели и карта желаний, анкета и «Мой рост». Устанавливается на телефон как приложение.

## Как это устроено
- `index.html` — всё приложение (одна страница), `config.js` — подключение к базе, `sw.js` + `manifest.webmanifest` + `icons/` — установка и офлайн-режим.
- Данные каждого пользователя лежат в его личном пространстве в Supabase (правила на уровне базы: чужое не прочитать даже владельцу проекта).
- Статистика для владельца (`#admin`) — только обезличенные счётчики: регистрации, активность по дням, устройства.

## Подключение базы (один раз)
1. supabase.com → New project. Регион Frankfurt. Пароль базы — сохранить себе, он больше нигде не нужен.
2. SQL Editor → New query → вставить содержимое `supabase/schema.sql` → Run.
3. Authentication → URL Configuration: Site URL = `https://uliapetrenko154-cmyk.github.io/planer/`, в Redirect URLs добавить тот же адрес.
4. Project Settings → API: скопировать Project URL и anon public key в `config.js`.

## Публикация
GitHub Pages из ветки `main`, папка `/` (Settings → Pages). Адрес: `https://uliapetrenko154-cmyk.github.io/planer/`.
